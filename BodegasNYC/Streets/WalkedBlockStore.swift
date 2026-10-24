import Foundation
import SwiftData

/// The two kinds of match pass.
nonisolated enum WalkedPassKind: Equatable {
    /// Unmatched fixes after the newest matched one, ORed into the masks.
    case incremental
    /// Every mask recomputed from all history.
    case rebuild
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

    let container: ModelContainer
    let grid: StreetGrid
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

    init(container: ModelContainer, grid: StreetGrid) {
        self.container = container
        self.grid = grid
    }

    /// One pass's input, gathered before the activity query.
    struct Plan {
        let kind: WalkedPassKind
        let context: ModelContext
        /// History order; for an incremental pass the newest matched fix
        /// first, so it closes the first new leg.
        let snapshots: [WalkedPointSnapshot]
        /// The fixes this pass flips to matched.
        let unmatched: [WalkedPoint]

        var range: DateInterval? {
            guard let first = snapshots.first, let last = snapshots.last else { return nil }
            return DateInterval(start: first.recordedAt, end: last.recordedAt)
        }
    }

    /// What the next pass must do, or `nil` when the cache is current.
    /// A stamp that differs from the bundle's (or none) rebuilds; so does an
    /// unmatched fix that sorts before the newest matched one (a late or
    /// deferred delivery).
    func plan() throws -> Plan? {
        let context = Self.makeContext(container)
        let state = try context.fetch(FetchDescriptor<WalkedMatchState>()).first
        guard state?.datasetStamp == Int(grid.datasetStamp) else {
            return try rebuildPlan(context)
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
        let snapshots = (predecessor.map { [$0] } ?? []) + new
        return Plan(kind: .incremental, context: context, snapshots: snapshots, unmatched: unmatched)
    }

    private func rebuildPlan(_ context: ModelContext) throws -> Plan {
        let all = try fetchPaged(context, predicate: nil)
        return Plan(
            kind: .rebuild,
            context: context,
            snapshots: Self.ordered(all),
            unmatched: all.filter { !$0.isMatched }
        )
    }

    /// Matches the plan, stages masks, flips and stamp, then asks
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
        let delta = BlockMatcher.match(plan.snapshots, grid: grid, activity: activity)
        let context = plan.context
        let written: MaskWrite
        do {
            written = switch plan.kind {
            case .rebuild: try writeRebuild(delta, in: context)
            case .incremental: try writeIncrement(delta, in: context)
            }
            if let state = try context.fetch(FetchDescriptor<WalkedMatchState>()).first {
                state.datasetStamp = Int(grid.datasetStamp)
            } else {
                context.insert(WalkedMatchState(datasetStamp: grid.datasetStamp))
            }
            for point in plan.unmatched {
                point.isMatched = true
            }
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
        return true
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
    }

    static func clearCache(in container: ModelContainer) throws {
        let context = makeContext(container)
        for block in try context.fetch(FetchDescriptor<WalkedBlock>()) {
            context.delete(block)
        }
        for state in try context.fetch(FetchDescriptor<WalkedMatchState>()) {
            context.delete(state)
        }
        try context.save()
    }

    // MARK: Helpers

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

    private func fetchPaged(_ context: ModelContext, predicate: Predicate<WalkedPoint>?) throws -> [WalkedPoint] {
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

    private static func makeContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    static func snapshot(_ point: WalkedPoint) -> WalkedPointSnapshot {
        WalkedPointSnapshot(
            coordinate: Coordinate(latitude: point.latitude, longitude: point.longitude),
            recordedAt: point.recordedAt,
            id: point.id
        )
    }

    /// Snapshots in history order. The store sorts pages the same way; this
    /// settles timestamp ties by id exactly as `sortsBefore` defines them.
    private static func ordered(_ points: [WalkedPoint]) -> [WalkedPointSnapshot] {
        points.map(snapshot).sorted(by: WalkedPointSnapshot.sortsBefore)
    }
}
