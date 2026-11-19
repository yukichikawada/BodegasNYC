#if DEBUG
import Foundation
import SwiftData

// Walked blocks for `BodegasNYCUITests` (#108 PR 2) and walk days for Your
// Walks (#170).
nonisolated extension UITestFixtures {
    // MARK: Walked blocks (#108 PR 2)

    /// With `-UITestFixtures`, Streets Walked runs on an in-memory store
    /// seeded with `walkedBlockFixture`, so Your Blocks has a known count
    /// without touching the simulator's real history.
    static let walkedBlocksLaunchArgument = "-UITestWalkedBlocks"
    /// With `-UITestFixtures`, the in-memory store holds `walkedDaysFixture`
    /// instead (#170): walks on five days, so Your Walks has dots. A separate
    /// argument, so `-UITestWalkedBlocks` keeps its one block.
    static let walkedDaysLaunchArgument = "-UITestWalkedDays"

    static var seedsWalkedBlocks: Bool {
        isEnabled && CommandLine.arguments.contains(walkedBlocksLaunchArgument)
    }

    static var seedsWalkedDays: Bool {
        isEnabled && CommandLine.arguments.contains(walkedDaysLaunchArgument)
    }

    /// The in-memory Streets Walked store with the fixture walks saved, or
    /// nil if the bundled street data or the store fails.
    @MainActor
    static func makeWalkedBlocksContainer(now: Date = Date()) -> ModelContainer? {
        guard let grid = try? StreetGridLoader.shared.grid(),
              let container = try? ModelContainer(
                  for: Schema(StreetsWalkedSchema.models),
                  configurations: ModelConfiguration(isStoredInMemoryOnly: true)
              )
        else { return nil }
        let context = container.mainContext
        let fixes: [WalkedPointSnapshot] = if seedsWalkedDays {
            walkedDaysFixture(grid: grid, now: now)
        } else if seedsWalkedBlocks {
            walkedBlockFixture(grid: grid, now: now)
        } else {
            [] // -UITestImportFixture alone: an empty store for the import to fill
        }
        for fix in fixes {
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
        guard let index = fixtureBlocks(grid: grid, count: 1).first else { return [] }
        let walk = centerlineWalk(grid: grid, segment: index)
        let start = now.addingTimeInterval(-3_600 - (walk.last?.1 ?? 0))
        return walk.map { WalkedPointSnapshot(coordinate: $0.0, recordedAt: start.addingTimeInterval($0.1)) }
    }

    /// The walk-day offsets of `walkedDaysFixture`, before today's walk day.
    static let walkedDayOffsets = [100, 35, 9, 3, 1]

    /// Walks at noon New York time on fixed day offsets from `now`'s walk
    /// day (#170 eng A10, never "an hour before now"), one Manhattan block
    /// each from the first five `fixtureBlocks`, except 3 days back, which
    /// walks the 9-days-back block again before its own: a repeat and a new
    /// block. Offsets 100, 35 and 9 are past CoreMotion's 7 days, so they
    /// read as estimates (eng E2); 100 days back puts the scroll's top three
    /// months or more above the current one (a six-row August in a
    /// mid-November run).
    static func walkedDaysFixture(grid: StreetGrid, now: Date) -> [WalkedPointSnapshot] {
        let blocks = fixtureBlocks(grid: grid, count: 5)
        guard blocks.count == 5 else { return [] }
        let today = WalkedDayKey(date: now)
        let plan: [(offset: Int, blocks: [Int])] = [
            (100, [blocks[4]]), (35, [blocks[0]]), (9, [blocks[1]]), (3, [blocks[1], blocks[2]]), (1, [blocks[3]])
        ]
        var fixes: [WalkedPointSnapshot] = []
        for day in plan {
            var start = today.advanced(by: -day.offset).noon
            for block in day.blocks {
                let walk = centerlineWalk(grid: grid, segment: block)
                fixes += walk.map { WalkedPointSnapshot(coordinate: $0.0, recordedAt: start.addingTimeInterval($0.1)) }
                // A separate walk: past the 20 min gap rule.
                start.addTimeInterval((walk.last?.1 ?? 0) + 30 * 60)
            }
        }
        return fixes
    }

    /// The first `count` Manhattan segments between 80 and 200 m long.
    private static func fixtureBlocks(grid: StreetGrid, count: Int) -> [Int] {
        Array((0 ..< grid.segmentCount).lazy.filter {
            grid.borough(for: $0) == .manhattan && (80 ... 200).contains(grid.length(of: $0))
        }.prefix(count))
    }

    /// Points along a segment's centerline, at most 10 m apart, timed at
    /// 1.4 m/s from zero.
    private static func centerlineWalk(grid: StreetGrid, segment: Int) -> [(Coordinate, TimeInterval)] {
        let vertices = grid.polyline(for: segment)
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
        return timed
    }
}
#endif
