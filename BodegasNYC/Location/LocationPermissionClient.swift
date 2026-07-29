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

    private let manager: CLLocationManager
    private var pendingContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        self.authorizationStatus = manager.authorizationStatus
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
        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
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
        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
            manager.requestAlwaysAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            authorizationStatus = status
            pendingContinuation?.resume(returning: status)
            pendingContinuation = nil
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
}
