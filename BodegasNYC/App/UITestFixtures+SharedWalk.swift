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

    /// `-UITestOpenURL <url>` (#177 PR 2): hands `<url>` to the shared walk
    /// inbox's `receive(_:)` at launch, the path `.onOpenURL` takes, since
    /// `XCUIApplication.open(_:)` is unreliable for universal links.
    nonisolated static let openURLArgument = "-UITestOpenURL"
    /// `-UITestOpenURLDelay <seconds>`: hands it over that long after launch
    /// instead, so a UI test can have another sheet up when it lands.
    nonisolated static let openURLDelayArgument = "-UITestOpenURLDelay"

    nonisolated static func argumentValue(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Feeds `-UITestOpenURL` to `inbox`, at once or after the delay.
    static func openLaunchURL(in inbox: SharedWalkInbox) {
        guard let text = argumentValue(after: openURLArgument), let url = URL(string: text) else { return }
        let delay = argumentValue(after: openURLDelayArgument).flatMap(Double.init) ?? 0
        guard delay > 0 else {
            inbox.receive(url)
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            inbox.receive(url)
        }
    }

    /// A shared walk's blocks (#177 PR 2): 53 `physicalid`s in the bundled
    /// street file along a loop from 5th Avenue and 14th Street up to 34th,
    /// across to 8th Avenue and back down, for the violet captures and the
    /// UI tests' links (`SharedWalkLinkTests` checks every id is in the
    /// bundle).
    nonisolated static let sharedWalkFixtureIDs: Set<UInt32> = [
        762, 843, 1009, 1106, 1107, 1108, 1109, 1110, 1111, 1112, 1113, 1114, 1115, 1116, 1117, 1118, 1119,
        1120, 1121, 1122, 1169, 1351, 1383, 1389, 1392, 4230, 16619, 16681, 16686, 16722, 16724, 72653, 79849,
        79854, 79855, 79890, 79905, 79949, 79951, 80051, 80065, 81163, 81166, 97215, 118232, 155903, 172248,
        174138, 174203, 181261, 183517, 183629, 191178
    ]

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
