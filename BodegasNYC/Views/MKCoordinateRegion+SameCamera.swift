import MapKit

extension MKCoordinateRegion {
    /// Equal to well under a point on screen: MapKit reports an unchanged
    /// camera with floating-point noise. `MapScreenView` uses it to skip
    /// replaying a settle that changed nothing (#23).
    func isSameCamera(as other: MKCoordinateRegion?) -> Bool {
        guard let other else { return false }
        let tolerance = 1e-7
        return abs(center.latitude - other.center.latitude) < tolerance
            && abs(center.longitude - other.center.longitude) < tolerance
            && abs(span.latitudeDelta - other.span.latitudeDelta) < tolerance
            && abs(span.longitudeDelta - other.span.longitudeDelta) < tolerance
    }
}
