import CoreLocation
import Observation

/// Seam for the streets-walked heatmap (`docs/PRD.md` §5) — deliberately
/// not wired into any shipped UI yet. Building the type and its permission
/// entry point now, without the real background-tracking implementation
/// behind it, would mean asking for Always location authorization with no
/// real feature justifying it — a bad-faith look for App Store review and
/// contrary to the PRD's own "keep every permission ask honest and narrowly
/// scoped" framing. `MapScreenView` marks where the future toggle and
/// overlay hook in with `// TODO(streets-walked)`.
///
/// Decoupled from `BodegaMapViewModel` on purpose: this feature's data
/// source (background `CLLocationManager` updates persisted to SwiftData)
/// has an entirely different lifecycle than the bodega pins' async Supabase
/// fetch, so composing two small view models at the view layer is simpler
/// than one shared type trying to own both.
@MainActor
@Observable
final class StreetsWalkedViewModel {
    private(set) var isTrackingEnabled = false

    private let locationPermissionClient: LocationPermissionClient

    init(locationPermissionClient: LocationPermissionClient) {
        self.locationPermissionClient = locationPermissionClient
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

    // TODO(streets-walked): start continuous, distance-filtered background
    // CLLocationManager updates and persist walked segments to SwiftData.
    func enableTracking() async throws {
        isTrackingEnabled = true
    }

    // TODO(streets-walked): stop background location updates.
    func disableTracking() {
        isTrackingEnabled = false
    }

    // TODO(streets-walked): delete all SwiftData-persisted walked-street
    // records (PRD §5.1: users must be able to fully clear this history).
    func clearHistory() async throws {}
}
