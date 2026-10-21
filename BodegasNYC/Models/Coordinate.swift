import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// A plain latitude/longitude pair. Not decoded directly from the wire —
/// `Bodega` reads flat `latitude`/`longitude` columns (generated from the
/// `bodegas.location` PostGIS column) and assembles this in its own custom
/// `init(from:)`.
nonisolated struct Coordinate: Codable, Sendable, Hashable {
    var latitude: Double
    var longitude: Double
}

#if canImport(CoreLocation)
extension Coordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Straight-line distance in metres (`CLLocation.distance(from:)`).
    func distance(to other: Coordinate) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }

    /// How far this point is from the user's fix (#68), `nil` without a fix.
    /// One helper so the list row and the detail header compute it the same
    /// way; the fix's accuracy gates "Around the corner" (design D3).
    func blockDistance(from fix: UserFix?) -> BlockDistance? {
        guard let fix else { return nil }
        return BlockDistance(meters: distance(to: fix.coordinate), horizontalAccuracy: fix.horizontalAccuracy)
    }
}
#endif
