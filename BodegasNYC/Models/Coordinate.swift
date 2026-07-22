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
    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
#endif
