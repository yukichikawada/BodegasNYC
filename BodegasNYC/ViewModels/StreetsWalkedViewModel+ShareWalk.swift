import Foundation

// Share a Walk (#177 PR 1): the form reads the history Your Walks already
// holds (`walksHistory`); runs for the picture are built off the main actor.
extension StreetsWalkedViewModel {
    /// The walked runs for a shared walk's picture.
    func shareRuns(_ walk: SharedWalk) async -> [WalkedRun] {
        await matcher.runs(for: walk.blockIDs)
    }

    /// The snapshotter the picture uses: MapKit's, or under the DEBUG UI-test
    /// fixtures (no network) a flat stub, unless `-UITestLiveSnapshot` asks
    /// for MapKit's for a live check.
    static var walkSnapshotter: any WalkMapSnapshotting {
        #if DEBUG
        if UITestFixtures.isEnabled, !UITestFixtures.usesLiveSnapshot {
            return UITestFixtures.FlatWalkSnapshotter()
        }
        #endif
        return MapKitWalkSnapshotter()
    }
}
