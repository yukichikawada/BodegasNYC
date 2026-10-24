//
//  BlockMatchingActorTests.swift
//  BodegasNYCTests
//
//  The walked-block cache (#108 spec Implementation 4, AC7; eng R4, R8):
//  when a pass rebuilds, what it saves together, and the progress math.
//

import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

@MainActor
struct BlockMatchingActorTests {
    private typealias F = StreetFixtures

    private func makeActor(
        _ container: ModelContainer,
        stamp: UInt32 = 1,
        motion: FakeMotionProvider = FakeMotionProvider()
    ) -> BlockMatchingActor {
        BlockMatchingActor(
            container: container,
            activityProvider: motion,
            loadGrid: { F.cornerGrid(stamp: stamp) },
            onGridLoadFailure: { _ in }
        )
    }

    private func savedMasks(_ context: ModelContext) throws -> [UInt32: UInt16] {
        Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<WalkedBlock>()).map { ($0.physicalID, $0.mask) })
    }

    private func summary(_ outcome: BlockMatchingActor.Outcome) -> WalkedSummary? {
        if case .updated(let summary, _) = outcome { return summary }
        return nil
    }

    /// protects: a bundled dataset stamp that differs from the saved one
    /// triggers exactly one rebuild, which backfills history (AC7, eng R8:
    /// history from before #108 migrates unmatched).
    /// fails_when: no rebuild after a data refresh, or one on every pass.
    /// no_claim: SwiftData's lightweight migration of a real on-disk store.
    @Test func aStampChangeRebuildsExactlyOnce() async throws {
        let container = try makeInMemoryModelContainer()
        try F.seed(F.walk(from: (0, 12), to: (100, 12)), in: container.mainContext)

        let first = makeActor(container, stamp: 1)
        #expect(summary(await first.catchUp())?.walkedIDs == [100])
        _ = await first.catchUp()
        #expect(await first.rebuildCount == 1)

        let refreshed = makeActor(container, stamp: 2)
        #expect(summary(await refreshed.catchUp())?.walkedIDs == [100])
        _ = await refreshed.catchUp()
        _ = await refreshed.catchUp()
        #expect(await refreshed.rebuildCount == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<WalkedMatchState>()).map(\.datasetStamp) == [2])
    }

    /// protects: an unmatched fix older than the newest matched one (a late
    /// or deferred delivery) forces a full rebuild instead of an incremental
    /// pass that would mis-order the legs (AC7, eng R8).
    /// fails_when: the late fix is matched incrementally.
    /// no_claim: how often iOS delivers late.
    @Test func aLateFixForcesARebuild() async throws {
        let container = try makeInMemoryModelContainer()
        let actor = makeActor(container)
        try F.seed(F.walk(from: (0, 12), to: (40, 12), startTime: 600), in: container.mainContext)
        _ = await actor.catchUp()
        #expect(await actor.rebuildCount == 1)

        try F.seed(F.walk(from: (40, 12), to: (50, 12), startTime: 900).suffix(1), in: container.mainContext)
        _ = await actor.catchUp()
        #expect(await actor.rebuildCount == 1)

        let late = WalkedPointSnapshot(coordinate: F.coordinate(x: 0, y: 12), recordedAt: F.baseDate.addingTimeInterval(10))
        try F.seed([late], in: container.mainContext)
        _ = await actor.catchUp()
        #expect(await actor.rebuildCount == 2)
        let unmatched = try container.mainContext.fetchCount(FetchDescriptor<WalkedPoint>(predicate: #Predicate { !$0.isMatched }))
        #expect(unmatched == 0)
    }

    /// protects: passes over history delivered in batches save the same
    /// masks as one rebuild over all of it (the cache's version of AC6), and
    /// every matched fix is flipped.
    /// fails_when: the predecessor fix is not used to close the next leg,
    /// or a batch's masks overwrite instead of OR.
    /// no_claim: page boundaries (5,000 fixes; the perf test pages).
    @Test func batchedPassesEqualOneRebuild() async throws {
        let walk = F.walk(from: (0, 12), to: (100, 12)) + F.walk(from: (100, 12), to: (100, 70), startTime: 72).dropFirst()
        let batched = try makeInMemoryModelContainer()
        let actor = makeActor(batched)
        for batch in stride(from: 0, to: walk.count, by: 3) {
            try F.seed(Array(walk[batch ..< min(walk.count, batch + 3)]), in: batched.mainContext)
            _ = await actor.catchUp()
        }
        #expect(await actor.rebuildCount == 1)

        let whole = try makeInMemoryModelContainer()
        try F.seed(Array(walk), in: whole.mainContext)
        _ = await makeActor(whole).catchUp()

        #expect(try savedMasks(batched.mainContext) == savedMasks(whole.mainContext))
        #expect(try savedMasks(whole.mainContext) == BlockMatcher.match(Array(walk), grid: F.cornerGrid()))
        let unmatched = try batched.mainContext.fetchCount(FetchDescriptor<WalkedPoint>(predicate: #Predicate { !$0.isMatched }))
        #expect(unmatched == 0)
    }

    /// protects: a pass whose generation changed saves nothing: no masks,
    /// no flips, no stamp (eng R8/R9: one `save()` or none).
    /// fails_when: part of a cancelled pass is written.
    /// no_claim: a crash mid-save (SwiftData's transaction).
    @Test func aCancelledPassSavesNothing() async throws {
        let container = try makeInMemoryModelContainer()
        let motion = FakeMotionProvider()
        let actor = makeActor(container, motion: motion)
        try F.seed(F.walk(from: (0, 12), to: (100, 12)), in: container.mainContext)
        motion.holdNext()
        let pass = Task { await actor.catchUp() }
        await motion.waitUntilHeld()
        actor.invalidate()
        motion.release()

        guard case .cancelled = await pass.value else {
            Issue.record("expected the pass to be cancelled")
            return
        }
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<WalkedBlock>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<WalkedMatchState>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<WalkedPoint>(predicate: #Predicate { $0.isMatched })) == 0)
    }

    /// protects: the Clear History invariant (#113 item 2, eng R9): once the
    /// Clear's queued cache clear has run there are zero `WalkedBlock`s, no
    /// `WalkedMatchState`, no fix at or before the tap, every fix after the
    /// tap is kept, and the next pass counts only those. Holds whether the
    /// Clear lands before the pass's generation check (the pass drops) or
    /// after it, so the pass saves after the Clear's delete (the case the
    /// check cannot catch, as if there were no check).
    /// fails_when: a pass that saves after the Clear's delete leaves masks,
    /// a stamp or resurrected fixes behind the cache clear, a post-tap fix
    /// is lost, or the next pass still counts deleted history.
    /// no_claim: the view model's ordering (StreetsWalkedViewModelTests);
    /// a crash mid-save (SwiftData's transaction).
    @Test(arguments: [BlockMatchingActor.CommitPoint.beforeCheck, .beforeSave])
    func clearHistoryLeavesNoTraceWhereverItLandsInAPass(_ point: BlockMatchingActor.CommitPoint) async throws {
        let container = try makeInMemoryModelContainer()
        let tapTime = F.baseDate.addingTimeInterval(3_600)
        let beforeTap = F.walk(from: (0, 12), to: (100, 12))
        let afterTap = F.walk(from: (0, 68), to: (100, 68), startTime: 3_601)
        try F.seed(beforeTap, in: container.mainContext)
        let hook = CommitHook(at: point)
        let actor = BlockMatchingActor(
            container: container,
            activityProvider: FakeMotionProvider(),
            loadGrid: { F.cornerGrid() },
            onGridLoadFailure: { _ in },
            willCommit: { try hook.fire($0) }
        )
        // Clear History's tap in the view model's order (delete and save at
        // the tap, then the bump), then fixes that arrive after the tap.
        hook.setOnce {
            let context = ModelContext(container)
            try context.delete(model: WalkedPoint.self, where: #Predicate { $0.recordedAt <= tapTime })
            try context.save()
            actor.invalidate()
            for fix in afterTap {
                context.insert(
                    WalkedPoint(
                        id: fix.id,
                        latitude: fix.coordinate.latitude,
                        longitude: fix.coordinate.longitude,
                        recordedAt: fix.recordedAt
                    )
                )
            }
            try context.save()
        }

        let outcome = await actor.catchUp()
        #expect(hook.fired == 1)
        if point == .beforeCheck {
            // The check runs after staging, so a Clear before it drops the
            // whole pass even before the cache clear.
            guard case .cancelled = outcome else {
                Issue.record("expected the pass to be cancelled, got \(outcome)")
                return
            }
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<WalkedBlock>()) == 0)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<WalkedMatchState>()) == 0)
        }

        _ = await actor.clearCache()

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<WalkedBlock>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<WalkedMatchState>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<WalkedPoint>(predicate: #Predicate { $0.recordedAt <= tapTime })) == 0)
        let remaining = try context.fetch(FetchDescriptor<WalkedPoint>())
        #expect(Set(remaining.map(\.id)) == Set(afterTap.map(\.id)))

        let expected = BlockMatcher.match(afterTap, grid: F.cornerGrid())
        #expect(!expected.isEmpty)
        _ = await actor.catchUp()
        #expect(try savedMasks(ModelContext(container)) == expected)
    }

    /// protects: per-borough counts come from walked masks only, totals from
    /// the header, and the percent reads floor or "<1%" (spec
    /// Implementation 7).
    /// fails_when: a 5-tenth block counts, a borough total is off, the
    /// percent rounds up, or a nonzero count under 1% shows 0%.
    /// no_claim: the sheet's copy (#108 PR 2).
    @Test func progressMath() {
        let grid = StreetGrid(segments: [
            F.segment(1, [(0, 0), (100, 0)], borough: .manhattan),
            F.segment(2, [(0, 100), (100, 100)], borough: .manhattan),
            F.segment(3, [(0, 200), (100, 200)], borough: .queens)
        ])
        let summary = WalkedSummary(masks: [1: 0b11_1111, 2: 0b1_1111, 3: 0x3FF, 99: 0x3FF], grid: grid)
        #expect(summary.walkedIDs == [1, 3])
        #expect(summary.progress.map(\.borough) == Borough.displayOrder)
        #expect(summary.progress.first { $0.borough == .manhattan } == BoroughProgress(borough: .manhattan, walked: 1, total: 2))
        #expect(summary.progress.first { $0.borough == .queens }?.walked == 1)
        #expect(summary.citywide.walked == 2 && summary.citywide.total == 3)

        #expect(BoroughProgress.percent(walked: 0, total: 9_300) == .whole(0))
        #expect(BoroughProgress.percent(walked: 1, total: 9_300) == .lessThanOne)
        #expect(BoroughProgress.percent(walked: 92, total: 9_300) == .lessThanOne)
        #expect(BoroughProgress.percent(walked: 93, total: 9_300) == .whole(1))
        #expect(BoroughProgress.percent(walked: 412, total: 9_300) == .whole(4))
        #expect(BoroughProgress.percent(walked: 9_299, total: 9_300) == .whole(99))
        #expect(BoroughProgress.percent(walked: 9_300, total: 9_300) == .whole(100))
        #expect(BoroughProgress.percent(walked: 0, total: 0) == .whole(0))
    }
}

/// Runs a test's action once, from inside a pass, at one `CommitPoint`.
final class CommitHook: @unchecked Sendable {
    private let point: BlockMatchingActor.CommitPoint
    private let lock = NSLock()
    private var action: (@Sendable () throws -> Void)?
    private var _fired = 0
    var fired: Int { lock.withLock { _fired } }

    init(at point: BlockMatchingActor.CommitPoint) { self.point = point }

    func setOnce(_ action: @escaping @Sendable () throws -> Void) {
        lock.withLock { self.action = action }
    }

    func fire(_ reached: BlockMatchingActor.CommitPoint) throws {
        guard reached == point else { return }
        let pending = lock.withLock { () -> (@Sendable () throws -> Void)? in
            defer { action = nil }
            if action != nil { _fired += 1 }
            return action
        }
        try pending?()
    }
}
