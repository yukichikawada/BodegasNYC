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
/// Owns its own dedicated `CLLocationManager`, separate from
/// `LocationPermissionClient`'s — a `CLLocationManager` only supports one
/// delegate at a time, and authorization status is shared app-wide
/// regardless of which manager instance requested it, so this manager can
/// start updates immediately once
/// `locationPermissionClient.authorizationStatus == .authorizedAlways`.
///
/// Decoupled from `BodegaMapViewModel` on purpose: this feature's data
/// source (background `CLLocationManager` updates persisted to SwiftData)
/// has an entirely different lifecycle than the bodega pins' async Supabase
/// fetch, so composing two small view models at the view layer is simpler
/// than one shared type trying to own both.
@MainActor
@Observable
final class StreetsWalkedViewModel: NSObject, CLLocationManagerDelegate {
    enum StreetsWalkedError: Error {
        case authorizationNotGranted
    }

    /// Where the block counts stand (design D8).
    enum CountState: Equatable {
        /// Nothing asked yet (no history, recording off: the street data
        /// never loads).
        case idle
        /// A pass is running; the last overlay and counts stay up.
        case counting
        case ready
        /// The bundled street data did not load (eng R5).
        case unavailable
    }

    private(set) var isTrackingEnabled = false
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
    private(set) var lastTrackingError: String?
    /// The map's "No streets yet." card was closed. Deliberately not
    /// persisted: it lives here rather than on `MapScreenView` so it
    /// survives the Map/List tab switch that rebuilds that view, and resets
    /// on relaunch (spec #24, eng review).
    var isEmptyBannerDismissed = false
    /// Whether the scene is in the foreground; deliveries match only then.
    private(set) var isSceneActive = false
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
    private let userDefaults: UserDefaults
    private let manager: CLLocationManager
    private let matcher: BlockMatchingActor
    private let motion: any MotionActivityProviding
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false

    private static let trackingEnabledDefaultsKey = "streetsWalked.isTrackingEnabled"
    private static let overlayVisibleDefaultsKey = "streetsWalked.isOverlayVisible"
    private static let motionAskedDefaultsKey = "streetsWalked.hasAskedForMotion"
    /// Must match a key in `Info.plist`'s
    /// `NSLocationTemporaryUsageDescriptionDictionary` — calling
    /// `requestTemporaryFullAccuracyAuthorization` with an unregistered key
    /// is a hard runtime crash, not a catchable error.
    private static let fullAccuracyPurposeKey = "StreetsWalkedTracking"

    /// - Parameters:
    ///   - matcher: the matching actor; by default one over `modelContainer`
    ///     with the bundled street data and CoreMotion.
    ///   - motion: Motion & Fitness, for the one-time ask (design D6).
    init(
        locationPermissionClient: LocationPermissionClient,
        modelContainer: ModelContainer,
        userDefaults: UserDefaults = .standard,
        motion: any MotionActivityProviding = CoreMotionActivityProvider(),
        matcher: BlockMatchingActor? = nil
    ) {
        self.locationPermissionClient = locationPermissionClient
        self.modelContainer = modelContainer
        self.modelContext = modelContainer.mainContext
        self.userDefaults = userDefaults
        self.motion = motion
        self.matcher = matcher ?? BlockMatchingActor(container: modelContainer, activityProvider: motion)
        isOverlayVisible = userDefaults.object(forKey: Self.overlayVisibleDefaultsKey) as? Bool ?? true
        let manager = CLLocationManager()
        self.manager = manager
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = true
        manager.activityType = .fitness
        manager.distanceFilter = 15
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        hasHistory = storedPointCount() > 0
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

    /// Since iOS 14, users can grant "Approximate Location" instead of
    /// precise — this is tracked separately from `authorizationStatus`. A
    /// street-level walking tracker with reduced accuracy would produce a
    /// much coarser, less useful trace.
    var accuracyAuthorization: CLAccuracyAuthorization {
        manager.accuracyAuthorization
    }

    /// `requestTemporaryFullAccuracyAuthorization` is completion-handler
    /// based, not routed through `CLLocationManagerDelegate` like
    /// authorization changes — bridged to async/await here to match this
    /// class's other request methods. No-ops (no system prompt) if full
    /// accuracy is already granted, so this is safe to call unconditionally
    /// on every enable/resume rather than needing to be called exactly
    /// once.
    func requestFullAccuracyIfNeeded() async {
        guard Self.shouldRequestFullAccuracy(currentAccuracyAuthorization: accuracyAuthorization) else { return }
        let error = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.fullAccuracyPurposeKey) { error in
                continuation.resume(returning: error)
            }
        }
        if let error {
            lastTrackingError = error.localizedDescription
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
        manager.startUpdatingLocation()
        isTrackingEnabled = true
        userDefaults.set(true, forKey: Self.trackingEnabledDefaultsKey)
        scheduleRefresh()
    }

    /// Pauses collection only — never deletes history. Clearing history is
    /// an explicit, separate, destructive action (`clearHistory()`).
    func disableTracking() {
        manager.stopUpdatingLocation()
        isTrackingEnabled = false
        userDefaults.set(false, forKey: Self.trackingEnabledDefaultsKey)
    }

    /// Asks for Motion & Fitness once, ever (design D6): right after Start
    /// Recording succeeds and the location dialogs have closed. Never on map
    /// open, rebuild or resume; the matcher's queries never prompt.
    func requestMotionAccessIfNeeded() async {
        guard motion.authorization == .notDetermined,
              !userDefaults.bool(forKey: Self.motionAskedDefaultsKey)
        else { return }
        userDefaults.set(true, forKey: Self.motionAskedDefaultsKey)
        await motion.requestAuthorization()
    }

    /// Called once from the composition root on every launch. Per Apple's
    /// documented contract, iOS can relaunch a terminated app in the
    /// background for a new location event, and the app is expected to
    /// re-create/restart its `CLLocationManager` to keep receiving updates
    /// — without this, background tracking would silently stop working the
    /// first time the app is ever killed, defeating the feature's purpose.
    /// Resumes silently (no prompt) only if both the persisted flag and
    /// current authorization already hold. Does not match: a background
    /// relaunch only records (eng R2).
    func resumeTrackingIfPreviouslyEnabled() {
        guard userDefaults.bool(forKey: Self.trackingEnabledDefaultsKey),
              alwaysAuthorizationStatus == .authorizedAlways
        else { return }
        manager.startUpdatingLocation()
        isTrackingEnabled = true
        // Fire-and-forget: this method is called synchronously from the
        // composition root's launch-time factory, which isn't async.
        Task { await requestFullAccuracyIfNeeded() }
    }

    /// Clear History (PRD §5.1, eng R9): deletes every fix recorded up to
    /// `tapTime` (the confirm tap) at once, makes any pass in flight drop its
    /// work, then clears the block cache after it. A fix saved after the
    /// tap survives and starts the new history. Does not affect whether
    /// tracking is enabled.
    func clearHistory(at tapTime: Date = Date()) async throws {
        try modelContext.delete(model: WalkedPoint.self, where: #Predicate { $0.recordedAt <= tapTime })
        try modelContext.save()
        matcher.invalidate()
        if case .failed(let message) = await matcher.clearCache() {
            lastTrackingError = message
        }
        walkedBlockIDs = []
        walkedRunIndex = .empty
        walkedRunsVersion += 1
        appliedRunsVersion = nil
        boroughProgress = boroughProgress.map { BoroughProgress(borough: $0.borough, walked: 0, total: $0.total) }
        hasHistory = storedPointCount() > 0
        if hasHistory { scheduleRefresh() }
    }

    /// The scene came to the foreground (or left it). Coming back runs a
    /// catch-up pass even when no fix arrives (eng A2).
    func sceneActivityChanged(isActive: Bool) {
        isSceneActive = isActive
        if isActive { scheduleRefresh() }
    }

    /// Acknowledges/clears the current error so the UI can dismiss whatever
    /// affordance is showing it. Separate from the condition actually
    /// resolving — a new failure after this call sets `lastTrackingError`
    /// again independently.
    func dismissTrackingError() {
        lastTrackingError = nil
    }

    /// Brings the walked blocks up to date with history and waits for it.
    /// Requests that land while a pass runs are folded into one more pass.
    /// Without history and with recording off it does nothing, so the
    /// street data never loads for people who never opted in.
    func refreshWalkedBlocks() async {
        scheduleRefresh()
        await refreshTask?.value
    }

    private func scheduleRefresh() {
        hasHistory = storedPointCount() > 0
        guard hasHistory || isTrackingEnabled else { return }
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
        let outcome = await matcher.catchUp()
        // A Clear History that landed meanwhile owns the state now.
        guard matcher.generation == generation else {
            countState = hasCounted ? .ready : .idle
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
            lastTrackingError = message
            countState = hasCounted ? .ready : .idle
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

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            recordLocations(locations)
        }
    }

    /// The main-actor body of `didUpdateLocations`, split out so tests can
    /// drive it synchronously instead of racing the delegate's `Task`.
    /// Persists every fix accurate and fresh enough to trust. In the
    /// background that is all (eng R2); in the foreground it also queues a
    /// match pass, so the overlay and the cards update while walking.
    func recordLocations(_ locations: [CLLocation]) {
        var inserted = 0
        for location in locations {
            guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 50,
                  abs(location.timestamp.timeIntervalSinceNow) <= 30
            else { continue }
            modelContext.insert(
                WalkedPoint(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    recordedAt: location.timestamp
                )
            )
            inserted += 1
        }
        guard inserted > 0 else { return }
        // Explicit, immediate save rather than relying on autosave
        // timing — the process can be suspended moments after a
        // background delivery.
        do {
            try modelContext.save()
        } catch {
            lastTrackingError = error.localizedDescription
            return
        }
        hasHistory = true
        if isSceneActive { scheduleRefresh() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            lastTrackingError = error.localizedDescription
        }
    }
}

extension StreetsWalkedViewModel {
    /// Pure branching logic, factored out so it's testable without a live
    /// `CLLocationManager` — same rationale as
    /// `LocationPermissionClient.shouldSkipWhenInUseRequest`/
    /// `shouldSkipAlwaysRequest`.
    nonisolated static func shouldRequestFullAccuracy(currentAccuracyAuthorization: CLAccuracyAuthorization) -> Bool {
        currentAccuracyAuthorization == .reducedAccuracy
    }
}
