import CoreLocation
import Observation
import SwiftData

/// Streets-walked heatmap (`docs/PRD.md` §5): opt-in, off-by-default
/// continuous background location tracking, persisted locally to SwiftData
/// and rendered as a polyline overlay (`MapScreenView`).
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

    private(set) var isTrackingEnabled = false
    private(set) var polylines: [[Coordinate]] = []
    private(set) var lastTrackingError: String?

    private let locationPermissionClient: LocationPermissionClient
    /// Held explicitly (not just its `.mainContext`) so the container's
    /// lifetime is unambiguously tied to this view model's, rather than
    /// relying on `ModelContext` retaining its container internally.
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let userDefaults: UserDefaults
    private let manager: CLLocationManager

    private static let trackingEnabledDefaultsKey = "streetsWalked.isTrackingEnabled"
    /// Must match a key in `Info.plist`'s
    /// `NSLocationTemporaryUsageDescriptionDictionary` — calling
    /// `requestTemporaryFullAccuracyAuthorization` with an unregistered key
    /// is a hard runtime crash, not a catchable error.
    private static let fullAccuracyPurposeKey = "StreetsWalkedTracking"

    init(
        locationPermissionClient: LocationPermissionClient,
        modelContainer: ModelContainer,
        userDefaults: UserDefaults = .standard
    ) {
        self.locationPermissionClient = locationPermissionClient
        self.modelContainer = modelContainer
        self.modelContext = modelContainer.mainContext
        self.userDefaults = userDefaults
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
        loadPolylinesIfNeeded()
    }

    /// Pauses collection only — never deletes history. Clearing history is
    /// an explicit, separate, destructive action (`clearHistory()`).
    func disableTracking() {
        manager.stopUpdatingLocation()
        isTrackingEnabled = false
        userDefaults.set(false, forKey: Self.trackingEnabledDefaultsKey)
    }

    /// Called once from the composition root on every launch. Per Apple's
    /// documented contract, iOS can relaunch a terminated app in the
    /// background for a new location event, and the app is expected to
    /// re-create/restart its `CLLocationManager` to keep receiving updates
    /// — without this, background tracking would silently stop working the
    /// first time the app is ever killed, defeating the feature's purpose.
    /// Resumes silently (no prompt) only if both the persisted flag and
    /// current authorization already hold.
    func resumeTrackingIfPreviouslyEnabled() {
        guard userDefaults.bool(forKey: Self.trackingEnabledDefaultsKey),
              alwaysAuthorizationStatus == .authorizedAlways
        else { return }
        manager.startUpdatingLocation()
        isTrackingEnabled = true
        loadPolylinesIfNeeded()
        // Fire-and-forget: this method is called synchronously from the
        // composition root's launch-time factory, which isn't async.
        Task { await requestFullAccuracyIfNeeded() }
    }

    /// Deletes all persisted walked-street history (PRD §5.1: users must be
    /// able to fully clear it). Does not affect whether tracking is
    /// currently enabled.
    func clearHistory() async throws {
        try modelContext.delete(model: WalkedPoint.self)
        try modelContext.save()
        polylines = []
    }

    /// Acknowledges/clears the current error so the UI can dismiss whatever
    /// affordance is showing it. Separate from the condition actually
    /// resolving — a new failure after this call sets `lastTrackingError`
    /// again independently.
    func dismissTrackingError() {
        lastTrackingError = nil
    }

    /// Refetches and resegments the persisted history. Cheap and idempotent
    /// at this feature's scale, so callers (a view's `.task`, right after
    /// enabling tracking, right after clearing history) can call it
    /// whenever a refresh might matter rather than needing a separate
    /// invalidation signal.
    func loadPolylinesIfNeeded() {
        do {
            let descriptor = FetchDescriptor<WalkedPoint>()
            let points = try modelContext.fetch(descriptor)
            let snapshots = points
                .sorted { $0.recordedAt < $1.recordedAt }
                .map {
                    WalkedPointSnapshot(
                        coordinate: Coordinate(latitude: $0.latitude, longitude: $0.longitude),
                        recordedAt: $0.recordedAt
                    )
                }
            polylines = Self.segments(from: snapshots)
        } catch {
            lastTrackingError = error.localizedDescription
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
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
            }
            // Explicit, immediate save rather than relying on autosave
            // timing — the process can be suspended moments after a
            // background delivery.
            do {
                try modelContext.save()
            } catch {
                lastTrackingError = error.localizedDescription
            }
        }
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
