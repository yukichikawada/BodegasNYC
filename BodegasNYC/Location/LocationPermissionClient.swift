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
    /// Keyed rather than a single slot: `requestAlwaysAuthorization()` can be
    /// in flight from one caller while another awaits
    /// `requestWhenInUseAuthorization()` (or the same request twice), and a
    /// single slot would silently overwrite — and leak — the earlier
    /// continuation.
    private var pendingContinuations: [UUID: CheckedContinuation<CLAuthorizationStatus, Never>] = [:]

    /// CLLocationManager's Always-upgrade prompt is documented to be
    /// presentable only once per install; a second call while still
    /// `.authorizedWhenInUse` silently no-ops with no delegate callback at
    /// all. There's no API to distinguish that from "the prompt is still up
    /// and the user hasn't answered yet", so every request is bounded by this
    /// timeout rather than awaiting the delegate forever.
    private static let authorizationTimeout: Duration = .seconds(30)

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

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            authorizationStatus = status
            for id in pendingContinuations.keys {
                resumePending(id: id, status: status)
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
}
