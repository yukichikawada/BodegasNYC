import CoreLocation
import OSLog

/// One delivery from the location backend, decoupled from `CLLocationUpdate`
/// so tests can feed a scripted stream (#123). Built off the main actor by
/// the live backend's producer, so it is `nonisolated` (eng C1).
nonisolated struct WalkUpdate: Sendable, Equatable {
    /// Transient conditions that resolve without the person: logged on
    /// every change (eng R2), and `insufficientlyInUse` rebuilds the
    /// sessions on the next scene activation.
    enum Diagnostic: String, Sendable, Hashable, CaseIterable {
        case insufficientlyInUse
        case locationUnavailable
        case serviceSessionRequired
        case authorizationRequestInProgress
    }

    var location: CLLocation?
    var isStationary: Bool
    /// What stops recording until the person acts (`saveFailed` never
    /// comes from a delivery).
    var problem: RecorderProblem?
    var diagnostics: Set<Diagnostic>

    init(
        location: CLLocation?,
        isStationary: Bool = false,
        problem: RecorderProblem? = nil,
        diagnostics: Set<Diagnostic> = []
    ) {
        self.location = location
        self.isStationary = isStationary
        self.problem = problem
        self.diagnostics = diagnostics
    }

    /// Maps a live update to one problem (#123 design DS3): restricted,
    /// then Location Services off for the whole phone (checked before the
    /// per-app denial, which may be set alongside it), then denied, then
    /// Precise off. The transient flags are diagnostics only.
    init(_ update: CLLocationUpdate) {
        var problem: RecorderProblem?
        if update.authorizationRestricted {
            problem = .restricted
        } else if update.authorizationDeniedGlobally {
            problem = .servicesOff
        } else if update.authorizationDenied {
            problem = .denied
        } else if update.accuracyLimited {
            problem = .preciseOff
        }
        var diagnostics: Set<Diagnostic> = []
        if update.insufficientlyInUse { diagnostics.insert(.insufficientlyInUse) }
        if update.locationUnavailable { diagnostics.insert(.locationUnavailable) }
        if update.serviceSessionRequired { diagnostics.insert(.serviceSessionRequired) }
        if update.authorizationRequestInProgress { diagnostics.insert(.authorizationRequestInProgress) }
        self.init(
            location: update.location,
            isStationary: update.stationary,
            problem: problem,
            diagnostics: diagnostics
        )
    }
}

/// The authorization state the recorder reads at each activation and on
/// each authorization change (#123 design DS3).
nonisolated struct LocationAccess: Equatable, Sendable {
    var status: CLAuthorizationStatus
    var isPrecise: Bool = true
    /// Location Services for the whole phone; with it off the per-app
    /// status reads `.denied`.
    var servicesEnabled: Bool = true

    var isAlways: Bool { status == .authorizedAlways }

    /// What this access state alone says is wrong.
    var problems: Set<RecorderProblem> {
        switch status {
        case .restricted: return [.restricted]
        case .denied: return servicesEnabled ? [.denied] : [.servicesOff]
        case .authorizedAlways: return isPrecise ? [] : [.preciseOff]
        case .authorizedWhenInUse: return isPrecise ? [.needsAlways] : [.needsAlways, .preciseOff]
        default: return [.needsAlways]
        }
    }
}

/// The one seam between `WalkRecorder` and Core Location (eng S1):
/// `start()` takes the sessions and returns the update stream; `stop()`
/// gives the sessions up and finishes the stream.
protocol WalkLocationBackend: AnyObject {
    func start() -> AsyncStream<WalkUpdate>
    func stop()
}

/// Holds `CLServiceSession(.always)` and `CLBackgroundActivitySession` and
/// a producer that forwards `CLLocationUpdate.liveUpdates(.fitness)`. Both
/// sessions are taken synchronously in `start()`, which the app delegate
/// calls inside `didFinishLaunching` on a background launch (the headers'
/// contract: a session not re-taken at once on that run ends). Ending the
/// stream, from either side, cancels the producer (eng O3).
final class LiveWalkLocationBackend: WalkLocationBackend {
    /// Takes the sessions and returns the call that invalidates them.
    typealias TakeSessions = @MainActor () -> @MainActor () -> Void
    /// Forwards updates into the continuation until cancelled.
    typealias Produce = @Sendable (AsyncStream<WalkUpdate>.Continuation) async -> Void

    /// Must match a key in `Info.plist`'s
    /// `NSLocationTemporaryUsageDescriptionDictionary`.
    static let fullAccuracyPurposeKey = "StreetsWalkedTracking"

    private let takeSessions: TakeSessions
    private let produce: Produce
    private var invalidateSessions: (@MainActor () -> Void)?
    private var continuation: AsyncStream<WalkUpdate>.Continuation?

    init(
        takeSessions: @escaping TakeSessions = LiveWalkLocationBackend.takeLocationSessions,
        produce: @escaping Produce = LiveWalkLocationBackend.produceLiveUpdates
    ) {
        self.takeSessions = takeSessions
        self.produce = produce
    }

    func start() -> AsyncStream<WalkUpdate> {
        stop()
        invalidateSessions = takeSessions()
        let (stream, continuation) = AsyncStream.makeStream(of: WalkUpdate.self)
        let produce = produce
        let producer = Task.detached {
            await produce(continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in producer.cancel() }
        self.continuation = continuation
        return stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        invalidateSessions?()
        invalidateSessions = nil
    }

    /// The service session first (it carries the Always requirement and
    /// the full-accuracy purpose key for relaunches), then the background
    /// activity session (the blue status-bar pill).
    static func takeLocationSessions() -> @MainActor () -> Void {
        let service = CLServiceSession(authorization: .always, fullAccuracyPurposeKey: fullAccuracyPurposeKey)
        let activity = CLBackgroundActivitySession()
        return {
            service.invalidate()
            activity.invalidate()
        }
    }

    nonisolated static func produceLiveUpdates(_ continuation: AsyncStream<WalkUpdate>.Continuation) async {
        do {
            for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                if Task.isCancelled { return }
                continuation.yield(WalkUpdate(update))
            }
        } catch {
            WalkRecorder.logger.error("live updates threw: \(error.localizedDescription, privacy: .public)")
        }
    }
}
