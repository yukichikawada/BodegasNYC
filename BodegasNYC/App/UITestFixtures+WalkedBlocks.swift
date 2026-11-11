#if DEBUG
import Foundation
import SwiftData

// Walked blocks for `BodegasNYCUITests` (#108 PR 2).
nonisolated extension UITestFixtures {
    // MARK: Walked blocks (#108 PR 2)

    /// With `-UITestFixtures`, Streets Walked runs on an in-memory store
    /// seeded with `walkedBlockFixture`, so Your Blocks has a known count
    /// without touching the simulator's real history.
    static let walkedBlocksLaunchArgument = "-UITestWalkedBlocks"

    static var seedsWalkedBlocks: Bool {
        isEnabled && CommandLine.arguments.contains(walkedBlocksLaunchArgument)
    }

    /// The in-memory Streets Walked store with the fixture walk saved, or
    /// nil if the bundled street data or the store fails.
    @MainActor
    static func makeWalkedBlocksContainer(now: Date = Date()) -> ModelContainer? {
        guard let grid = try? StreetGrid.loadBundled(),
              let container = try? ModelContainer(
                  for: Schema(StreetsWalkedSchema.models),
                  configurations: ModelConfiguration(isStoredInMemoryOnly: true)
              )
        else { return nil }
        let context = container.mainContext
        for fix in walkedBlockFixture(grid: grid, now: now) {
            context.insert(
                WalkedPoint(
                    id: fix.id,
                    latitude: fix.coordinate.latitude,
                    longitude: fix.coordinate.longitude,
                    recordedAt: fix.recordedAt
                )
            )
        }
        guard (try? context.save()) != nil else { return nil }
        return container
    }

    /// A walk down the centreline of one real Manhattan block: the first
    /// Manhattan segment in the bundle between 80 and 200 m long, end to
    /// end at 1.4 m/s with fixes at most 10 m apart, finishing an hour
    /// before `now`. It walks exactly one block, so Your Blocks reads
    /// "Manhattan, 1 of 9,300 blocks, less than 1 percent."
    /// (`YourBlocksTests` checks that against the bundle).
    static func walkedBlockFixture(grid: StreetGrid, now: Date) -> [WalkedPointSnapshot] {
        if let count = UserDefaults.standard.string(forKey: "UITestWalkedBlockCount").flatMap(Int.init) {
            return manyWalkedBlocks(count, grid: grid, now: now)
        }
        guard let index = (0 ..< grid.segmentCount).first(where: {
            grid.borough(for: $0) == .manhattan && (80 ... 200).contains(grid.length(of: $0))
        }) else { return [] }
        let vertices = grid.polyline(for: index)
        var points: [Coordinate] = [vertices[0]]
        for (start, end) in zip(vertices, vertices.dropFirst()) {
            let steps = max(1, Int((BlockMatcher.distance(start, end) / 10).rounded(.up)))
            for step in 1 ... steps {
                let fraction = Double(step) / Double(steps)
                points.append(Coordinate(
                    latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                    longitude: start.longitude + (end.longitude - start.longitude) * fraction
                ))
            }
        }
        let speed = 1.4
        var elapsed: TimeInterval = 0
        var timed: [(Coordinate, TimeInterval)] = []
        for (offset, point) in points.enumerated() {
            if offset > 0 { elapsed += BlockMatcher.distance(points[offset - 1], point) / speed }
            timed.append((point, elapsed))
        }
        let start = now.addingTimeInterval(-3_600 - elapsed)
        return timed.map { WalkedPointSnapshot(coordinate: $0.0, recordedAt: start.addingTimeInterval($0.1)) }
    }

    /// #119 probe, simulator look checks: `-UITestWalkedBlockCount N` walks
    /// the N Manhattan blocks nearest the `-WalkedLaunchCamera` centre (else
    /// Washington Square), each end to end at 1.4 m/s, fixes at most 10 m
    /// apart, with a 0.1 s hop between blocks (too fast to credit).
    static func manyWalkedBlocks(_ count: Int, grid: StreetGrid, now: Date) -> [WalkedPointSnapshot] {
        let parts = (UserDefaults.standard.string(forKey: "WalkedLaunchCamera") ?? "")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let center = parts.count >= 2
            ? Coordinate(latitude: parts[0], longitude: parts[1])
            : Coordinate(latitude: 40.7308, longitude: -73.9973)
        let nearest = (0 ..< grid.segmentCount)
            .filter { grid.borough(for: $0) == .manhattan }
            .map { ($0, BlockMatcher.distance(WalkedTiles.halfLengthPoint(grid.polyline(for: $0)), center)) }
            .sorted { $0.1 < $1.1 }
            .prefix(count)
        var fixes: [(Coordinate, TimeInterval)] = []
        var elapsed: TimeInterval = 0
        for (index, _) in nearest {
            let vertices = grid.polyline(for: index)
            if !fixes.isEmpty { elapsed += 0.1 }
            fixes.append((vertices[0], elapsed))
            for (start, end) in zip(vertices, vertices.dropFirst()) {
                let meters = BlockMatcher.distance(start, end)
                let steps = max(1, Int((meters / 10).rounded(.up)))
                for step in 1 ... steps {
                    let fraction = Double(step) / Double(steps)
                    elapsed += meters / Double(steps) / 1.4
                    fixes.append((Coordinate(
                        latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                        longitude: start.longitude + (end.longitude - start.longitude) * fraction
                    ), elapsed))
                }
            }
        }
        let start = now.addingTimeInterval(-3_600 - elapsed)
        return fixes.map { WalkedPointSnapshot(coordinate: $0.0, recordedAt: start.addingTimeInterval($0.1)) }
    }
}
#endif
