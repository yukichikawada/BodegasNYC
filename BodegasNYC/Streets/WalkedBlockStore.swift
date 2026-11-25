import Foundation
import SwiftData

/// The three kinds of match pass.
nonisolated enum WalkedPassKind: Equatable {
    /// Unmatched fixes after the newest matched one, ORed into the masks.
    case incremental
    /// Every mask recomputed from all history.
    case rebuild
    /// The per-day rows built once from matched history, each day mask
    /// clamped to its block's saved mask; the masks are not touched (#170
    /// eng A1).
    case backfill
}

/// The synchronous core of a match pass (#108 spec Implementation 4, eng
/// R4/R8): reads history from the store, decides incremental or rebuild,
/// writes masks, `isMatched` flips and the dataset stamp in one `save()`.
///
/// Not thread-safe; `BlockMatchingActor` owns the one instance and runs
/// every pass on itself. Each pass uses a fresh `ModelContext`, so a
/// 100,000-fix rebuild does not stay registered after it saves.
nonisolated final class WalkedBlockStore {
    /// History is read oldest first in pages of this many fixes (eng R4).
    static let pageSize = 5_000
    /// The per-day rows' version (#170): a store whose state is behind it
    /// backfills them once. A fix that changes how day rows are derived
    /// bumps it to rebuild them from `WalkedPoint`. 2: street meters and
    /// standing still (#192).
    static let dayIndexVersion = 2

    let container: ModelContainer
    let grid: StreetGrid
    /// The clock `WalkedEstimate` reads (tests pin it).
    let now: @Sendable () -> Date
    /// The saved day rows, loaded once for the first `history()` and kept
    /// current from each saved pass's day delta from then on (eng A3);
    /// `nil` until then.
    var days: WalkedDayRows?
    /// Whether the saved day rows are at `dayIndexVersion`; `nil` until read.
    var isDayIndexCurrent: Bool?
    /// The history of `days`, until they change.
    var cachedHistory: WalkedHistory?
    /// Advanced whenever the day rows held in memory change.
    var historyVersion = 0
    /// Backfill passes saved so far (tests: a 1.0.0 store backfills once).
    private(set) var backfillCount = 0
    /// The saved masks, read in full once for the first `summary()` and
    /// mirrored after every successful save from then on; `nil` until then.
    /// A pass never reads it: an incremental pass merges into the rows it
    /// fetches, so its cost follows its fixes, not the walked history
    /// (#113 item 4).
    private var masks: [UInt32: UInt16]?
    /// The summary of `masks`, until they change.
    private var cachedSummary: WalkedSummary?
    /// The last summary handed out, which the next one reconciles with.
    private var lastSummary = WalkedSummary.empty
    /// Full rebuilds saved so far (for tests: a stamp change rebuilds once).
    private(set) var rebuildCount = 0
    /// `WalkedBlock` rows fetched so far (for tests: an incremental pass
    /// fetches only the rows of the blocks it touches).
    private(set) var blockRowsFetched = 0

    init(container: ModelContainer, grid: StreetGrid, now: @escaping @Sendable () -> Date = { Date() }) {
        self.container = container
        self.grid = grid
        self.now = now
    }

    /// One pass's input, gathered before the activity query.
    struct Plan {
        let kind: WalkedPassKind
        let context: ModelContext
        /// History order; for an incremental pass the matched context
        /// (#192 eng E3) first, its newest fix closing the first new leg.
        let snapshots: [WalkedPointSnapshot]
        /// The fixes this pass flips to matched.
        let unmatched: [WalkedPoint]
        /// The fixes this pass may save ride evidence on (#170): every fix it
        /// matches the leg into, never an incremental pass's predecessor.
        let evidenceRows: [WalkedPoint]
        /// The index of the first new fix in `snapshots` (#192): legs end
        /// from here on, and the fixes before it are only read. 1 for a
        /// rebuild, a backfill, or an incremental pass with no matched fix.
        var firstNewIndex = 1
        /// A backfill of day rows that already existed (saved version 1 or
        /// more) keeps the saved estimate as it is (#192 eng E4).
        var keepsSavedEstimate = false
        var savedEstimate: WalkedDayKey?
    }

    /// What the next pass must do, or `nil` when the cache is current.
    /// A stamp that differs from the bundle's (or none) rebuilds; so does an
    /// unmatched fix that sorts before the newest matched one (a late or
    /// deferred delivery). A current stamp with day rows behind
    /// `dayIndexVersion` backfills them first, unless `allowsBackfill` is
    /// false (a backfill just failed, eng A6); the unmatched fixes then take
    /// the next, incremental, pass.
    func plan(allowsBackfill: Bool = true) throws -> Plan? {
        let context = Self.makeContext(container)
        let state = try context.fetch(FetchDescriptor<WalkedMatchState>()).first
        guard let state, state.datasetStamp == Int(grid.datasetStamp) else {
            return try rebuildPlan(context)
        }
        if allowsBackfill, state.dayIndexVersion != Self.dayIndexVersion {
            return try backfillPlan(context, state: state)
        }
        let unmatched = try fetchPaged(context, predicate: #Predicate { $0.isMatched == false })
        let new = Self.ordered(unmatched)
        guard let oldestNew = new.first else { return nil }
        var lastMatched = FetchDescriptor<WalkedPoint>(
            predicate: #Predicate { $0.isMatched == true },
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse), SortDescriptor(\.id, order: .reverse)]
        )
        lastMatched.fetchLimit = 1
        let predecessor = try context.fetch(lastMatched).first.map(Self.snapshot)
        if let predecessor, WalkedPointSnapshot.sortsBefore(oldestNew, predecessor) {
            return try rebuildPlan(context)
        }
        let lookBack = try predecessor.map { try matchedContext(context, before: oldestNew, newest: $0) } ?? []
        return Plan(
            kind: .incremental,
            context: context,
            snapshots: lookBack + new,
            unmatched: unmatched,
            evidenceRows: unmatched,
            firstNewIndex: max(1, lookBack.count)
        )
    }

    private func rebuildPlan(_ context: ModelContext) throws -> Plan {
        let all = try fetchPaged(context, predicate: nil)
        return Plan(
            kind: .rebuild,
            context: context,
            snapshots: Self.ordered(all),
            unmatched: all.filter { !$0.isMatched },
            evidenceRows: all
        )
    }

    /// Matches the plan, stages masks, flips, ride evidence and stamp, then asks
    /// `shouldCommit` immediately before the one `save()`, so the check is as
    /// late as it can be. If the work is stale (Clear History), or anything
    /// throws, the staged changes are rolled back. Returns whether it saved.
    /// `seam` is for tests (`.beforeCheck`, `.beforeSave`).
    @discardableResult
    func apply(
        _ plan: Plan,
        activity: VehicleActivity,
        seam: (BlockMatchingActor.CommitPoint) throws -> Void = { _ in },
        shouldCommit: () -> Bool
    ) throws -> Bool {
        let result = BlockMatcher.matchByDay(
            plan.snapshots, grid: grid, activity: activity, firstLegEnd: plan.firstNewIndex
        )
        // Only the predecessor and the new fixes (#192 eng E5).
        let evidence = BlockMatcher.evidence(plan.legSnapshots, activity: activity)
        // Rebuilds and backfills re-derive old days (eng E2); an
        // incremental pass leaves the saved value alone.
        let estimated = estimatedThroughDay(plan, found: evidence)
        let context = plan.context
        let written: MaskWrite
        let dayWrite: DayWrite
        do {
            written = switch plan.kind {
            case .rebuild: try writeRebuild(result.masks, in: context)
            case .incremental: try writeIncrement(result.masks, in: context)
            case .backfill: .merged([:]) // The totals stay as saved (eng A1).
            }
            dayWrite = try stageDays(plan.kind, result.days, in: context)
            try stageState(plan.kind, estimatedThroughDay: estimated, in: context)
            for point in plan.unmatched {
                point.isMatched = true
            }
            Self.saveEvidence(evidence, on: plan.evidenceRows)
            try seam(.beforeCheck)
            guard shouldCommit() else {
                context.rollback()
                return false
            }
            try seam(.beforeSave)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        didSave(written)
        if plan.kind == .backfill { backfillCount += 1 }
        didSave(dayWrite, estimatedThroughDay: estimated)
        return true
    }

    /// Mirrors a saved pass's masks in memory.
    private func didSave(_ written: MaskWrite) {
        switch written {
        case .replaced(let all):
            if all != masks { cachedSummary = nil }
            masks = all
            rebuildCount += 1
        case .merged(let changed):
            guard !changed.isEmpty else { break }
            cachedSummary = nil
            masks?.merge(changed) { $1 }
        }
    }

    /// What a pass staged, applied to `masks` only once it saves.
    private enum MaskWrite {
        /// Every mask (a rebuild).
        case replaced([UInt32: UInt16])
        /// The masks whose value changed, merged values (an incremental pass).
        case merged([UInt32: UInt16])
    }

    /// Replaces every mask with `delta`. Rows are updated in place or
    /// deleted, never deleted and re-inserted under the same unique id in
    /// one save.
    private func writeRebuild(_ delta: [UInt32: UInt16], in context: ModelContext) throws -> MaskWrite {
        var remaining = delta
        let rows = try context.fetch(FetchDescriptor<WalkedBlock>())
        blockRowsFetched += rows.count
        for block in rows {
            if let mask = remaining.removeValue(forKey: block.physicalID) {
                if block.mask != mask { block.mask = mask }
            } else {
                context.delete(block)
            }
        }
        for (physicalID, mask) in remaining {
            context.insert(WalkedBlock(physicalID: physicalID, mask: mask))
        }
        return .replaced(delta)
    }

    /// ORs `delta` into the saved masks. Fetches only the rows of the
    /// blocks `delta` touches (the merge base is what is on disk, never a
    /// copy that might be stale), writes only rows that change, and returns
    /// those.
    private func writeIncrement(_ delta: [UInt32: UInt16], in context: ModelContext) throws -> MaskWrite {
        guard !delta.isEmpty else { return .merged([:]) }
        var remaining = delta
        let keys = delta.keys.map(Int.init)
        let rows = try context.fetch(
            FetchDescriptor<WalkedBlock>(predicate: #Predicate { keys.contains($0.storedPhysicalID) })
        )
        blockRowsFetched += rows.count
        var changed: [UInt32: UInt16] = [:]
        for block in rows {
            guard let bits = remaining.removeValue(forKey: block.physicalID) else { continue }
            let merged = block.mask | bits
            if merged != block.mask {
                block.mask = merged
                changed[block.physicalID] = merged
            }
        }
        for (physicalID, mask) in remaining {
            context.insert(WalkedBlock(physicalID: physicalID, mask: mask))
            changed[physicalID] = mask
        }
        return .merged(changed)
    }

    /// The saved masks as walked blocks, counts and runs. Built once per
    /// mask change and reconciled with the last one here, off the main
    /// actor: unchanged runs keep their `MKPolyline` objects and the same
    /// `runsVersion`, so a catch-up that found nothing new costs the view
    /// model an integer compare and the map nothing.
    func summary() throws -> WalkedSummary {
        if let cachedSummary { return cachedSummary }
        let fresh = WalkedSummary(masks: try loadMasks(), grid: grid).reconciled(with: lastSummary)
        cachedSummary = fresh
        lastSummary = fresh
        return fresh
    }

    /// Deletes every mask and the stamp (Clear History). Raw history is the
    /// caller's: it deletes `WalkedPoint`s up to the tap itself (eng R9).
    func clear() throws {
        try Self.clearCache(in: container)
        masks = [:]
        cachedSummary = nil
        clearDays()
    }

    /// Deletes the masks, the day rows (#170) and the stamp in one save.
    static func clearCache(in container: ModelContainer) throws {
        let context = makeContext(container)
        for block in try context.fetch(FetchDescriptor<WalkedBlock>()) {
            context.delete(block)
        }
        for row in try context.fetch(FetchDescriptor<WalkedDayBlock>()) {
            context.delete(row)
        }
        for day in try context.fetch(FetchDescriptor<WalkedDay>()) {
            context.delete(day)
        }
        for state in try context.fetch(FetchDescriptor<WalkedMatchState>()) {
            context.delete(state)
        }
        try context.save()
    }

    // MARK: Helpers

    /// Stages `evidence` on the rows it names. Evidence already known is
    /// never overwritten: it was read while CoreMotion still remembered the
    /// leg, and a late fix that splits the leg leaves it true (#170).
    private static func saveEvidence(_ evidence: [UUID: RideEvidence], on rows: [WalkedPoint]) {
        guard !evidence.isEmpty else { return }
        for point in rows where point.ride == .unknown {
            if let known = evidence[point.id] { point.ride = known }
        }
    }

    private func loadMasks() throws -> [UInt32: UInt16] {
        if let masks { return masks }
        let context = Self.makeContext(container)
        var loaded: [UInt32: UInt16] = [:]
        let rows = try context.fetch(FetchDescriptor<WalkedBlock>())
        blockRowsFetched += rows.count
        for block in rows {
            loaded[block.physicalID] = block.mask
        }
        masks = loaded
        return loaded
    }

    func fetchPaged(_ context: ModelContext, predicate: Predicate<WalkedPoint>?) throws -> [WalkedPoint] {
        var result: [WalkedPoint] = []
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<WalkedPoint>(predicate: predicate, sortBy: Self.oldestFirst)
            descriptor.fetchLimit = Self.pageSize
            descriptor.fetchOffset = offset
            let page = try context.fetch(descriptor)
            result.append(contentsOf: page)
            guard page.count == Self.pageSize else { return result }
            offset += page.count
        }
    }

    private static let oldestFirst = [SortDescriptor(\WalkedPoint.recordedAt), SortDescriptor(\WalkedPoint.id)]

    static func makeContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    static func snapshot(_ point: WalkedPoint) -> WalkedPointSnapshot {
        WalkedPointSnapshot(
            coordinate: Coordinate(latitude: point.latitude, longitude: point.longitude),
            recordedAt: point.recordedAt,
            id: point.id,
            ride: point.ride
        )
    }

    /// Snapshots in history order. The store sorts pages the same way; this
    /// settles timestamp ties by id exactly as `sortsBefore` defines them.
    static func ordered(_ points: [WalkedPoint]) -> [WalkedPointSnapshot] {
        points.map(snapshot).sorted(by: WalkedPointSnapshot.sortsBefore)
    }
}
