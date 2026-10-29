import CoreLocation
import Observation
import OSLog
import SwiftData

/// Streets Walked's background recorder (#123): one per process, owned by
/// `AppDelegate` and started from `didFinishLaunching`, so a background
/// relaunch records with no UI scene. It persists raw fixes only; matching
/// is `StreetsWalkedViewModel`'s, in the foreground (eng R2).
///
/// Three pieces of state, kept apart (eng O1): the persisted intent
/// (`isEnabled`, the `streetsWalked.isTrackingEnabled` key), whether the
/// sessions are held (`isRecording`: intent and Always at the last check),
/// and whether the update loop is still running (`isLoopAlive`). Scene
/// activation reconciles them (`resync()`).
@Observable
final class WalkRecorder {
    enum RecorderError: Error {
        case authorizationNotGranted
    }

    /// What `lastError` was last set for, so a condition that persists
    /// across deliveries or activations sets it once (no banner flicker).
    enum Issue: Equatable {
        case denied
        case accuracyLimited
        case alwaysOff
    }

    nonisolated static let trackingEnabledDefaultsKey = "streetsWalked.isTrackingEnabled"
    /// A saved fix at least this far from the last saved one (decision D2:
    /// today's `distanceFilter`, now in code since live updates have none).
    nonisolated static let minimumSpacingMeters: CLLocationDistance = 15
    nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BodegasNYC",
        category: "WalkRecorder"
    )

    /// The sessions are held and the loop was started: intent and Always.
    private(set) var isRecording = false
    private(set) var lastError: String?
    /// Called on the main actor after each save that inserted a fix.
    var onPointsSaved: (() -> Void)?

    /// The persisted intent; survives a pause without Always (eng R1) and a
    /// `.denied` delivery.
    var isEnabled: Bool { userDefaults.bool(forKey: Self.trackingEnabledDefaultsKey) }

    /// Updates handled since launch, for tests to wait on.
    private(set) var handledUpdateCount = 0
    private(set) var isLoopAlive = false

    /// Held explicitly: a `ModelContext` does not keep its container alive.
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let userDefaults: UserDefaults
    private let authorizationStatus: @MainActor () -> CLAuthorizationStatus
    private let backend: any WalkLocationBackend
    private let now: () -> Date
    private var loopTask: Task<Void, Never>?
    /// Bumped on every start and stop, so a loop that outlives its run
    /// drops what it still receives.
    private var loopGeneration = 0
    private var lastSaved: CLLocation?
    private var lastIssue: Issue?
    private var lastStationary: Bool?
    private var lastDiagnostics: Set<WalkUpdate.Diagnostic> = []

    init(
        modelContainer: ModelContainer,
        userDefaults: UserDefaults = .standard,
        authorizationStatus: @escaping @MainActor () -> CLAuthorizationStatus,
        backend: any WalkLocationBackend = LiveWalkLocationBackend(),
        now: @escaping () -> Date = Date.init
    ) {
        // Inserts and Clear History share the main context, as before (eng R3).
        self.modelContainer = modelContainer
        modelContext = modelContainer.mainContext
        self.userDefaults = userDefaults
        self.authorizationStatus = authorizationStatus
        self.backend = backend
        self.now = now
    }

    /// Starts recording and persists the intent. Throws, changing nothing,
    /// unless Always is granted. A no-op while already recording.
    func start() throws {
        guard authorizationStatus() == .authorizedAlways else {
            throw RecorderError.authorizationNotGranted
        }
        userDefaults.set(true, forKey: Self.trackingEnabledDefaultsKey)
        guard !isRecording else { return }
        if lastIssue == .alwaysOff { lastIssue = nil }
        startBackend()
        Self.logger.info("start")
    }

    /// Stops recording and clears the intent. A second call is a no-op.
    func stop() {
        userDefaults.set(false, forKey: Self.trackingEnabledDefaultsKey)
        guard isRecording else { return }
        stopBackend()
        Self.logger.info("stop")
    }

    /// At launch, from `didFinishLaunching`: resumes when the intent and
    /// Always both hold, before the delegate returns, so a background
    /// relaunch re-takes the sessions in time. Never prompts.
    func resumeIfPreviouslyEnabled(isBackgroundLaunch: Bool = false) {
        guard isEnabled, !isRecording, authorizationStatus() == .authorizedAlways else { return }
        startBackend()
        Self.logger.info("resumed at launch (background: \(isBackgroundLaunch, privacy: .public))")
    }

    /// On every scene activation (eng R1, R2, O1): without Always the
    /// sessions are given up but the intent kept, and the person is told
    /// once; with Always, recording starts if it was paused or skipped, and
    /// a dead loop or one stalled on `insufficientlyInUse` is rebuilt here
    /// in the foreground, where a new session can activate.
    func resync() {
        guard isEnabled else { return }
        let status = authorizationStatus()
        guard status == .authorizedAlways else {
            if isRecording {
                stopBackend()
                Self.logger.info("paused: not Always (status \(status.rawValue, privacy: .public))")
            }
            let isDenied = status == .denied || status == .restricted
            report(isDenied ? .denied : .alwaysOff)
            return
        }
        if lastIssue == .alwaysOff { lastIssue = nil }
        guard isRecording else {
            startBackend()
            Self.logger.info("resumed on activation")
            return
        }
        if !isLoopAlive || lastDiagnostics.contains(.insufficientlyInUse) {
            Self.logger.info("rebuilding sessions (loop alive: \(self.isLoopAlive, privacy: .public))")
            stopBackend()
            startBackend()
        }
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: Loop

    private func startBackend() {
        loopGeneration += 1
        let generation = loopGeneration
        let stream = backend.start()
        isRecording = true
        isLoopAlive = true
        lastDiagnostics = []
        loopTask = Task { [weak self] in
            for await update in stream {
                guard let self, self.loopGeneration == generation else { return }
                self.handle(update)
            }
            self?.loopEnded(generation: generation)
        }
    }

    private func stopBackend() {
        loopGeneration += 1
        loopTask?.cancel()
        loopTask = nil
        backend.stop()
        isRecording = false
        isLoopAlive = false
    }

    /// The stream ended on its own: logged, intent and `isRecording` kept;
    /// the next activation restarts it (eng O1), so there is no tight loop.
    private func loopEnded(generation: Int) {
        guard generation == loopGeneration else { return }
        isLoopAlive = false
        Self.logger.error("update stream ended while recording")
    }

    private func handle(_ update: WalkUpdate) {
        handledUpdateCount += 1
        if update.isStationary != lastStationary {
            lastStationary = update.isStationary
            Self.logger.info("stationary \(update.isStationary, privacy: .public)")
        }
        if update.diagnostics != lastDiagnostics {
            lastDiagnostics = update.diagnostics
            let names = update.diagnostics.map(\.rawValue).sorted().joined(separator: ",")
            Self.logger.info("diagnostics [\(names, privacy: .public)]")
        }
        if let problem = update.problem {
            report(problem == .denied ? .denied : .accuracyLimited)
        } else if update.location != nil {
            lastIssue = nil
        }
        guard let location = update.location else { return }
        record(location)
    }

    private func record(_ location: CLLocation) {
        guard Self.isTrustworthy(location, now: now()),
              Self.keepsFix(distanceFromLastSaved: lastSaved.map { location.distance(from: $0) })
        else { return }
        modelContext.insert(
            WalkedPoint(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                recordedAt: location.timestamp
            )
        )
        // Saved at once: the process can be suspended moments after a
        // background delivery.
        do {
            try modelContext.save()
        } catch {
            lastError = error.localizedDescription
            return
        }
        lastSaved = location
        onPointsSaved?()
    }

    private func report(_ issue: Issue) {
        guard issue != lastIssue else { return }
        lastIssue = issue
        lastError = Self.message(for: issue)
    }

    /// Interim copy until the design review's card replaces it.
    private static func message(for issue: Issue) -> String {
        switch issue {
        case .denied:
            "Location access is off, so Streets Walked can't record. Turn on Always in Settings."
        case .accuracyLimited:
            "Precise Location is off, so Streets Walked can't record streets accurately."
        case .alwaysOff:
            "Always is off, so Streets Walked paused. Turn on Always in Settings."
        }
    }
}

// MARK: - Filtering (pure)

extension WalkRecorder {
    /// Accurate to 50 m and at most 30 s old (moved unchanged from the view
    /// model's `recordLocations`).
    nonisolated static func isTrustworthy(_ location: CLLocation, now: Date) -> Bool {
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 50
            && abs(location.timestamp.timeIntervalSince(now)) <= 30
    }

    /// Keeps a fix at least 15 m from the last saved one; the first fix
    /// after launch (`nil`) is always kept.
    nonisolated static func keepsFix(distanceFromLastSaved distance: CLLocationDistance?) -> Bool {
        guard let distance else { return true }
        return distance >= minimumSpacingMeters
    }
}
