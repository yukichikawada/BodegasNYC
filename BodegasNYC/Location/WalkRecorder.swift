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
///
/// What is wrong is a set of `RecorderProblem`s (design DS3): from the
/// authorization state (read at activation and on each change), from the
/// latest delivery, and a failed save. They live here, not in the UI, so a
/// dismissed card still leaves the problem in the model (design DS5).
@Observable
final class WalkRecorder {
    enum RecorderError: Error {
        case authorizationNotGranted
    }

    nonisolated static let trackingEnabledDefaultsKey = "streetsWalked.isTrackingEnabled"
    /// A saved fix at least this far from the last saved one (decision D2:
    /// today's `distanceFilter`, now in code since live updates have none).
    nonisolated static let minimumSpacingMeters: CLLocationDistance = 15
    nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BodegasNYC",
        category: "WalkRecorder"
    )

    /// The persisted intent; survives a pause (eng R1) and any problem.
    private(set) var isEnabled: Bool {
        didSet { userDefaults.set(isEnabled, forKey: Self.trackingEnabledDefaultsKey) }
    }
    /// The sessions are held and the loop was started: intent and Always.
    private(set) var isRecording = false
    /// From the authorization state; empty while the intent is off.
    private(set) var accessProblems: Set<RecorderProblem> = []
    /// From the latest delivery; a delivery with a fix and no problem
    /// clears it, and so does a restart.
    private(set) var deliveryProblem: RecorderProblem?
    /// The last save failed; the next successful save clears it.
    private(set) var saveFailed = false
    /// Called on the main actor after each save that inserted a fix.
    @ObservationIgnored var onPointsSaved: (@MainActor () -> Void)?
    /// Called on the main actor when `topProblem` changes, with the old
    /// and the new value, after the recorder has settled (so a resume has
    /// already set `isRecording`).
    @ObservationIgnored var onTopProblemChanged: (@MainActor (RecorderProblem?, RecorderProblem?) -> Void)?

    /// Every current problem; empty while the intent is off.
    var problems: Set<RecorderProblem> {
        guard isEnabled else { return [] }
        var all = accessProblems
        if let deliveryProblem { all.insert(deliveryProblem) }
        if saveFailed { all.insert(.saveFailed) }
        return all
    }

    /// The one problem to show, by `RecorderProblem`'s order.
    var topProblem: RecorderProblem? { problems.min() }

    /// Updates handled since launch, for tests to wait on.
    private(set) var handledUpdateCount = 0
    private(set) var isLoopAlive = false

    /// Held explicitly: a `ModelContext` does not keep its container alive.
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let userDefaults: UserDefaults
    private let access: @MainActor () -> LocationAccess
    private let backend: any WalkLocationBackend
    private let now: () -> Date
    private let saveContext: @MainActor (ModelContext) throws -> Void
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    /// Bumped on every start and stop, so a loop that outlives its run
    /// drops what it still receives.
    @ObservationIgnored private var loopGeneration = 0
    @ObservationIgnored private var lastSaved: CLLocation?
    @ObservationIgnored private var lastStationary: Bool?
    @ObservationIgnored private var lastDiagnostics: Set<WalkUpdate.Diagnostic> = []

    /// - Parameters:
    ///   - access: the authorization state, read at launch, at each scene
    ///     activation and on each authorization change.
    ///   - saveContext: saves after each insert; a seam for the save-failure
    ///     tests.
    init(
        modelContainer: ModelContainer,
        userDefaults: UserDefaults = .standard,
        access: @escaping @MainActor () -> LocationAccess,
        backend: any WalkLocationBackend = LiveWalkLocationBackend(),
        now: @escaping () -> Date = Date.init,
        saveContext: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) {
        // Inserts and Clear History share the main context, as before (eng R3).
        self.modelContainer = modelContainer
        modelContext = modelContainer.mainContext
        self.userDefaults = userDefaults
        self.access = access
        self.backend = backend
        self.now = now
        self.saveContext = saveContext
        isEnabled = userDefaults.bool(forKey: Self.trackingEnabledDefaultsKey)
    }

    /// Starts recording and persists the intent. Throws, changing nothing,
    /// unless Always is granted. A no-op while already recording.
    func start() throws {
        let current = access()
        guard current.isAlways else {
            throw RecorderError.authorizationNotGranted
        }
        settleProblems {
            isEnabled = true
            accessProblems = current.problems
            guard !isRecording else { return }
            startBackend()
            Self.logger.info("start")
        }
    }

    /// Start Recording without Always (design DS4): the intent is saved and
    /// the problem card explains what Settings needs; granting Always later
    /// starts recording on the next activation (eng R1). With Always it
    /// starts at once.
    func enable() {
        settleProblems { isEnabled = true }
        resync()
    }

    /// Stops recording, clears the intent and every problem. A second call
    /// is a no-op.
    func stop() {
        settleProblems {
            isEnabled = false
            accessProblems = []
            deliveryProblem = nil
            saveFailed = false
            guard isRecording else { return }
            stopBackend()
            Self.logger.info("stop")
        }
    }

    /// At launch, from `didFinishLaunching`: resumes when the intent and
    /// Always both hold, before the delegate returns, so a background
    /// relaunch re-takes the sessions in time. Never prompts.
    func resumeIfPreviouslyEnabled(isBackgroundLaunch: Bool = false) {
        guard isEnabled, !isRecording else { return }
        let current = access()
        settleProblems {
            accessProblems = current.problems
            guard current.isAlways else { return }
            startBackend()
            Self.logger.info("resumed at launch (background: \(isBackgroundLaunch, privacy: .public))")
        }
    }

    /// On every scene activation (eng R1, R2, O1): without Always the
    /// sessions are given up but the intent kept, and the problem says why;
    /// with Always, recording starts if it was paused or skipped, and a dead
    /// loop or one stalled on `insufficientlyInUse` is rebuilt here in the
    /// foreground, where a new session can activate.
    func resync() {
        guard isEnabled else { return }
        let current = access()
        settleProblems {
            accessProblems = classify(current)
            guard current.isAlways else {
                if isRecording {
                    stopBackend()
                    Self.logger.info("paused: not Always (status \(current.status.rawValue, privacy: .public))")
                }
                return
            }
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
    }

    /// The authorization changed (the app delegate's location manager):
    /// re-reads the problems only. Sessions start and stop at activation.
    func accessDidChange() {
        guard isEnabled else { return }
        let current = access()
        settleProblems { accessProblems = classify(current) }
    }

    /// With the per-app status `.denied`, a delivery that said Location
    /// Services is off for the phone is the better answer when the cached
    /// services flag has not caught up yet.
    private func classify(_ current: LocationAccess) -> Set<RecorderProblem> {
        if current.status == .denied, deliveryProblem == .servicesOff { return [.servicesOff] }
        return current.problems
    }

    /// Runs `body`, then reports a change of `topProblem` once.
    private func settleProblems(_ body: () -> Void) {
        let before = topProblem
        body()
        let after = topProblem
        guard before != after else { return }
        Self.logger.info("problem \(after.map { "\($0)" } ?? "none", privacy: .public)")
        onTopProblemChanged?(before, after)
    }

    // MARK: Loop

    private func startBackend() {
        loopGeneration += 1
        let generation = loopGeneration
        let stream = backend.start()
        isRecording = true
        isLoopAlive = true
        lastDiagnostics = []
        deliveryProblem = nil
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
        settleProblems {
            if let problem = update.problem {
                if problem != deliveryProblem { deliveryProblem = problem }
            } else if update.location != nil, deliveryProblem != nil {
                deliveryProblem = nil
            }
            if let location = update.location { record(location) }
        }
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
            try saveContext(modelContext)
        } catch {
            Self.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
            if !saveFailed { saveFailed = true }
            return
        }
        if saveFailed { saveFailed = false }
        lastSaved = location
        onPointsSaved?()
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
