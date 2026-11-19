//
//  WalkHistoryPerformanceTests.swift
//  BodegasNYCTests
//
//  #180 AC 10, export half: on the 100,000-fix seed, an export (one fetch,
//  encode, write) has a median under 5 s in a Release build. Opt-in in the
//  `WalkedBlocksPerformanceTests` harness's pattern (same seed walk, same
//  skip and `ceiling(release:debug:)` rule): Debug runs skip unless
//  `TEST_RUNNER_BODEGAS_PERF_TESTS=1`, then assert the Debug ceiling (60 s).
//  PR 2 adds import here, and the at-the-cap time and memory (eng A2).
//
//  protects: export stays inside its budget, off the main actor.
//  fails_when: the median exceeds 5 s (Release) or 60 s (opted-in Debug),
//  or the file does not hold all 100,000 fixes.
//  no_claim: device timings, or Release timings from a Debug run.
//

import SwiftData
import XCTest

@testable import BodegasNYC

@MainActor
final class WalkHistoryPerformanceTests: XCTestCase {
    private static func median(_ values: [Duration]) -> Duration {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func skipUnlessMeasurable() throws {
        #if DEBUG
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BODEGAS_PERF_TESTS"] == "1",
            "Debug build: set TEST_RUNNER_BODEGAS_PERF_TESTS=1 to measure"
        )
        #endif
    }

    private static func ceiling(release: Duration, debug: Duration) -> Duration {
        #if DEBUG
        debug
        #else
        release
        #endif
    }

    func testExportOfOneHundredThousandFixesBudget() async throws {
        try skipUnlessMeasurable()
        let grid = try StreetGrid.loadBundled()
        let walk = WalkedBlocksPerformanceTests.manhattanWalk(fixes: 100_000, grid: grid)
        let container = try makeInMemoryModelContainer()
        try StreetFixtures.seed(walk, in: container.mainContext)
        let root = URL.temporaryDirectory.appending(path: "WalkHistoryPerformance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = WalkHistoryTransfer(container: container, exportRoot: root)
        let tapTime = Date.distantFuture

        var times: [Duration] = []
        let clock = ContinuousClock()
        var last: WalkHistoryTransfer.Export?
        for _ in 0 ..< 5 {
            let start = clock.now
            last = try await transfer.export(through: tapTime)
            times.append(clock.now - start)
        }
        print("Export of 100,000 fixes: median \(Self.median(times))")
        let export = try XCTUnwrap(last)
        XCTAssertEqual(export.fixCount, 100_000)
        XCTAssertEqual(try WalkHistoryFile.decode(Data(contentsOf: export.files[0])).fixes.count, 100_000)
        XCTAssertLessThan(Self.median(times), Self.ceiling(release: .seconds(5), debug: .seconds(60)))
    }
}
