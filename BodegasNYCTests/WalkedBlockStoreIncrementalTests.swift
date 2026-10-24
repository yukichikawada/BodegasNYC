//
//  WalkedBlockStoreIncrementalTests.swift
//  BodegasNYCTests
//
//  The incremental match pass reads only the masks it touches (#113 item 4)
//  and still saves exactly what a full rebuild would, through Clears, a
//  failed save, a stamp change and relaunches.
//

import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

@MainActor
struct WalkedBlockStoreIncrementalTests {
    private typealias F = StreetFixtures

    /// A 7 x 7 lattice of 100 m blocks in two boroughs: 84 blocks, ids from 1.
    private static let lattice: [StreetGrid.Segment] = {
        var segments: [StreetGrid.Segment] = []
        var id: UInt32 = 1
        for row in 0 ... 6 {
            for column in 0 ..< 6 {
                let y = Double(row) * 100, x = Double(column) * 100
                segments.append(F.segment(id, [(x, y), (x + 100, y)], borough: row < 3 ? .manhattan : .brooklyn))
                id += 1
                segments.append(F.segment(id, [(y, x), (y, x + 100)], borough: row < 3 ? .manhattan : .brooklyn))
                id += 1
            }
        }
        return segments
    }()

    private static func latticeGrid(stamp: UInt32) -> StreetGrid {
        StreetGrid(datasetStamp: stamp, segments: lattice)
    }

    private func savedMasks(_ container: ModelContainer) throws -> [UInt32: UInt16] {
        Dictionary(uniqueKeysWithValues: try ModelContext(container).fetch(FetchDescriptor<WalkedBlock>()).map { ($0.physicalID, $0.mask) })
    }

    /// Every fix on disk, in history order: what a full rebuild matches.
    private func history(_ container: ModelContainer) throws -> [WalkedPointSnapshot] {
        try ModelContext(container).fetch(FetchDescriptor<WalkedPoint>())
            .map(WalkedBlockStore.snapshot)
            .sorted(by: WalkedPointSnapshot.sortsBefore)
    }

    private func expectSameSummary(_ summary: WalkedSummary, _ expected: WalkedSummary, _ note: String) {
        #expect(summary.walkedIDs == expected.walkedIDs, "\(note): walked IDs")
        #expect(summary.progress == expected.progress, "\(note): borough progress")
        #expect(summary.runs == expected.runs, "\(note): runs")
    }

    /// protects: after every pass of a randomized sequence (incremental
    /// batches, late fixes, Clear History at a mid-history tap, a save that
    /// throws and rolls back, a cancelled pass, a dataset stamp change, a
    /// dropped stamp and a relaunch with nothing cached), the saved masks,
    /// the walked IDs, the runs and the borough progress equal a full rebuild
    /// over the history on disk; a failed or cancelled pass leaves both the
    /// masks and the summary as they were (#113 item 4: the store reads only
    /// touched masks and keeps an in-memory copy).
    /// fails_when: an incremental pass merges into stale or missing masks,
    /// the in-memory masks or cached summary survive a Clear, a rebuild or a
    /// rolled-back save, or a fresh store's first pass loses saved bits.
    /// no_claim: ride filtering (activity is unavailable throughout); a
    /// crash mid-save (SwiftData's transaction).
    @Test(arguments: [1, 2, 3, 4, 5, 6] as [UInt64])
    func incrementalPassesEqualAFullRebuildAfterEveryPass(seed: UInt64) throws {
        var random = SplitMix64(seed: seed)
        let container = try makeInMemoryModelContainer()
        var stamp: UInt32 = 1
        var store = WalkedBlockStore(container: container, grid: Self.latticeGrid(stamp: stamp))
        var position = (x: 0.0, y: 0.0)
        var time = 0.0
        var pending: [WalkedPointSnapshot] = []
        var mostWalked = 0
        var counts = (passes: 0, incremental: 0, rebuilds: 0, clears: 0, failed: 0, cancelled: 0, stamps: 0, relaunches: 0)

        /// Walks one 100 m lattice block from `position` in 10 m steps.
        func walkOneBlock() {
            let horizontal = random.next() % 2 == 0
            var dx = 0.0, dy = 0.0
            if horizontal { dx = position.x >= 600 || (position.x > 0 && random.next() % 2 == 0) ? -100 : 100 } else {
                dy = position.y >= 600 || (position.y > 0 && random.next() % 2 == 0) ? -100 : 100
            }
            // Now and then a long pause, so a leg is too long to credit.
            time += random.next() % 5 == 0 ? 600 : 7
            for step in 1 ... 10 {
                let fraction = Double(step) / 10
                pending.append(WalkedPointSnapshot(
                    coordinate: F.coordinate(x: position.x + dx * fraction, y: position.y + dy * fraction),
                    recordedAt: F.baseDate.addingTimeInterval(time)
                ))
                time += 7
            }
            position = (position.x + dx, position.y + dy)
        }

        func record(_ count: Int) throws {
            while pending.count < count { walkOneBlock() }
            try F.seed(Array(pending.prefix(count)), in: container.mainContext)
            pending.removeFirst(count)
        }

        func pass(seam: (BlockMatchingActor.CommitPoint) throws -> Void = { _ in }, commit: Bool = true) throws -> Bool {
            guard let plan = try store.plan() else { return true }
            counts.passes += 1
            if plan.kind == .incremental { counts.incremental += 1 } else { counts.rebuilds += 1 }
            return try store.apply(plan, activity: .unavailable, seam: seam, shouldCommit: { commit })
        }

        func expectMatchesRebuild(_ note: String) throws {
            let expected = BlockMatcher.match(try history(container), grid: store.grid)
            #expect(try savedMasks(container) == expected, "\(note): saved masks")
            let summary = try store.summary()
            mostWalked = max(mostWalked, summary.walkedIDs.count)
            expectSameSummary(summary, WalkedSummary(masks: expected, grid: store.grid), note)
            let unmatched = try ModelContext(container).fetchCount(FetchDescriptor<WalkedPoint>(predicate: #Predicate { !$0.isMatched }))
            #expect(unmatched == 0, "\(note): unmatched fixes")
        }

        for step in 0 ..< 60 {
            let note = "seed \(seed) step \(step)"
            // Mostly new fixes; every tenth step forces one of the other
            // paths in turn, so each seed covers all of them.
            let action = step % 10 == 9 ? UInt64(step / 10) : random.next() % 20
            switch action {
            case 0: // Clear History at a tap mid-history, as clearHistory + runClear do.
                let fixes = try history(container)
                guard let tap = fixes.dropFirst(fixes.count / 2).first?.recordedAt else { continue }
                try container.mainContext.delete(model: WalkedPoint.self, where: #Predicate { $0.recordedAt <= tap })
                try container.mainContext.save()
                try store.clear()
                counts.clears += 1
                #expect(try savedMasks(container).isEmpty, "\(note): masks after Clear")
                expectSameSummary(try store.summary(), WalkedSummary(masks: [:], grid: store.grid), "\(note) after Clear")
            case 1: // A save that throws, then a cancelled pass: nothing changes.
                try record(Int(random.next() % 12) + 2)
                let masks = try savedMasks(container)
                let summary = try store.summary()
                #expect(throws: SimulatedSaveFailure.self) {
                    _ = try pass(seam: { if $0 == .beforeSave { throw SimulatedSaveFailure() } })
                }
                #expect(try !pass(commit: false), "\(note): the stale pass reports no save")
                counts.failed += 1
                counts.cancelled += 1
                #expect(try savedMasks(container) == masks, "\(note): masks after rollback")
                expectSameSummary(try store.summary(), summary, "\(note) after rollback")
            case 2: // A data refresh: a new bundle stamp, a new store.
                stamp += 1
                store = WalkedBlockStore(container: container, grid: Self.latticeGrid(stamp: stamp))
                counts.stamps += 1
            case 3: // The saved stamp disappears under a warm store.
                let context = ModelContext(container)
                for state in try context.fetch(FetchDescriptor<WalkedMatchState>()) { context.delete(state) }
                try context.save()
                counts.stamps += 1
            case 4: // A relaunch: same stamp, nothing cached.
                store = WalkedBlockStore(container: container, grid: Self.latticeGrid(stamp: stamp))
                counts.relaunches += 1
            case 5: // A late delivery, older than the newest matched fix.
                if let oldest = try history(container).first {
                    try F.seed([WalkedPointSnapshot(coordinate: oldest.coordinate, recordedAt: oldest.recordedAt.addingTimeInterval(1))], in: container.mainContext)
                }
            default:
                try record(Int(random.next() % 15) + 1)
            }
            #expect(try pass(), "\(note): pass saves")
            try expectMatchesRebuild(note)
        }
        // The sequence exercised every path it claims to.
        #expect(counts.incremental > 20 && counts.rebuilds > 2, "\(counts)")
        #expect(counts.clears > 0 && counts.failed > 0 && counts.stamps > 0 && counts.relaunches > 0, "\(counts)")
        #expect(mostWalked > 5, "the sequence walked enough blocks to compare")
    }

    /// protects: an incremental pass reads only the `WalkedBlock` rows of
    /// the blocks its fixes touch, on a warm store and on a fresh one (the
    /// first pass after launch), so its cost does not grow with walked
    /// history (#113 item 4: the device pass spent 29 ms of 36 ms loading
    /// all 5,006 masks).
    /// fails_when: an incremental pass fetches every mask (the full load
    /// that used to back `writeIncrement`), or any more rows than the blocks
    /// it touches.
    /// no_claim: SQLite's own cost per fetch; `summary()`, which reads every
    /// mask once per store because it counts them all.
    @Test(arguments: [false, true])
    func anIncrementalPassReadsOnlyTheMasksItTouches(freshStore: Bool) throws {
        let container = try makeInMemoryModelContainer()
        let grid = Self.latticeGrid(stamp: 1)
        // Walk every block once: 84 saved masks.
        var walk: [WalkedPointSnapshot] = []
        var time = 0.0
        for segment in Self.lattice {
            time += 600
            let (start, end) = (segment.coordinates[0], segment.coordinates[1])
            for step in 0 ... 10 {
                let fraction = Double(step) / 10
                walk.append(WalkedPointSnapshot(
                    coordinate: Coordinate(
                        latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                        longitude: start.longitude + (end.longitude - start.longitude) * fraction
                    ),
                    recordedAt: F.baseDate.addingTimeInterval(time + Double(step) * 7)
                ))
            }
        }
        try F.seed(walk, in: container.mainContext)
        var store = WalkedBlockStore(container: container, grid: grid)
        let backfill = try #require(try store.plan())
        try store.apply(backfill, activity: .unavailable) { true }
        #expect(try savedMasks(container).count == Self.lattice.count)
        _ = try store.summary()
        if freshStore { store = WalkedBlockStore(container: container, grid: grid) }

        // Three fixes back along the last block: one or two blocks touched.
        let last = try #require(walk.last)
        let back = (1 ... 3).map { step in
            WalkedPointSnapshot(
                coordinate: Coordinate(latitude: last.coordinate.latitude - Double(step) * 0.00009, longitude: last.coordinate.longitude),
                recordedAt: last.recordedAt.addingTimeInterval(Double(step) * 7)
            )
        }
        try F.seed(back, in: container.mainContext)
        let before = store.blockRowsFetched
        let plan = try #require(try store.plan())
        #expect(plan.kind == .incremental)
        let touched = BlockMatcher.match(plan.snapshots, grid: grid)
        #expect(!touched.isEmpty && touched.count < Self.lattice.count / 10)
        #expect(try store.apply(plan, activity: .unavailable) { true })
        #expect(store.blockRowsFetched - before == touched.count)

        // The summary is still the full one: one full read on a fresh store,
        // none on a warm one.
        let reads = store.blockRowsFetched
        #expect(try store.summary().walkedIDs.count == Self.lattice.count)
        #expect(store.blockRowsFetched - reads == (freshStore ? Self.lattice.count : 0))
    }
}

private struct SimulatedSaveFailure: Error {}

/// A small seeded generator, so a failing sequence replays exactly.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
