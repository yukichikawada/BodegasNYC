//
//  WalkedBlocksPerformanceTests.swift
//  BodegasNYCTests
//
//  The budgets of #108 spec Implementation 4 / AC10b, measured with
//  XCTMeasure (median of the default 10 iterations) on the real bundle:
//  StreetGrid load under 500 ms and 40 MB, a full rebuild of 100,000 fixes
//  under 3 s, an incremental pass of 10 fixes under 5 ms. The budgets are
//  Release numbers and are asserted in Release builds.
//
//  `scripts/run-tests.sh` builds Debug (-Onone), where the matcher runs about
//  40x slower (macOS harness, same sources: 100,000 fixes match in 0.13 s at
//  -O, 6.0 s at -Onone) and the 100,000-fix test alone takes over a minute,
//  past the script's 3-minute cap. So in Debug these tests skip unless
//  opted in (`TEST_RUNNER_BODEGAS_PERF_TESTS=1 TEST_TIMEOUT_SECONDS=900
//  scripts/run-tests.sh`), and then assert Debug ceilings (`debugCeiling`)
//  as a regression guard.
//
//  protects: the matcher and cache stay inside their budgets.
//  fails_when: a median exceeds its budget (Release) or its Debug ceiling
//  (opted-in Debug run); each test times itself on its own clock, so a
//  regression fails the run rather than only logging.
//  no_claim: device timings, or Release timings from a Debug run.
//

import SwiftData
import XCTest

@testable import BodegasNYC

@MainActor
final class WalkedBlocksPerformanceTests: XCTestCase {
    /// One seeded 100,000-fix Manhattan history, shared by the cache tests.
    private static var seeded: (container: ModelContainer, grid: StreetGrid, walk: [WalkedPointSnapshot])?

    private static func seededHistory() throws -> (container: ModelContainer, grid: StreetGrid, walk: [WalkedPointSnapshot]) {
        if let seeded { return seeded }
        let grid = try StreetGrid.loadBundled()
        let walk = manhattanWalk(fixes: 100_000, grid: grid)
        let container = try makeInMemoryModelContainer()
        try StreetFixtures.seed(walk, in: container.mainContext)
        seeded = (container, grid, walk)
        return (container, grid, walk)
    }

    /// Walks Manhattan block after block along each centerline, a fix every
    /// 10 m at 1.4 m/s, with a 25-minute gap between blocks, until `fixes`.
    static func manhattanWalk(fixes: Int, grid: StreetGrid) -> [WalkedPointSnapshot] {
        var walk: [WalkedPointSnapshot] = []
        walk.reserveCapacity(fixes)
        var time = StreetFixtures.baseDate
        var index = 0
        while walk.count < fixes {
            defer { index = (index + 1) % grid.segmentCount }
            guard grid.borough(for: index) == .manhattan else { continue }
            let line = grid.polyline(for: index)
            for (start, end) in zip(line, line.dropFirst()) {
                let meters = BlockMatcher.distance(start, end)
                let steps = max(1, Int((meters / 10).rounded(.up)))
                for step in 0 ..< steps where walk.count < fixes {
                    let fraction = Double(step) / Double(steps)
                    walk.append(WalkedPointSnapshot(
                        coordinate: Coordinate(
                            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                            longitude: start.longitude + (end.longitude - start.longitude) * fraction
                        ),
                        recordedAt: time
                    ))
                    time.addTimeInterval(meters / Double(steps) / 1.4)
                }
            }
            time.addTimeInterval(25 * 60)
        }
        return walk
    }

    private static func median(_ values: [Duration]) -> Duration {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Debug runs skip unless opted in (see the header).
    private func skipUnlessMeasurable() throws {
        #if DEBUG
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BODEGAS_PERF_TESTS"] == "1",
            "Debug build: set TEST_RUNNER_BODEGAS_PERF_TESTS=1 to measure"
        )
        #endif
    }

    /// The Release budget, or in Debug the budget times the measured -Onone
    /// slowdown with headroom.
    private static func ceiling(release: Duration, debug: Duration) -> Duration {
        #if DEBUG
        debug
        #else
        release
        #endif
    }

    private var manualOptions: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        return options
    }

    /// protects: a settle's culling with hysteresis (#113,
    /// `WalkedRunIndex.visible(in:keeping:)`) stays a small part of a frame
    /// on the 5,000-block seed, timed over a scripted 69-settle pan session.
    /// fails_when: the median per-settle time passes 1 ms (Release) or 2 ms
    /// (opted-in Debug; measured 0.13 ms on the simulator, 2026-10-23).
    /// no_claim: MapKit's add/remove cost, which is the hitch (#113 trace).
    func testSettleCullingWithRetentionBudget() throws {
        try skipUnlessMeasurable()
        let index = WalkedPanReplay.seedIndex
        XCTAssertGreaterThan(index.runs.count, 100)
        let regions = WalkedPanReplay.script(over: index, seed: 1)
        var times: [Duration] = []
        let clock = ContinuousClock()
        measure(metrics: [XCTClockMetric()]) {
            var drawn = WalkedOverlay.Visible.runs([])
            let start = clock.now
            for region in regions {
                drawn = index.visible(in: region, keeping: drawn)
            }
            times.append((clock.now - start) / regions.count)
            XCTAssertNotEqual(drawn, .overCap)
        }
        print("Settle culling with retention, per settle median: \(Self.median(times))")
        XCTAssertLessThan(Self.median(times), Self.ceiling(release: .milliseconds(1), debug: .milliseconds(2)))
    }

    func testStreetGridLoadBudget() throws {
        try skipUnlessMeasurable()
        var times: [Duration] = []
        let clock = ContinuousClock()
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let start = clock.now
            let grid = try? StreetGrid.loadBundled()
            times.append(clock.now - start)
            XCTAssertNotNil(grid)
        }
        print("StreetGrid load median: \(Self.median(times))")
        XCTAssertLessThan(Self.median(times), Self.ceiling(release: .milliseconds(500), debug: .seconds(2)))
    }

    func testFullRebuildOfOneHundredThousandFixesBudget() throws {
        try skipUnlessMeasurable()
        let (container, grid, _) = try Self.seededHistory()
        let store = WalkedBlockStore(container: container, grid: grid)
        var times: [Duration] = []
        let clock = ContinuousClock()
        measure(metrics: [XCTClockMetric()], options: manualOptions) {
            // A new dataset stamp: drop the saved one so the next pass rebuilds.
            let context = ModelContext(container)
            for state in (try? context.fetch(FetchDescriptor<WalkedMatchState>())) ?? [] {
                context.delete(state)
            }
            try? context.save()
            startMeasuring()
            let start = clock.now
            do {
                let plan = try XCTUnwrap(store.plan())
                XCTAssertEqual(plan.kind, .rebuild)
                XCTAssertTrue(try store.apply(plan, activity: .unavailable) { true })
            } catch {
                XCTFail("rebuild threw \(error)")
            }
            times.append(clock.now - start)
            stopMeasuring()
        }
        // The first iteration is the post-update backfill (every fix flips);
        // the rest are data-refresh rebuilds.
        print("Full rebuild of 100,000 fixes: first \(times[0]), median \(Self.median(times))")
        XCTAssertLessThan(Self.median(times), Self.ceiling(release: .seconds(3), debug: .seconds(20)))
        XCTAssertGreaterThan(try XCTUnwrap(store.summary()).walkedIDs.count, 5_000)
    }

    func testIncrementalPassOfTenFixesBudget() throws {
        try skipUnlessMeasurable()
        let (container, grid, walk) = try Self.seededHistory()
        let store = WalkedBlockStore(container: container, grid: grid)
        if let plan = try store.plan() {
            try store.apply(plan, activity: .unavailable) { true }
        }
        var next = walk.last?.recordedAt ?? StreetFixtures.baseDate
        let anchor = try XCTUnwrap(walk.last?.coordinate)
        var times: [Duration] = []
        let clock = ContinuousClock()
        measure(metrics: [XCTClockMetric()], options: manualOptions) {
            // Ten new fixes walking north from the end of history.
            let fixes = (1 ... 10).map { step -> WalkedPointSnapshot in
                next.addTimeInterval(7)
                return WalkedPointSnapshot(
                    coordinate: Coordinate(latitude: anchor.latitude + Double(step) * 0.00009, longitude: anchor.longitude),
                    recordedAt: next
                )
            }
            try? StreetFixtures.seed(fixes, in: container.mainContext)
            startMeasuring()
            let start = clock.now
            do {
                let plan = try XCTUnwrap(store.plan())
                XCTAssertEqual(plan.kind, .incremental)
                XCTAssertEqual(plan.unmatched.count, 10)
                XCTAssertTrue(try store.apply(plan, activity: .unavailable) { true })
            } catch {
                XCTFail("incremental pass threw \(error)")
            }
            times.append(clock.now - start)
            stopMeasuring()
        }
        print("Incremental pass of 10 fixes median: \(Self.median(times))")
        XCTAssertLessThan(Self.median(times), Self.ceiling(release: .milliseconds(5), debug: .milliseconds(30)))
    }
}
