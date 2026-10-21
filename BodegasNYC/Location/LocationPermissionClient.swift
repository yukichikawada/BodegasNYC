import CoreLocation
import Observation

/// Bridges `CLLocationManager`'s authorization flow to async/await. Owns the
/// single `CLLocationManager` instance shared by every feature that needs a
/// location permission decision (the core bodega-finding When-In-Use ask
/// today; the streets-walked heatmap's separate Always ask once that feature
/// ships — see `StreetsWalkedViewModel`).
///
/// `CLLocationManagerDelegate`'s callbacks are not `@MainActor`-isolated in
/// the SDK, so `locationManagerDidChangeAuthorization` is `nonisolated` here
/// and hops back to the main actor itself, rather than the whole type being
/// `nonisolated` (which would push isolation handling onto every caller
/// instead of handling it once, here).
@MainActor
@Observable
final class LocationPermissionClient: NSObject, CLLocationManagerDelegate {
    private(set) var authorizationStatus: CLAuthorizationStatus
    /// Precise Location on or off. Changes arrive through the same
    /// `locationManagerDidChangeAuthorization` callback (#68: the distance
    /// slot is reserved only with full accuracy).
    private(set) var accuracyAuthorization: CLAccuracyAuthorization

    private let manager: CLLocationManager
    /// Keyed rather than a single slot: `requestAlwaysAuthorization()` can be
    /// in flight from one caller while another awaits
    /// `requestWhenInUseAuthorization()` (or the same request twice), and a
    /// single slot would silently overwrite — and leak — the earlier
    /// continuation.
    private var pendingContinuations: [UUID: CheckedContinuation<CLAuthorizationStatus, Never>] = [:]
    /// Same rationale as `pendingContinuations`, for `requestCurrentFix()`
    /// callers — e.g. Add-a-Bodega's placement-mode auto-pan and "Use Current
    /// Location" shortcut could plausibly race, and the list's distances
    /// (#68) refresh on every tab switch and navigation change.
    private var pendingLocationContinuations: [UUID: CheckedContinuation<CLLocation?, Never>] = [:]

    /// CLLocationManager's Always-upgrade prompt is documented to be
    /// presentable only once per install; a second call while still
    /// `.authorizedWhenInUse` silently no-ops with no delegate callback at
    /// all. There's no API to distinguish that from "the prompt is still up
    /// and the user hasn't answered yet", so every request is bounded by this
    /// timeout rather than awaiting the delegate forever.
    private static let authorizationTimeout: Duration = .seconds(30)
    /// `requestLocation()` has no documented upper bound on how long it can
    /// take (or whether it calls back at all if a fix never arrives), so
    /// this is a best-effort convenience bounded the same way as the
    /// authorization requests above — callers treat a timeout identically to
    /// a denied/failed fix (`nil`).
    private static let locationFixTimeout: Duration = .seconds(10)

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        self.authorizationStatus = manager.authorizationStatus
        self.accuracyAuthorization = manager.accuracyAuthorization
        super.init()
        manager.delegate = self
    }

    /// Requests When-In-Use authorization. Skips the actual prompt once the
    /// user has already answered either way — `.notDetermined` is the only
    /// state a re-prompt can come from, so this just returns the existing
    /// status otherwise instead of silently doing nothing while a caller
    /// awaits forever.
    @discardableResult
    func requestWhenInUseAuthorization() async -> CLAuthorizationStatus {
        guard !Self.shouldSkipWhenInUseRequest(currentStatus: authorizationStatus) else {
            return authorizationStatus
        }
        manager.requestWhenInUseAuthorization()
        return await awaitAuthorizationChange()
    }

    /// Requests Always authorization. Unlike the When-In-Use ask, this has a
    /// real second legitimate entry point beyond `.notDetermined`: the
    /// system-documented `.authorizedWhenInUse` → `.authorizedAlways`
    /// upgrade path re-prompts even though a decision was already made.
    /// Skip only the true terminal state, `.authorizedAlways` itself.
    @discardableResult
    func requestAlwaysAuthorization() async -> CLAuthorizationStatus {
        guard !Self.shouldSkipAlwaysRequest(currentStatus: authorizationStatus) else {
            return authorizationStatus
        }
        manager.requestAlwaysAuthorization()
        return await awaitAuthorizationChange()
    }

    private func awaitAuthorizationChange() async -> CLAuthorizationStatus {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            pendingContinuations[id] = continuation
            Task { @MainActor in
                try? await Task.sleep(for: Self.authorizationTimeout)
                self.resumePending(id: id, status: self.authorizationStatus)
            }
        }
    }

    private func resumePending(id: UUID, status: CLAuthorizationStatus) {
        guard let continuation = pendingContinuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: status)
    }

    /// One-shot current-location fetch for Add-a-Bodega's "Use Current
    /// Location" shortcut and placement-mode auto-pan. Returns `nil` on
    /// timeout/failure/denial rather than throwing — this is a best-effort
    /// convenience, never a hard requirement (placement mode works fine via
    /// manual panning without it).
    @discardableResult
    func requestCurrentLocation() async -> CLLocationCoordinate2D? {
        await requestCurrentFix()?.coordinate
    }

    /// The same one-shot fetch, keeping the whole `CLLocation` so callers can
    /// read its accuracy and timestamp (`UserLocationProvider`, #68). Never
    /// prompts: `nil` unless When-In-Use or Always is already granted.
    func requestCurrentFix() async -> CLLocation? {
        guard Self.canRequestCurrentLocation(authorizationStatus: authorizationStatus) else { return nil }
        let id = UUID()
        manager.requestLocation()
        return await withCheckedContinuation { continuation in
            pendingLocationContinuations[id] = continuation
            Task { @MainActor in
                try? await Task.sleep(for: Self.locationFixTimeout)
                self.resumePendingLocation(id: id, location: nil)
            }
        }
    }

    private func resumePendingLocation(id: UUID, location: CLLocation?) {
        guard let continuation = pendingLocationContinuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: location)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        Task { @MainActor in
            authorizationStatus = status
            accuracyAuthorization = accuracy
            for id in pendingContinuations.keys {
                resumePending(id: id, status: status)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            for id in pendingLocationContinuations.keys {
                resumePendingLocation(id: id, location: location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            for id in pendingLocationContinuations.keys {
                resumePendingLocation(id: id, location: nil)
            }
        }
    }
}

extension LocationPermissionClient {
    /// Pure re-prompt-skip logic, factored out so it's testable without a
    /// live `CLLocationManager` (which, unlike `PostgrestClient`, has no
    /// `URLProtocol`-style seam this codebase's testing conventions can hook
    /// into — see `LocationPermissionClientTests`).
    nonisolated static func shouldSkipWhenInUseRequest(currentStatus: CLAuthorizationStatus) -> Bool {
        currentStatus != .notDetermined
    }

    nonisolated static func shouldSkipAlwaysRequest(currentStatus: CLAuthorizationStatus) -> Bool {
        currentStatus == .authorizedAlways
    }

    nonisolated static func canRequestCurrentLocation(authorizationStatus: CLAuthorizationStatus) -> Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }
}
