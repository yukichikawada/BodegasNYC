//
//  WalkedDayStoreTests.swift
//  BodegasNYCTests
//
//  Day rows in the Streets Walked store (#170 PR 1, spec rules 3 to 6, AC 1,
//  2, 5; eng A1, A2, A3, A6): written in each pass's one save beside the
//  masks, batching-invariant, backfilled once from matched history and
//  clamped to the saved masks, cleared with Clear History, and read back as
//  `WalkedHistory` that stays current in memory. Walks run on the fixture
//  corner grid, anchored at noon New York time (eng A10), except the 1.0.0
//  store, which was matched against the bundle.
//

import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

@MainActor
struct WalkedDayStoreTests {
    private typealias F = StreetFixtures
    private typealias K = WalkedDayKeyTests

    private static let monday = K.newYork(2027, 1, 18, 12)
    private static let tuesday = K.newYork(2027, 1, 19, 12)
    private static let thursday = K.newYork(2027, 1, 21, 12)

    /// Monday: block 100, then cross street 201. Tuesday: block 100 again
    /// (a repeat) and block 300 (new). Thursday: block 400.
    private static let history =
        K.walk((0, 12), (100, 12), at: monday)
        + K.walk((88, 12), (88, 80), at: monday.addingTimeInterval(1_800))
        + K.walk((0, 12), (100, 12), at: tuesday)
        + K.walk((0, 68), (100, 68), at: tuesday.addingTimeInterval(1_800))
        + K.walk((100, 12), (200, 12), at: thursday)

    /// `history`, then half an hour after Thursday's walk ten minutes of
    /// pacing on block 400: twenty fixes 30 s apart alternating between
    /// (140, 0) and (160, 0). Its legs from the eighth on are standing
    /// still (#192), and every batch size below puts a boundary inside it.
    private static let dwellHistory = history + (0 ..< 20).map { step in
        WalkedPointSnapshot(
            coordinate: F.coordinate(x: step % 2 == 0 ? 140 : 160, y: 0),
            recordedAt: thursday.addingTimeInterval(1_800 + Double(step) * 30)
        )
    }

    private func savedMasks(_ container: ModelContainer) throws -> [UInt32: UInt16] {
        Dictionary(uniqueKeysWithValues: try ModelContext(container).fetch(FetchDescriptor<WalkedBlock>()).map { ($0.physicalID, $0.mask) })
    }

    private struct DayRow: Hashable {
        let day: Int
        let id: UInt32
        let mask: UInt16
    }

    private func dayRows(_ container: ModelContainer) throws -> Set<DayRow> {
        Set(try ModelContext(container).fetch(FetchDescriptor<WalkedDayBlock>()).map { DayRow(day: $0.day, id: $0.physicalID, mask: $0.mask) })
    }

    private func dayMeters(_ container: ModelContainer) throws -> [Int: Double] {
        Dictionary(uniqueKeysWithValues: try ModelContext(container).fetch(FetchDescriptor<WalkedDay>()).map { ($0.day, $0.meters) })
    }

    private struct StateValues: Equatable {
        let dayIndexVersion: Int
        let estimatedThroughDay: Int?
    }

    private func state(_ container: ModelContainer) throws -> StateValues? {
        try ModelContext(container).fetch(FetchDescriptor<WalkedMatchState>()).first.map {
            StateValues(dayIndexVersion: $0.dayIndexVersion, estimatedThroughDay: $0.estimatedThroughDay)
        }
    }

    private func setMask(_ mask: UInt16, of physicalID: UInt32, in container: ModelContainer) throws {
        let context = ModelContext(container)
        let block = try #require(try context.fetch(FetchDescriptor<WalkedBlock>()).first { $0.physicalID == physicalID })
        block.mask = mask
        try context.save()
    }

    /// Every block's day masks ORed together.
    private func dayUnion(_ container: ModelContainer) throws -> [UInt32: UInt16] {
        var union: [UInt32: UInt16] = [:]
        for row in try dayRows(container) { union[row.id, default: 0] |= row.mask }
        return union
    }

    /// A2: every block's total mask is the OR of its day masks. Holds only
    /// when each saved mask is a subset of what re-matching history gives
    /// (always true for masks this matcher wrote); a saved bit no re-match
    /// produces has no day to go to (`aSavedBitNoRematchGivesStaysInTheTotalsOnly`).
    private func expectTotalsAreTheOROfTheDaysWhenSavedIsASubsetOfARematch(
        _ container: ModelContainer,
        _ note: Comment
    ) throws {
        let union = try dayUnion(container)
        let saved = try savedMasks(container)
        #expect(union == saved, "\(note): days \(union), totals \(saved)")
    }

    private func pass(_ store: WalkedBlockStore, allowsBackfill: Bool = true) throws -> WalkedPassKind? {
        guard let plan = try store.plan(allowsBackfill: allowsBackfill) else { return nil }
        #expect(try store.apply(plan, activity: .unavailable) { true })
        return plan.kind
    }

    /// Makes `container` look like a store from before #170: day rows gone,
    /// day index version 0.
    private func rewindToBeforeDays(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<WalkedDayBlock>()) { context.delete(row) }
        for day in try context.fetch(FetchDescriptor<WalkedDay>()) { context.delete(day) }
        for state in try context.fetch(FetchDescriptor<WalkedMatchState>()) {
            state.dayIndexVersion = 0
            state.estimatedThroughDay = nil
        }
        try context.save()
    }

    // MARK: Writes

    /// protects: AC 2 and A2: the same history matched in one batch and in
    /// many gives identical day rows and meters (within 0.001 m), and the
    /// totals are the OR of the days after incremental passes and after a
    /// rebuild. #192 AC 7: with a batch boundary inside a stretch of
    /// standing still, the meters still agree (the incremental pass loads
    /// the look-back), and Thursday's are the 90 m of its walk plus the
    /// 7 x 20 m of pacing before the dwell starts.
    /// fails_when: a batch boundary moves a leg's day, meters double-count
    /// the predecessor leg, an incremental pass overwrites instead of ORing,
    /// a rebuild leaves stale rows, or an incremental pass judges standing
    /// still without the fixes before its batch.
    /// no_claim: the bundle's real blocks (the 1.0.0 test below).
    @Test(arguments: [1, 3, 7])
    func batchesGiveTheSameDayRowsAsOnePass(batchSize: Int) throws {
        let history = Self.dwellHistory
        let whole = try makeInMemoryModelContainer()
        try F.seed(history, in: whole.mainContext)
        #expect(try pass(WalkedBlockStore(container: whole, grid: F.cornerGrid())) == .rebuild)

        let batched = try makeInMemoryModelContainer()
        let store = WalkedBlockStore(container: batched, grid: F.cornerGrid())
        var start = 0
        while start < history.count {
            let end = min(start + batchSize, history.count)
            try F.seed(Array(history[start ..< end]), in: batched.mainContext)
            _ = try pass(store)
            start = end
        }
        #expect(try dayRows(batched) == dayRows(whole))
        let wholeMeters = try dayMeters(whole)
        let batchedMeters = try dayMeters(batched)
        #expect(Set(wholeMeters.keys) == Set(batchedMeters.keys))
        for (day, meters) in wholeMeters {
            #expect(abs((batchedMeters[day] ?? -1) - meters) < 0.001, "day \(day)")
        }
        #expect(abs((wholeMeters[20270121] ?? -1) - (90 + 7 * 20)) < 0.01, "\(wholeMeters)")
        #expect(Set(wholeMeters.keys) == [20270118, 20270119, 20270121])
        try expectTotalsAreTheOROfTheDaysWhenSavedIsASubsetOfARematch(batched, "incremental")
        try expectTotalsAreTheOROfTheDaysWhenSavedIsASubsetOfARematch(whole, "rebuild")

        // A data refresh rebuilds the batched store: same rows again.
        _ = try pass(WalkedBlockStore(container: batched, grid: F.cornerGrid(stamp: 2)))
        #expect(try dayRows(batched) == dayRows(whole))
        try expectTotalsAreTheOROfTheDaysWhenSavedIsASubsetOfARematch(batched, "rebuild after batches")
        #expect(try state(batched)?.dayIndexVersion == WalkedBlockStore.dayIndexVersion)
    }

    /// protects: #192 AC 7's plan (eng E3): an incremental pass's snapshots
    /// begin with the matched fixes of the 300 s before its oldest new fix,
    /// the newest 64 at most, and `firstNewIndex` points at the first new
    /// fix; when the newest matched fix is older than 300 s it alone leads
    /// (index 1); ride evidence is still asked only from the predecessor on.
    /// fails_when: the context is missing, unbounded, skips the
    /// predecessor, or `firstNewIndex` is off by one.
    /// no_claim: the meters that follow (the batch test above).
    @Test func anIncrementalPlanLeadsWithFiveMinutesOfMatchedFixes() throws {
        let container = try makeInMemoryModelContainer()
        let store = WalkedBlockStore(container: container, grid: F.cornerGrid())
        func fix(_ seconds: TimeInterval, x: Double = 50) -> WalkedPointSnapshot {
            WalkedPointSnapshot(coordinate: F.coordinate(x: x, y: 0), recordedAt: Self.monday.addingTimeInterval(seconds))
        }
        func planAfter(_ new: WalkedPointSnapshot) throws -> WalkedBlockStore.Plan {
            try F.seed([new], in: container.mainContext)
            let plan = try #require(try store.plan())
            #expect(plan.kind == .incremental)
            #expect(plan.snapshots.last?.id == new.id)
            #expect(plan.snapshots[plan.firstNewIndex].id == new.id)
            return plan
        }

        // 20 fixes 30 s apart (0 to 570 s), then one at 600 s: the ten at
        // 300 s and later lead.
        let sparse = (0 ..< 20).map { fix(Double($0) * 30, x: $0 % 2 == 0 ? 40 : 60) }
        try F.seed(sparse, in: container.mainContext)
        #expect(try pass(store) == .rebuild)
        let first = try planAfter(fix(600))
        #expect(first.snapshots.dropLast().map(\.id) == sparse.suffix(10).map(\.id))
        #expect(first.firstNewIndex == 10)
        #expect(first.legSnapshots.map(\.id) == [sparse[19].id, first.snapshots[10].id])
        #expect(try store.apply(first, activity: .unavailable) { true })

        // 100 fixes 3 s apart (603 to 900 s), then one at 903 s: all 100
        // are in the window, the newest 64 lead.
        let dense = (0 ..< 100).map { fix(603 + Double($0) * 3, x: $0 % 2 == 0 ? 40 : 50) }
        try F.seed(dense, in: container.mainContext)
        _ = try pass(store)
        let second = try planAfter(fix(903))
        #expect(second.snapshots.dropLast().map(\.id) == dense.suffix(64).map(\.id))
        #expect(second.firstNewIndex == 64)
        #expect(try store.apply(second, activity: .unavailable) { true })

        // Ten minutes later: nothing matched in the window, the newest
        // matched fix (903 s) alone leads.
        let third = try planAfter(fix(1_503))
        #expect(third.snapshots.count == 2 && third.firstNewIndex == 1)
        #expect(third.snapshots[0].recordedAt == Self.monday.addingTimeInterval(903))
        #expect(third.legSnapshots.count == 2)
    }

    // MARK: Upgrade to street meters (#192 AC 8, 9; eng E4)

    /// protects: #192 AC 8 and 9: a store whose day rows are at version 1
    /// (old-rule meters) backfills exactly once and no rebuild; every
    /// `WalkedBlock` and day mask stays as saved; every `WalkedDay.meters`
    /// becomes what a fresh match of the same fixes gives; the saved
    /// `estimatedThroughDay` is kept exactly (nil, or a day the backfill
    /// rule would not pick), on fixes with no ride evidence whose newest
    /// day the backfill rule would mark; a second launch plans nothing.
    /// fails_when: the backfill keeps the old meters, touches the masks,
    /// re-derives the estimate (marking Thursday), or runs again.
    /// no_claim: a real phone's store (QA's replay, AC 11); version 0
    /// stores, which still take the backfill rule
    /// (`aBackfillLeavesEveryMaskAsSavedAndClampsTheDays`).
    @Test(arguments: [nil, 20270119] as [Int?])
    func aVersionOneStoreBackfillsOnceAndKeepsItsEstimate(saved: Int?) throws {
        let container = try makeInMemoryModelContainer()
        try F.seed(Self.history, in: container.mainContext)
        _ = try pass(WalkedBlockStore(container: container, grid: F.cornerGrid()))
        let context = ModelContext(container)
        for day in try context.fetch(FetchDescriptor<WalkedDay>()) { day.meters = 12_345 }
        for state in try context.fetch(FetchDescriptor<WalkedMatchState>()) {
            state.dayIndexVersion = 1
            state.estimatedThroughDay = saved
        }
        try context.save()
        let masks = try savedMasks(container)
        let rows = try dayRows(container)

        let dayAfter = Self.thursday.addingTimeInterval(86_400)
        #expect(WalkedEstimate.throughDay(Self.history, found: [:], now: dayAfter, window: 0) == WalkedDayKey(value: 20270121))
        let store = WalkedBlockStore(container: container, grid: F.cornerGrid(), now: { dayAfter })
        #expect(try pass(store) == .backfill)
        #expect(store.backfillCount == 1 && store.rebuildCount == 0)
        #expect(try savedMasks(container) == masks)
        #expect(try dayRows(container) == rows)
        let fresh = BlockMatcher.matchByDay(Self.history, grid: F.cornerGrid()).days
        let meters = try dayMeters(container)
        #expect(Set(meters.keys) == Set(fresh.keys.map(\.value)))
        for (day, delta) in fresh {
            #expect(abs((meters[day.value] ?? -1) - delta.meters) < 0.001, "day \(day.value)")
        }
        #expect(try state(container) == StateValues(dayIndexVersion: WalkedBlockStore.dayIndexVersion, estimatedThroughDay: saved))
        #expect(store.days?.estimatedThroughDay == saved.map(WalkedDayKey.init(value:)))
        #expect(try pass(store) == nil)
        #expect(try WalkedBlockStore(container: container, grid: F.cornerGrid(), now: { dayAfter }).plan() == nil)
    }

    /// protects: #192 AC 8 and 9 on a real version 1 file
    /// (`Fixtures/streets-walked-6b96c40`, written by main before #180 PR 2
    /// with day index version 1 and no estimate): it backfills once, keeps
    /// its three masks byte for byte and its nil estimate (the backfill rule
    /// would set one: its last walk has no ride evidence), and its day
    /// meters become a fresh match's.
    /// fails_when: the real file's saved version does not trigger the
    /// backfill, or the backfill re-derives the estimate or touches masks.
    /// no_claim: an App Store device upgrade (QA's seeded simulator run).
    @Test func theSixB96C40StoreBackfillsOnceAndKeepsItsEstimate() throws {
        let bundled = try #require(Bundle(for: FakeMotionProvider.self).url(forResource: "streets-walked-6b96c40", withExtension: "store"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("streets-walked.store")
        try FileManager.default.copyItem(at: bundled, to: copy)

        let container = try ModelContainer(for: Schema(StreetsWalkedSchema.models), configurations: ModelConfiguration(url: copy))
        #expect(try state(container) == StateValues(dayIndexVersion: 1, estimatedThroughDay: nil))
        let masks = try savedMasks(container)
        #expect(masks == [100: 510, 200: 2, 201: 510])
        let points = try ModelContext(container).fetch(FetchDescriptor<WalkedPoint>())
            .map(WalkedBlockStore.snapshot).sorted(by: WalkedPointSnapshot.sortsBefore)
        let later = F.baseDate.addingTimeInterval(86_400 * 30)
        #expect(WalkedEstimate.throughDay(points, found: [:], now: later, window: 0) != nil)

        let store = WalkedBlockStore(container: container, grid: F.cornerGrid(), now: { later })
        #expect(try pass(store) == .backfill)
        #expect(try pass(store) == nil)
        #expect(store.backfillCount == 1 && store.rebuildCount == 0)
        #expect(try savedMasks(container) == masks)
        #expect(try state(container) == StateValues(dayIndexVersion: WalkedBlockStore.dayIndexVersion, estimatedThroughDay: nil))
        let fresh = BlockMatcher.matchByDay(points, grid: F.cornerGrid()).days
        let meters = try dayMeters(container)
        #expect(Set(meters.keys) == Set(fresh.keys.map(\.value)))
        for (day, delta) in fresh {
            #expect(abs((meters[day.value] ?? -1) - delta.meters) < 0.001, "day \(day.value)")
        }
        #expect(try WalkedBlockStore(container: container, grid: F.cornerGrid(), now: { later }).plan() == nil)
    }

    // MARK: Backfill (AC 1, eng A1)

    /// protects: AC 1 on the fixture grid: a store from before #170 runs
    /// exactly one backfill and no rebuild; every `WalkedBlock` row is what
    /// it was, including a saved mask a fresh match would enlarge; no day
    /// mask has a bit outside its block's saved mask; the next plan is
    /// nothing at all.
    /// fails_when: the backfill rebuilds or writes masks, a day row claims a
    /// tenth the totals do not, or the version is not saved.
    /// no_claim: a real 1.0.0 file (the next test).
    @Test func aBackfillLeavesEveryMaskAsSavedAndClampsTheDays() throws {
        let container = try makeInMemoryModelContainer()
        try F.seed(Self.history, in: container.mainContext)
        _ = try pass(WalkedBlockStore(container: container, grid: F.cornerGrid()))
        try rewindToBeforeDays(container)
        // A saved mask smaller than a fresh match (tenths 1 to 9; tenth 0
        // snaps to cross street 200): 6 of block 100's tenths.
        try setMask(0b111_1110, of: 100, in: container)
        let before = try savedMasks(container)

        // A day after the last walk: under 7 days, but the backfill asks no
        // CoreMotion, so its newest unknown day is still an estimate.
        let dayAfter = Self.thursday.addingTimeInterval(86_400)
        let store = WalkedBlockStore(container: container, grid: F.cornerGrid(), now: { dayAfter })
        #expect(try pass(store) == .backfill)
        #expect(store.rebuildCount == 0 && store.backfillCount == 1)
        #expect(try state(container)?.estimatedThroughDay == 20270121)
        #expect(try savedMasks(container) == before)
        for row in try dayRows(container) {
            #expect(row.mask & ~(before[row.id] ?? 0) == 0, "day \(row.day) block \(row.id)")
        }
        let blockRows = try dayRows(container).filter { $0.id == 100 }.sorted { $0.day < $1.day }
        #expect(blockRows.map(\.mask) == [0b111_1110, 0b111_1110], "\(blockRows)")
        try expectTotalsAreTheOROfTheDaysWhenSavedIsASubsetOfARematch(container, "backfill")
        #expect(try state(container)?.dayIndexVersion == WalkedBlockStore.dayIndexVersion)
        #expect(try store.plan() == nil)
        #expect(try WalkedBlockStore(container: container, grid: F.cornerGrid()).plan() == nil)
    }

    /// protects: the backfill's honest outcome when a saved mask holds a
    /// tenth no re-match of history produces (an older matcher's bit): the
    /// totals stay exactly as saved, the day rows never invent a day for the
    /// leftover bit, so their OR is a strict subset of the total, and
    /// history still loads.
    /// fails_when: the backfill drops the bit from the totals, attributes it
    /// to some day, or fails on it.
    /// no_claim: where the bit came from; that Your Walks' cumulative count
    /// matches Your Blocks in this case (it can fall below; PR 2 reads the
    /// headline count from the totals).
    @Test func aSavedBitNoRematchGivesStaysInTheTotalsOnly() throws {
        let container = try makeInMemoryModelContainer()
        try F.seed(Self.history, in: container.mainContext)
        _ = try pass(WalkedBlockStore(container: container, grid: F.cornerGrid()))
        // Block 100's tenth 0 always snaps to cross street 200, so no
        // re-match gives it; a saved mask with it set is a leftover.
        let rematch = try #require(try savedMasks(container)[100])
        #expect(rematch & 1 == 0 && BlockMatcher.isWalked(mask: rematch))
        try rewindToBeforeDays(container)
        try setMask(rematch | 1, of: 100, in: container)
        let before = try savedMasks(container)

        let store = WalkedBlockStore(container: container, grid: F.cornerGrid())
        #expect(try pass(store) == .backfill)
        #expect(try savedMasks(container) == before)
        let union = try dayUnion(container)
        #expect(union[100] == rematch)
        #expect(union.keys.sorted() == before.keys.sorted())
        #expect(union.allSatisfy { id, mask in mask & ~(before[id] ?? 0) == 0 })
        #expect(union != before)
        #expect(try store.history()?.walkedDays.isEmpty == false)
    }

    /// protects: A1's scope: the backfill matches only matched fixes; the
    /// unmatched ones take the incremental pass the actor runs right after,
    /// in the same job, and a store with both stamp and version stale runs
    /// one rebuild and no backfill.
    /// fails_when: the backfill flips or credits unmatched fixes, the
    /// actor stops after the backfill, or a stale stamp backfills first.
    /// no_claim: CoreMotion (no activity in these passes).
    @Test func theActorBackfillsThenMatchesTheRest() async throws {
        let container = try makeInMemoryModelContainer()
        // Monday's two walks are 11 + 8 fixes.
        let monday = Array(Self.history.prefix(19))
        #expect(monday.allSatisfy { WalkedDayKey(date: $0.recordedAt) == WalkedDayKey(value: 20270118) })
        try F.seed(monday, in: container.mainContext)
        _ = try pass(WalkedBlockStore(container: container, grid: F.cornerGrid()))
        try rewindToBeforeDays(container)
        try F.seed(Array(Self.history.dropFirst(19)), in: container.mainContext)

        let probe = WalkedBlockStore(container: container, grid: F.cornerGrid())
        let plan = try #require(try probe.plan())
        #expect(plan.kind == .backfill)
        #expect(plan.snapshots.count == monday.count && plan.unmatched.isEmpty)

        let actor = BlockMatchingActor(container: container, activityProvider: FakeMotionProvider(), loadGrid: { F.cornerGrid() }, onGridLoadFailure: { _ in })
        guard case .updated(let summary, _) = await actor.catchUp() else {
            Issue.record("the pass did not save")
            return
        }
        #expect(await actor.backfillCount == 1)
        #expect(await actor.rebuildCount == 0)
        #expect(summary.walkedIDs == [100, 201, 300, 400])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<WalkedPoint>(predicate: #Predicate { $0.isMatched == false })) == 0)
        try expectTotalsAreTheOROfTheDaysWhenSavedIsASubsetOfARematch(container, "backfill then incremental")

        // Both stale: one rebuild, no backfill.
        try rewindToBeforeDays(container)
        let refreshed = BlockMatchingActor(container: container, activityProvider: FakeMotionProvider(), loadGrid: { F.cornerGrid(stamp: 2) }, onGridLoadFailure: { _ in })
        _ = await refreshed.catchUp()
        #expect(await refreshed.rebuildCount == 1)
        #expect(await refreshed.backfillCount == 0)
        #expect(try state(container)?.dayIndexVersion == WalkedBlockStore.dayIndexVersion)
    }

    /// protects: eng A6: a backfill that throws does not block the summary:
    /// the pass still returns the saved masks, history reports failed, the
    /// version stays 0, and the next pass retries and succeeds.
    /// fails_when: a failed backfill fails the whole pass, saves a version,
    /// or is never retried.
    /// no_claim: which SwiftData error; the sheet's failure line (the
    /// content tests).
    @Test func aFailedBackfillStillCountsAndRetries() async throws {
        let container = try makeInMemoryModelContainer()
        try F.seed(Self.history, in: container.mainContext)
        _ = try pass(WalkedBlockStore(container: container, grid: F.cornerGrid()))
        try rewindToBeforeDays(container)
        let commits = FailingCommits(failures: 1, at: .beforeCheck)
        let actor = BlockMatchingActor(
            container: container,
            activityProvider: FakeMotionProvider(),
            loadGrid: { F.cornerGrid() },
            onGridLoadFailure: { _ in },
            willCommit: { try commits.attempt($0) }
        )

        guard case .updated(let summary, _) = await actor.catchUp() else {
            Issue.record("a failed backfill blocked the summary")
            return
        }
        #expect(summary.walkedIDs == [100, 201, 300, 400])
        guard case .failed = await actor.history() else {
            Issue.record("history should report the failed backfill")
            return
        }
        #expect(try state(container)?.dayIndexVersion == 0)

        _ = await actor.catchUp()
        #expect(await actor.backfillCount == 1)
        guard case .ready(let history) = await actor.history() else {
            Issue.record("the retried backfill did not make history ready")
            return
        }
        #expect(history.walkedDays.map(\.day.value) == [20270118, 20270119, 20270121])
    }

    /// protects: AC 1 and P0-4 on the real 1.0.0 store file
    /// (`Fixtures/streets-walked-1.0.0`): it opens under the new schema,
    /// backfills exactly once with no rebuild, keeps every `WalkedBlock`
    /// byte for byte (including one shrunk below what a fresh match gives),
    /// clamps the day rows, records the estimate for history older than 7
    /// days, and a second launch plans nothing.
    /// fails_when: the new entities or state fields break lightweight
    /// migration, the backfill touches the totals, or it runs twice.
    /// no_claim: stores from before 1.0.0; an App Store device upgrade.
    @Test func theOneZeroZeroStoreBackfillsOnceAndKeepsItsBlocks() throws {
        let bundled = try #require(Bundle(for: FakeMotionProvider.self).url(forResource: "streets-walked-1.0.0", withExtension: "store"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("streets-walked.store")
        try FileManager.default.copyItem(at: bundled, to: copy)

        let container = try ModelContainer(for: Schema(StreetsWalkedSchema.models), configurations: ModelConfiguration(url: copy))
        #expect(try state(container) == StateValues(dayIndexVersion: 0, estimatedThroughDay: nil))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<WalkedDayBlock>()) == 0)
        try setMask(0b11_1111_0000, of: 3, in: container)
        let before = try savedMasks(container)
        #expect(before == [3: 0b11_1111_0000, 5: 1023, 6: 1023, 14: 511, 23: 511, 24: 255])

        // Months after the fixture's 2027 walk, so all of it is past 7 days.
        let later = K.newYork(2027, 6, 1, 12)
        let grid = try StreetGrid.loadBundled()
        let store = WalkedBlockStore(container: container, grid: grid, now: { later })
        #expect(try pass(store) == .backfill)
        #expect(try pass(store) == nil)
        #expect(store.rebuildCount == 0 && store.backfillCount == 1)
        #expect(try savedMasks(container) == before)
        try expectTotalsAreTheOROfTheDaysWhenSavedIsASubsetOfARematch(container, "1.0.0 backfill")
        let points = try ModelContext(container).fetch(FetchDescriptor<WalkedPoint>(sortBy: [SortDescriptor(\.recordedAt)]))
        let newest = try #require(points.last)
        #expect(try state(container)?.dayIndexVersion == WalkedBlockStore.dayIndexVersion)
        #expect(try state(container)?.estimatedThroughDay == WalkedDayKey(date: newest.recordedAt).value)
        let history = try #require(try store.history())
        #expect(history.cumulative.last?.count == WalkedSummary(masks: before, grid: grid).citywide.walked)

        #expect(try WalkedBlockStore(container: container, grid: grid, now: { later }).plan() == nil)
    }

    // MARK: Clear (AC 5)

    /// protects: AC 5: Clear History leaves no day rows, including when it
    /// lands inside a pass after its check (the pass saves after the Clear's
    /// delete; #113's seam test, extended), and the next pass writes days
    /// for the surviving fixes only.
    /// fails_when: `clearCache` misses either day model, or the in-memory
    /// history keeps cleared days.
    /// no_claim: the view model's ordering (StreetsWalkedViewModelTests).
    @Test(arguments: [BlockMatchingActor.CommitPoint.beforeCheck, .beforeSave])
    func clearHistoryLeavesNoDayRows(_ point: BlockMatchingActor.CommitPoint) async throws {
        let container = try makeInMemoryModelContainer()
        let beforeTap = K.walk((0, 12), (100, 12), at: Self.monday)
        let tapTime = Self.monday.addingTimeInterval(3_600)
        let afterTap = K.walk((0, 68), (100, 68), at: Self.thursday)
        try F.seed(beforeTap, in: container.mainContext)
        let hook = CommitHook(at: point)
        let actor = BlockMatchingActor(
            container: container,
            activityProvider: FakeMotionProvider(),
            loadGrid: { F.cornerGrid() },
            onGridLoadFailure: { _ in },
            willCommit: { try hook.fire($0) }
        )
        hook.setOnce {
            let context = ModelContext(container)
            try context.delete(model: WalkedPoint.self, where: #Predicate { $0.recordedAt <= tapTime })
            try context.save()
            actor.invalidate()
            for fix in afterTap {
                context.insert(WalkedPoint(id: fix.id, latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, recordedAt: fix.recordedAt))
            }
            try context.save()
        }
        _ = await actor.catchUp()
        _ = await actor.clearCache()

        #expect(try ModelContext(container).fetchCount(FetchDescriptor<WalkedDayBlock>()) == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<WalkedDay>()) == 0)
        guard case .ready(let cleared) = await actor.history() else {
            Issue.record("history after a clear should be ready and empty")
            return
        }
        #expect(cleared.days.isEmpty)

        _ = await actor.catchUp()
        #expect(try Set(dayRows(container).map(\.day)) == [20270121])
        guard case .ready(let after) = await actor.history() else {
            Issue.record("history after the next pass should be ready")
            return
        }
        #expect(after.walkedDays.map(\.day.value) == [20270121])
    }

    // MARK: In-memory history (eng A3)

    /// protects: A3: history loaded once and kept current from each pass's
    /// day delta equals a fresh load from disk after every pass; `version`
    /// moves after a pass that changed a day, including a repeat walk that
    /// changes no total mask, and not after a pass that changed nothing.
    /// fails_when: a delta is dropped or double-applied, the cache is not
    /// refreshed after a repeat walk, or the version moves for nothing.
    /// no_claim: performance (WalkedBlocksPerformanceTests).
    @Test func historyKeptInMemoryEqualsAFreshLoad() throws {
        let container = try makeInMemoryModelContainer()
        let store = WalkedBlockStore(container: container, grid: F.cornerGrid())
        try F.seed(Array(Self.history.prefix(11)), in: container.mainContext)
        _ = try pass(store)
        var version = try #require(try store.history()).version

        func expectFresh(_ note: Comment) throws -> WalkedHistory {
            let kept = try #require(try store.history())
            let fresh = try #require(try WalkedBlockStore(container: container, grid: F.cornerGrid()).history())
            #expect(kept.days == fresh.days, note)
            #expect(kept.cumulative == fresh.cumulative, note)
            return kept
        }

        for part in [Self.history.dropFirst(11).prefix(11), Self.history.dropFirst(22).prefix(11), Self.history.dropFirst(33)] {
            try F.seed(Array(part), in: container.mainContext)
            _ = try pass(store)
            let kept = try expectFresh("after a pass")
            #expect(kept.version > version)
            version = kept.version
        }
        #expect(try pass(store) == nil)
        #expect(try store.history()?.version == version, "no pass, no new version")

        // Tuesday again, an hour later: block 100 a third time, no total changes.
        let masks = try savedMasks(container)
        try F.seed(K.walk((0, 12), (100, 12), at: Self.tuesday.addingTimeInterval(3_600)), in: container.mainContext)
        _ = try pass(store)
        #expect(try savedMasks(container) == masks)
        let repeated = try expectFresh("after a repeat walk")
        #expect(repeated.version > version)
        #expect(repeated.summary(for: WalkedDayKey(value: 20270119))?.walkedIDs == [100, 300])
    }
}
