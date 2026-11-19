#if DEBUG
import MapKit
import UIKit

// Share a Walk's picture under the UI-test fixtures (#177 PR 1): UI tests
// have no network, so the snapshot is a flat dark stub and the picture is
// made from it at once.
extension UITestFixtures {
    /// With `-UITestFixtures`, uses MapKit's snapshotter anyway, for a live
    /// look at the picture on a simulator with network.
    nonisolated static let liveSnapshotArgument = "-UITestLiveSnapshot"

    nonisolated static var usesLiveSnapshot: Bool {
        CommandLine.arguments.contains(liveSnapshotArgument)
    }

    /// A snapshot that is one flat #242426 field with a straight
    /// equirectangular projection of the region onto it.
    struct FlatWalkSnapshotter: WalkMapSnapshotting {
        static let ground = UIColor(red: 0x24 / 255, green: 0x24 / 255, blue: 0x26 / 255, alpha: 1)

        func snapshot(region: MKCoordinateRegion, size: CGSize) async throws -> WalkMapSnapshot {
            let format = UIGraphicsImageRendererFormat()
            format.scale = SharedWalkCard.scale
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                Self.ground.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            return WalkMapSnapshot(image: image) { coordinate in
                Self.project(coordinate, region: region, size: size)
            }
        }

        /// Where `coordinate` falls on a `size` image of `region`, north up.
        static func project(_ coordinate: CLLocationCoordinate2D, region: MKCoordinateRegion, size: CGSize) -> CGPoint {
            let west = region.center.longitude - region.span.longitudeDelta / 2
            let north = region.center.latitude + region.span.latitudeDelta / 2
            return CGPoint(
                x: (coordinate.longitude - west) / region.span.longitudeDelta * size.width,
                y: (north - coordinate.latitude) / region.span.latitudeDelta * size.height
            )
        }
    }
}
#endif
