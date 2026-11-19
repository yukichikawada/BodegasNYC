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

    // MARK: Import (#180 PR 2)

    /// `count` fixes of the Manhattan seed walk, as a file's fixes with no
    /// evidence, extended past the seed by repeating it a day later each
    /// time (fresh ids), so any size can be built.
    private static func fileFixes(_ count: Int, grid: StreetGrid) -> [WalkHistoryFile.Fix] {
        let seed = WalkedBlocksPerformanceTests.manhattanWalk(fixes: min(count, 100_000), grid: grid)
        return (0 ..< count).map { index in
            let snapshot = seed[index % seed.count]
            return WalkHistoryFile.Fix(
                id: UUID(),
                latitude: snapshot.coordinate.latitude,
                longitude: snapshot.coordinate.longitude,
                recordedAt: snapshot.recordedAt.addingTimeInterval(Double(index / seed.count) * 86_400),
                ride: 0
            )
        }
    }

    /// One import of `url` into a fresh empty store: read, validate, id
    /// check, insert, save (AC 10's span; not the match pass after it).
    /// With `onDisk`, into a file-backed store as the app's is (an
    /// in-memory store also holds every row in memory, which inflates peak).
    private static func importOnce(_ url: URL, maxFixCount: Int, onDisk: Bool = false) async throws -> Int {
        let storeDirectory = URL.temporaryDirectory.appending(path: "WalkHistoryImportStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let container: ModelContainer
        if onDisk {
            try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            container = try ModelContainer(
                for: Schema(StreetsWalkedSchema.models),
                configurations: ModelConfiguration(url: storeDirectory.appending(path: "walks.store"))
            )
        } else {
            container = try makeInMemoryModelContainer()
        }
        let transfer = WalkHistoryTransfer(container: container, maxFixCount: maxFixCount)
        let preview = try await transfer.inspect(url, request: 1, now: .distantFuture)
        guard case .committed(let inserted, _) = try await transfer.commit(1, shouldCommit: { true }) else { return -1 }
        XCTAssertEqual(inserted, preview.newFixCount)
        return inserted
    }

    /// #180 AC 10, import half: on the 100,000-fix seed an import has a
    /// median under 5 s in Release (60 s opted-in Debug).
    func testImportOfOneHundredThousandFixesBudget() async throws {
        try skipUnlessMeasurable()
        let grid = try StreetGrid.loadBundled()
        let url = try Self.writeFile(Self.fileFixes(100_000, grid: grid))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var times: [Duration] = []
        let clock = ContinuousClock()
        for _ in 0 ..< 3 {
            let start = clock.now
            let inserted = try await Self.importOnce(url, maxFixCount: WalkHistoryFile.maxFixCount)
            times.append(clock.now - start)
            XCTAssertEqual(inserted, 100_000)
        }
        print("Import of 100,000 fixes: median \(Self.median(times))")
        XCTAssertLessThan(Self.median(times), Self.ceiling(release: .seconds(5), debug: .seconds(60)))
    }

    /// #180 eng A2: time and peak memory of one export and one import at
    /// `WalkHistoryFile.maxFixCount`, against the review's bar (under 30 s
    /// and 300 MB). `BODEGAS_IMPORT_SIZES` (comma-separated) measures other
    /// sizes instead, to choose the cap; each size is printed.
    func testExportAndImportAtTheCap() async throws {
        try skipUnlessMeasurable()
        let grid = try StreetGrid.loadBundled()
        let sizes = ProcessInfo.processInfo.environment["BODEGAS_IMPORT_SIZES"]?
            .split(separator: ",").compactMap { Int($0) } ?? [WalkHistoryFile.maxFixCount]
        let clock = ContinuousClock()
        for size in sizes {
            let source = try makeInMemoryModelContainer()
            let fixes = Self.fileFixes(size, grid: grid)
            for fix in fixes {
                source.mainContext.insert(WalkedPoint(
                    id: fix.id, latitude: fix.latitude, longitude: fix.longitude, recordedAt: fix.recordedAt
                ))
            }
            try source.mainContext.save()
            let root = URL.temporaryDirectory.appending(path: "WalkHistoryCap-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }

            let exportMeter = PeakFootprint()
            var start = clock.now
            let export = try await WalkHistoryTransfer(container: source, exportRoot: root, maxFixCount: size)
                .export(through: .distantFuture)
            let exportTime = clock.now - start
            let exportPeak = exportMeter.stop()
            XCTAssertEqual(export.files.count, 1)

            let importMeter = PeakFootprint()
            start = clock.now
            let inserted = try await Self.importOnce(export.files[0], maxFixCount: size, onDisk: true)
            let importTime = clock.now - start
            let importPeak = importMeter.stop()
            XCTAssertEqual(inserted, size)
            let bytes = (try? export.files[0].resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print("Cap \(size) fixes (\(bytes / 1_000_000) MB file): export \(exportTime), "
                + "peak +\(exportPeak / 1_000_000) MB; import \(importTime), peak +\(importPeak / 1_000_000) MB")
            if sizes == [WalkHistoryFile.maxFixCount] {
                XCTAssertLessThan(importTime, Self.ceiling(release: .seconds(30), debug: .seconds(120)))
                XCTAssertLessThan(importPeak, 300_000_000)
            }
        }
    }

    private static func writeFile(_ fixes: [WalkHistoryFile.Fix]) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "WalkHistoryImportPerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "walks.mybodegas")
        try WalkHistoryFile.encode(fixes, exportedAt: Date(), appVersion: "perf").write(to: url)
        return url
    }
}

/// The process's peak physical footprint above where it stood at `init`,
/// sampled every 5 ms on a thread of its own until `stop()`.
final class PeakFootprint: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int
    private var isRunning = true
    private let baseline: Int

    init() {
        baseline = Self.footprint()
        peak = baseline
        Thread.detachNewThread { [self] in
            while lock.withLock({ isRunning }) {
                let now = Self.footprint()
                lock.withLock { peak = max(peak, now) }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    /// Bytes above the baseline at the highest sample.
    func stop() -> Int {
        let now = Self.footprint()
        return lock.withLock {
            isRunning = false
            return max(peak, now) - baseline
        }
    }

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
