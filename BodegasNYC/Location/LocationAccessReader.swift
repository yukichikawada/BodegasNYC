import CoreLocation

/// The recorder's view of location authorization (#123): one
/// `CLLocationManager`, read for its status and accuracy only, never
/// started (eng C2). Whether Location Services is on for the whole phone is
/// read off the main actor (`locationServicesEnabled()` can block) and
/// cached; `onChange` fires on every authorization change once it is.
final class LocationAccessReader: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var servicesEnabled = true
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var access: LocationAccess {
        LocationAccess(
            status: manager.authorizationStatus,
            isPrecise: manager.accuracyAuthorization == .fullAccuracy,
            servicesEnabled: servicesEnabled
        )
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let enabled = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
            self.servicesEnabled = enabled
            self.onChange?()
        }
    }
}
