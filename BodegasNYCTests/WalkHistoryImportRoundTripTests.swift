//
//  WalkHistoryImportRoundTripTests.swift
//  BodegasNYCTests
//
//  #180 PR 2: export and import end to end on real stores. The schema
//  upgrade (eng E3: two fixture stores written before `importBatch` existed
//  open with it nil), export → Clear → import restores the blocks and days
//  (AC 2 as eng A9 states it), the union of two histories equals matching
//  them from scratch (AC 4), and with a small injected cap every part of a
//  split export imports to the whole history (eng A2).
//

import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

@MainActor
struct WalkHistoryImportRoundTripTests {
    private typealias F = StreetFixtures

    private static let now = F.baseDate.addingTimeInterval(86_400 * 2)

    private static func makeDirectory() throws -> URL {
        let url = URL.temporaryDirectory.appending(
            path: "WalkHistoryImportRoundTripTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A copy of a bundled fixture store in a fresh directory, opened under
    /// today's schema. Never opened in place.
    private static func openFixture(_ name: String, in directory: URL) throws -> ModelContainer {
        let bundled = try #require(Bundle(for: FakeMotionProvider.self).url(forResource: name, withExtension: "store"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appending(path: "streets-walked.store")
        try FileManager.default.copyItem(at: bundled, to: copy)
        return try ModelContainer(for: Schema(StreetsWalkedSchema.models), configurations: ModelConfiguration(url: copy))
    }

    private struct Derived: Equatable {
        var masks: [UInt32: UInt16]
        var dayMasks: [Int: [Int: Int]]
        var dayMeters: [Int: Double]
    }

    private static func derived(_ container: ModelContainer) throws -> Derived {
        let context = ModelContext(container)
        let blocks = try context.fetch(FetchDescriptor<WalkedBlock>())
        var dayMasks: [Int: [Int: Int]] = [:]
        for row in try context.fetch(FetchDescriptor<WalkedDayBlock>()) {
            dayMasks[row.day, default: [:]][row.storedPhysicalID] = row.storedMask
        }
        let days = try context.fetch(FetchDescriptor<WalkedDay>())
        return Derived(
            masks: Dictionary(uniqueKeysWithValues: blocks.map { ($0.physicalID, $0.mask) }),
            dayMasks: dayMasks,
            dayMeters: Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0.meters) })
        )
    }

    /// Runs passes until the cache is current, CoreMotion unavailable.
    private static func match(_ container: ModelContainer, grid: StreetGrid) throws {
        let store = WalkedBlockStore(container: container, grid: grid, now: { [now = Self.now] in now })
        while let plan = try store.plan() {
            #expect(try store.apply(plan, activity: .unavailable) { true })
        }
    }

    private static func importAll(_ files: [URL], into container: ModelContainer) async throws {
        let transfer = WalkHistoryTransfer(container: container)
        for (index, file) in files.enumerated() {
            _ = try await transfer.inspect(file, request: index + 1, now: Self.now)
            #expect(try await transfer.commit(index + 1) { true } != .stale)
        }
    }

    // MARK: Upgrade (eng E3)

    /// protects=E3's lightweight migration: the real 1.0.0 store and the
    /// store written by main 6b96c40 (before `importBatch`) open under
    /// today's schema with `importBatch` nil on every fix and their rides,
    /// flags, masks and match state as written; fails_when=the new column
    /// has no default (no lightweight migration), or the upgrade touches
    /// history or the cache; no_claim=a device upgrade from the App Store
    /// build (owner check), stores from before 1.0.0.
    @Test func olderStoresOpenWithNoImportBatch() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let oneZero = try Self.openFixture("streets-walked-1.0.0", in: directory.appending(path: "a"))
        let oldPoints = try ModelContext(oneZero).fetch(FetchDescriptor<WalkedPoint>())
        #expect(oldPoints.count == 50)
        #expect(oldPoints.allSatisfy { $0.importBatch == nil && $0.isMatched && $0.ride == .unknown })
        #expect(try Self.derived(oneZero).masks == [3: 1023, 5: 1023, 6: 1023, 14: 511, 23: 511, 24: 255])

        let main = try Self.openFixture("streets-walked-6b96c40", in: directory.appending(path: "b"))
        let points = try ModelContext(main).fetch(FetchDescriptor<WalkedPoint>())
        #expect(points.count == 29)
        #expect(points.allSatisfy { $0.importBatch == nil && $0.isMatched })
        #expect(Dictionary(grouping: points, by: \.storedRide).mapValues(\.count) == [0: 8, 1: 10, 2: 11])
        #expect(try Self.derived(main).masks == [100: 510, 200: 2, 201: 510])
        let state = try #require(try ModelContext(main).fetch(FetchDescriptor<WalkedMatchState>()).first)
        #expect(state.datasetStamp == 1 && state.dayIndexVersion == 1 && state.estimatedThroughDay == nil)
        #expect(try ModelContext(main).fetchCount(FetchDescriptor<WalkedDayBlock>()) == 3)
    }

    /// protects=the spec's integration row: the 1.0.0 fixture store's whole
    /// history exports and imports into an empty store with every id, place
    /// and time; fails_when=a real old store does not survive the trip;
    /// no_claim=its blocks (the fixture was matched on the bundled grid;
    /// AC 2 below covers blocks).
    @Test func theOneZeroZeroStoreExportsAndImports() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try Self.openFixture("streets-walked-1.0.0", in: directory.appending(path: "old"))
        let export = try await WalkHistoryTransfer(container: old, exportRoot: directory.appending(path: "out"))
            .export(through: .distantFuture)
        let fresh = try makeInMemoryModelContainer()
        try await Self.importAll(export.files, into: fresh)
        let key: (WalkedPoint) -> String = { "\($0.id) \($0.latitude) \($0.longitude) \($0.recordedAt.timeIntervalSinceReferenceDate)" }
        let before = Set(try ModelContext(old).fetch(FetchDescriptor<WalkedPoint>()).map(key))
        let after = Set(try ModelContext(fresh).fetch(FetchDescriptor<WalkedPoint>()).map(key))
        #expect(before.count == 50)
        #expect(after == before)
    }

    // MARK: Round trips

    /// The walks of `RideEvidenceTests`, as one history: block 100, the
    /// slow ride on 300, the later walk down 201, and a walk the next day.
    /// Built once: each `F.walk` call makes new ids.
    private static let fixedHistory: [WalkedPointSnapshot] = F.walk(from: (0, 12), to: (100, 12))
        + F.walk(from: (0, 68), to: (100, 68), speed: 3, startTime: 600)
        + F.walk(from: (88, 68), to: (88, 12), startTime: 2_000)
        + F.walk(from: (12, 0), to: (12, 80), startTime: 86_400)

    private static func history() -> [WalkedPointSnapshot] { fixedHistory }

    /// protects=AC 2 as eng A9 states it: with CoreMotion unable to answer
    /// (as in the test), export → Clear History → import restores the same
    /// `WalkedBlock` masks and the same day rows and day distances;
    /// fails_when=an imported history derives different blocks or days
    /// than the one exported, or an import is matched incrementally;
    /// no_claim=histories whose unknown legs CoreMotion answered before the
    /// clear (A9: a rebuild may then classify them differently).
    @Test func exportClearImportRestoresBlocksAndDays() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grid = F.cornerGrid()
        let container = try makeInMemoryModelContainer()
        try F.seed(Self.history(), in: container.mainContext)
        try Self.match(container, grid: grid)
        let before = try Self.derived(container)
        #expect(!before.masks.isEmpty && before.dayMeters.count == 2)

        let export = try await WalkHistoryTransfer(container: container, exportRoot: directory)
            .export(through: .distantFuture)
        try container.mainContext.delete(model: WalkedPoint.self)
        try container.mainContext.save()
        try WalkedBlockStore.clearCache(in: container)
        try Self.match(container, grid: grid)
        #expect(try Self.derived(container).masks.isEmpty)

        try await Self.importAll(export.files, into: container)
        try Self.match(container, grid: grid)
        #expect(try Self.derived(container) == before)
    }

    /// protects=AC 4: importing a file into a store holding other history
    /// yields every fix from both, none duplicated, and masks and days equal
    /// to matching the combined history from scratch; fails_when=the merge
    /// drops or duplicates fixes, or an incremental pass over out-of-order
    /// imports derives something else; no_claim=two phones recording the
    /// same walk (A11, documented).
    @Test func theUnionEqualsMatchingFromScratch() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grid = F.cornerGrid()
        let all = Self.history()
        let mine = Array(all.enumerated().filter { $0.offset % 3 != 0 }.map(\.element))
        let theirs = Array(all.enumerated().filter { $0.offset % 3 != 1 }.map(\.element)) // overlaps mine

        let source = try makeInMemoryModelContainer()
        try F.seed(theirs, in: source.mainContext)
        let export = try await WalkHistoryTransfer(container: source, exportRoot: directory).export(through: .distantFuture)

        let container = try makeInMemoryModelContainer()
        try F.seed(mine, in: container.mainContext)
        try Self.match(container, grid: grid)
        try await Self.importAll(export.files, into: container)
        try Self.match(container, grid: grid)
        let ids = try ModelContext(container).fetch(FetchDescriptor<WalkedPoint>()).map(\.id)
        #expect(ids.count == all.count)
        #expect(Set(ids) == Set(all.map(\.id)))

        let scratch = try makeInMemoryModelContainer()
        try F.seed(all, in: scratch.mainContext)
        try Self.match(scratch, grid: grid)
        #expect(try Self.derived(container).masks == Self.derived(scratch).masks)
        #expect(try Self.derived(container).dayMasks == Self.derived(scratch).dayMasks)
    }

    /// protects=eng A2: with a small injected cap, a history over it exports
    /// as parts, every part imports (merge-only makes parts composable), and
    /// the union is exactly the store; fails_when=a valid export cannot be
    /// imported, or a part is refused as too large; no_claim=the measured
    /// cap (WalkHistoryPerformanceTests).
    @Test func everyPartOfASplitExportImports() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cap = 7
        let source = try makeInMemoryModelContainer()
        try F.seed(Self.history(), in: source.mainContext)
        let export = try await WalkHistoryTransfer(container: source, exportRoot: directory, maxFixCount: cap)
            .export(through: .distantFuture)
        #expect(export.files.count == WalkHistoryFile.partCount(fixCount: Self.history().count, maxFixCount: cap))
        #expect(export.files.count > 1)

        let target = try makeInMemoryModelContainer()
        let transfer = WalkHistoryTransfer(container: target, maxFixCount: cap)
        for (index, file) in export.files.enumerated() {
            _ = try await transfer.inspect(file, request: index + 1, now: Self.now)
            #expect(try await transfer.commit(index + 1) { true } != .stale)
        }
        let ids = try ModelContext(target).fetch(FetchDescriptor<WalkedPoint>()).map(\.id)
        #expect(ids.count == Self.history().count)
        #expect(Set(ids) == Set(Self.history().map(\.id)))
    }
}
