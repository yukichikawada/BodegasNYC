import CoreLocation
import Observation
import SwiftData

/// Streets Walked (`docs/PRD.md` §5, #108): opt-in, off-by-default
/// continuous background location tracking, persisted locally to SwiftData
/// as raw fixes, map-matched into walked street blocks
/// (`BlockMatchingActor`) and drawn as a block overlay (`MapScreenView`).
///
/// Background deliveries only persist raw fixes (eng R2): matching, and the
/// street data load it needs, run when the scene becomes active, when the
/// map shows, and per delivery only while the scene is active.
///
/// Recording itself is `WalkRecorder`'s (#123): one per process, owned by
/// `AppDelegate` and started at launch, so it runs with no UI scene. This
/// view model is UI only: one shared instance, built by `AppDelegate` on
/// the first UI request (eng R5), that matches, counts and reads the
/// recorder's state. Scene activity is counted across windows.
///
/// Decoupled from `BodegaMapViewModel` on purpose: this feature's data
/// source (background location updates persisted to SwiftData)
/// has an entirely different lifecycle than the bodega pins' async Supabase
/// fetch, so composing two small view models at the view layer is simpler
/// than one shared type trying to own both.
@MainActor
@Observable
final class StreetsWalkedViewModel {
    enum StreetsWalkedError: Error {
        case authorizationNotGranted
    }

    /// Forwards to the recorder: the sessions are held (intent and Always).
    var isTrackingEnabled: Bool { recorder.isRecording }
    /// Blocks with at least 6 of 10 tenths walked, by `physicalid`.
    private(set) var walkedBlockIDs: Set<UInt32> = []
    /// Walked and total blocks per borough, in `Borough.displayOrder`.
    private(set) var boroughProgress: [BoroughProgress] = []
    /// The walked blocks chained for drawing (eng R3), with their spatial
    /// index, built off the main actor.
    private(set) var walkedRunIndex = WalkedRunIndex.empty
    var walkedRuns: [WalkedRun] { walkedRunIndex.runs }
    /// Bumped whenever the runs are replaced: a cheap change signal for the
    /// map, which redraws only at camera rest (design D10).
    private(set) var walkedRunsVersion = 0
    /// The matcher's `runsVersion` last applied; `nil` after a clear.
    private var appliedRunsVersion: Int?
    /// Whether any raw fix is stored.
    private(set) var hasHistory = false
    private(set) var countState: CountState = .idle
    /// A count has saved since launch, so zero walked blocks is a fact, not
    /// a count in progress (design D8: no "No streets yet." while counting
    /// with no prior blocks).
    private(set) var hasCounted = false
    /// Show on Map (eng R11): persisted, on by default, independent of
    /// recording and Clear History.
    var isOverlayVisible: Bool {
        didSet { userDefaults.set(isOverlayVisible, forKey: Self.overlayVisibleDefaultsKey) }
    }
    /// The last match or count failure, or a failed Precise ask. Logged,
    /// never shown as text (design DS1 removed the banner; DESIGN.md: no raw
    /// error strings): Your Blocks shows a failed first count.
    private(set) var lastMatchError: String? {
        didSet {
            if let lastMatchError {
                WalkRecorder.logger.error("match: \(lastMatchError, privacy: .public)")
            }
        }
    }
    /// The recorder card closed for this problem (design DS5): hidden until
    /// the problem changes or the next cold launch; the problem itself stays
    /// in the recorder. One view model, so every window shares it.
    var dismissedRecorderProblem: RecorderProblem?
    /// Motion & Fitness as last read: at launch, when the scene comes
    /// forward (back from Settings), when Your Blocks opens and after an
    /// ask (design D6).
    private(set) var motionAuthorization: MotionAuthorization
    /// The map's "No streets yet." card was closed. Deliberately not
    /// persisted: it lives here rather than on `MapScreenView` so it
    /// survives the Map/List tab switch that rebuilds that view, and resets
    /// on relaunch (spec #24, eng review).
    var isEmptyBannerDismissed = false
    /// Whether any scene is in the foreground; deliveries match only then.
    var isSceneActive: Bool { !activeScenes.isEmpty }
    /// The windows whose scene is active (eng R5: one view model, many
    /// windows, active while any is).
    private var activeScenes: Set<SceneToken> = []
    /// The map draws walked blocks while history exists and Show on Map is
    /// on, recording or not (eng R11).
    var showsWalkedOverlay: Bool { isOverlayVisible && hasHistory }
    /// Whether a refresh is running or queued.
    var isRefreshing: Bool { refreshTask != nil }

    private let locationPermissionClient: LocationPermissionClient
    /// Held explicitly (not just its `.mainContext`) so the container's
    /// lifetime is unambiguously tied to this view model's, rather than
    /// relying on `ModelContext` retaining its container internally.
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    let userDefaults: UserDefaults
    let recorder: WalkRecorder
    /// Posts a VoiceOver announcement (design DS7); injected for tests.
    let announce: @MainActor (String) -> Void
    private let matcher: BlockMatchingActor
    let motion: any MotionActivityProviding
    private var refreshTask: Task<Void, Never>?
    private let firstCountRetryDelay: Duration
    private var refreshQueued = false

    private static let overlayVisibleDefaultsKey = "streetsWalked.isOverlayVisible"
    static let motionAskedDefaultsKey = "streetsWalked.hasAskedForMotion"

    /// - Parameters:
    ///   - recorder: the process's one `WalkRecorder` (`AppDelegate`).
    ///   - matcher: the matching actor; by default one over `modelContainer`
    ///     with the bundled street data and CoreMotion.
    ///   - motion: Motion & Fitness, for the one-time ask (design D6).
    ///   - firstCountRetryDelay: before a failed first count's retry (#113).
    ///   - announce: posts VoiceOver announcements (design DS7).
    init(
        locationPermissionClient: LocationPermissionClient,
        modelContainer: ModelContainer,
        recorder: WalkRecorder,
        userDefaults: UserDefaults = .standard,
        motion: any MotionActivityProviding = CoreMotionActivityProvider(),
        matcher: BlockMatchingActor? = nil,
        firstCountRetryDelay: Duration = .milliseconds(500),
        announce: @escaping @MainActor (String) -> Void = StreetsWalkedViewModel.postAnnouncement
    ) {
        self.announce = announce
        self.firstCountRetryDelay = firstCountRetryDelay
        self.locationPermissionClient = locationPermissionClient
        self.modelContainer = modelContainer
        self.modelContext = modelContainer.mainContext
        self.userDefaults = userDefaults
        self.recorder = recorder
        self.motion = motion
        self.matcher = matcher ?? BlockMatchingActor(container: modelContainer, activityProvider: motion)
        isOverlayVisible = userDefaults.object(forKey: Self.overlayVisibleDefaultsKey) as? Bool ?? true
        motionAuthorization = motion.authorization
        hasHistory = storedPointCount() > 0
        recorder.onPointsSaved = { [weak self] in self?.pointsSaved() }
        recorder.onTopProblemChanged = { [weak self] old, new in
            self?.recorderProblemChanged(from: old, to: new)
        }
    }

    /// Forwards to the shared `LocationPermissionClient` rather than
    /// tracking a separate copy — `CLLocationManager` has exactly one
    /// authorization status, not distinct slots per feature.
    var alwaysAuthorizationStatus: CLAuthorizationStatus {
        locationPermissionClient.authorizationStatus
    }

    @discardableResult
    func requestTrackingPermission() async -> CLAuthorizationStatus {
        await locationPermissionClient.requestAlwaysAuthorization()
    }

    /// Asks for temporary Precise Location when it is off (eng R4): awaited
    /// in the foreground before the recorder starts, so the Motion ask
    /// that follows never stacks on this sheet. The recorder's service
    /// session carries the same purpose key for relaunches.
    func requestFullAccuracyIfNeeded() async {
        if let error = await locationPermissionClient.requestFullAccuracyIfNeeded(
            purposeKey: LiveWalkLocationBackend.fullAccuracyPurposeKey
        ) {
            lastMatchError = error.localizedDescription
        }
    }

    /// Starts continuous background tracking. Throws rather than silently
    /// no-op-ing if Always authorization isn't actually granted — the
    /// caller (`MapScreenView`) is expected to have already requested it via
    /// `requestTrackingPermission()` and handled a non-`.authorizedAlways`
    /// result (e.g. nudging the user to Settings) before ever calling this.
    func enableTracking() async throws {
        guard alwaysAuthorizationStatus == .authorizedAlways else {
            throw StreetsWalkedError.authorizationNotGranted
        }
        await requestFullAccuracyIfNeeded()
        do {
            try recorder.start()
        } catch {
            throw StreetsWalkedError.authorizationNotGranted
        }
        scheduleRefresh()
    }

    /// Pauses collection only — never deletes history. Clearing history is
    /// an explicit, separate, destructive action (`clearHistory()`).
    func disableTracking() {
        recorder.stop()
    }

    /// Re-reads Motion & Fitness; writes only on a change. The asks are in
    /// `StreetsWalkedViewModel+YourBlocks.swift`.
    func refreshMotionAuthorization() {
        let current = motion.authorization
        if current != motionAuthorization { motionAuthorization = current }
    }

    /// Clear History (PRD §5.1, eng R9): deletes every fix up to `tapTime`
    /// (the confirm tap) at once, makes passes in flight drop their work
    /// (never waiting on one), then clears the block cache after them: zero
    /// walked, real totals (#113). Fixes after the tap survive.
    func clearHistory(at tapTime: Date = Date()) async throws {
        try modelContext.delete(model: WalkedPoint.self, where: #Predicate { $0.recordedAt <= tapTime })
        try modelContext.save()
        matcher.invalidate()
        let outcome = await matcher.clearCache()
        walkedBlockIDs = []
        walkedRunIndex = .empty
        walkedRunsVersion += 1
        appliedRunsVersion = nil
        boroughProgress = boroughProgress.map { BoroughProgress(borough: $0.borough, walked: 0, total: $0.total) }
        if case .updated(let summary, _) = outcome {
            apply(summary)
            hasCounted = true
            // A refresh still running settles the state itself.
            if countState != .unavailable, !isRefreshing { countState = .ready }
        } else if case .failed(let message) = outcome {
            lastMatchError = message
            if !hasCounted, countState != .unavailable { countState = .failed }
        }
        hasHistory = storedPointCount() > 0
        if hasHistory { scheduleRefresh() }
    }

    /// A window's scene came to the foreground (or left it, or the window
    /// went away). Coming back runs a catch-up pass even when no fix
    /// arrives (eng A2) and reconciles the recorder with the current
    /// authorization (eng R1, R2, O1).
    func sceneActivityChanged(isActive: Bool, scene: SceneToken = .main) {
        if isActive {
            activeScenes.insert(scene)
        } else {
            activeScenes.remove(scene)
        }
        guard isActive else { return }
        recorder.resync()
        refreshMotionAuthorization()
        scheduleRefresh()
    }

    /// Brings the walked blocks up to date with history and waits for it.
    /// Requests that land while a pass runs are folded into one more pass.
    /// Without history and with recording off it does nothing, so the
    /// street data never loads for people who never opted in.
    func refreshWalkedBlocks() async {
        scheduleRefresh()
        await refreshTask?.value
    }

    /// `evenWithoutHistory`: Your Blocks asked (`yourBlocksDidOpen`).
    func scheduleRefresh(evenWithoutHistory: Bool = false) {
        hasHistory = storedPointCount() > 0
        guard hasHistory || isTrackingEnabled || evenWithoutHistory else { return }
        guard refreshTask == nil else {
            refreshQueued = true
            return
        }
        refreshTask = Task { [weak self] in
            await self?.runRefreshes()
        }
    }

    private func runRefreshes() async {
        repeat {
            refreshQueued = false
            await refreshOnce()
        } while refreshQueued
        refreshTask = nil
    }

    private func refreshOnce() async {
        let generation = matcher.generation
        if countState != .unavailable { countState = .counting }
        var outcome = await matcher.catchUp()
        if case .failed = outcome, !hasCounted, matcher.generation == generation { // one retry (#113)
            try? await Task.sleep(for: firstCountRetryDelay)
            if matcher.generation == generation { outcome = await matcher.catchUp() }
        }
        // A Clear History that landed meanwhile owns the state now.
        guard matcher.generation == generation else {
            if countState == .counting { countState = hasCounted ? .ready : .idle }
            return
        }
        switch outcome {
        case .updated(let summary, _):
            apply(summary)
            hasCounted = true
            countState = .ready
        case .unavailable:
            countState = .unavailable
        case .cancelled:
            countState = hasCounted ? .ready : .idle
        case .failed(let message):
            lastMatchError = message
            countState = hasCounted ? .ready : .failed
        }
    }

    /// Publishes a summary only when its runs changed: the matcher's
    /// `runsVersion` (an integer compare on the main actor, never the arrays)
    /// moves exactly when they do, and the walked set and counts move with
    /// them. A catch-up that found nothing new writes no state, so the map's
    /// content is not touched (R3 device check).
    private func apply(_ summary: WalkedSummary) {
        guard summary.runsVersion != appliedRunsVersion else { return }
        appliedRunsVersion = summary.runsVersion
        walkedBlockIDs = summary.walkedIDs
        walkedRunIndex = summary.runIndex
        walkedRunsVersion += 1
        boroughProgress = summary.progress
    }

    private func storedPointCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<WalkedPoint>())) ?? 0
    }

    /// The recorder saved a fix. In the background that is all (eng R2); in
    /// the foreground it also queues a match pass, so the overlay and the
    /// cards update while walking.
    private func pointsSaved() {
        hasHistory = true
        if isSceneActive { scheduleRefresh() }
    }
}

extension StreetsWalkedViewModel {
    /// One window's identity for `sceneActivityChanged` (eng R5).
    struct SceneToken: Hashable {
        let id: UUID
        /// The single-scene default (tests, previews).
        static let main = SceneToken(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))

        static func make() -> SceneToken { SceneToken(id: UUID()) }
    }
}
