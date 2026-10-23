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
    /// The saved masks, mirrored after every successful save.
    private var masks: [UInt32: UInt16]?
    /// Full rebuilds saved so far (for tests: a stamp change rebuilds once).
    private(set) var rebuildCount = 0

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
        var firstUnmatched = FetchDescriptor<WalkedPoint>(
            predicate: #Predicate { $0.isMatched == false },
            sortBy: Self.oldestFirst
        )
        firstUnmatched.fetchLimit = 1
        guard let oldestNew = try context.fetch(firstUnmatched).first else { return nil }
        var lastMatched = FetchDescriptor<WalkedPoint>(
            predicate: #Predicate { $0.isMatched == true },
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse), SortDescriptor(\.id, order: .reverse)]
        )
        lastMatched.fetchLimit = 1
        let predecessor = try context.fetch(lastMatched).first.map(Self.snapshot)
        if let predecessor, WalkedPointSnapshot.sortsBefore(Self.snapshot(oldestNew), predecessor) {
            return try rebuildPlan(context)
        }
        let unmatched = try fetchPaged(context, predicate: #Predicate { $0.isMatched == false })
        let snapshots = (predecessor.map { [$0] } ?? []) + Self.ordered(unmatched)
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

    /// Matches the plan and saves masks, flips and stamp in one `save()`,
    /// unless `shouldCommit` says the work is stale (Clear History). Returns
    /// whether it saved.
    @discardableResult
    func apply(_ plan: Plan, activity: VehicleActivity, shouldCommit: () -> Bool) throws -> Bool {
        let delta = BlockMatcher.match(plan.snapshots, grid: grid, activity: activity)
        guard shouldCommit() else {
            plan.context.rollback()
            return false
        }
        let context = plan.context
        let updated = switch plan.kind {
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
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        masks = updated
        if plan.kind == .rebuild { rebuildCount += 1 }
        return true
    }

    /// Replaces every mask with `delta`. Rows are updated in place or
    /// deleted, never deleted and re-inserted under the same unique id in
    /// one save.
    private func writeRebuild(_ delta: [UInt32: UInt16], in context: ModelContext) throws -> [UInt32: UInt16] {
        var remaining = delta
        for block in try context.fetch(FetchDescriptor<WalkedBlock>()) {
            if let mask = remaining.removeValue(forKey: block.physicalID) {
                if block.mask != mask { block.mask = mask }
            } else {
                context.delete(block)
            }
        }
        for (physicalID, mask) in remaining {
            context.insert(WalkedBlock(physicalID: physicalID, mask: mask))
        }
        return delta
    }

    /// ORs `delta` into the saved masks, touching only rows that change.
    private func writeIncrement(_ delta: [UInt32: UInt16], in context: ModelContext) throws -> [UInt32: UInt16] {
        var updated = try loadMasks()
        var changed: [UInt32: UInt16] = [:]
        for (physicalID, bits) in delta {
            let merged = (updated[physicalID] ?? 0) | bits
            if merged != updated[physicalID] {
                changed[physicalID] = merged
                updated[physicalID] = merged
            }
        }
        let keys = changed.keys.map(Int.init)
        let existing = try context.fetch(
            FetchDescriptor<WalkedBlock>(predicate: #Predicate { keys.contains($0.storedPhysicalID) })
        )
        for block in existing {
            if let mask = changed.removeValue(forKey: block.physicalID) { block.mask = mask }
        }
        for (physicalID, mask) in changed {
            context.insert(WalkedBlock(physicalID: physicalID, mask: mask))
        }
        return updated
    }

    /// The saved masks as walked blocks, counts and runs.
    func summary() throws -> WalkedSummary {
        WalkedSummary(masks: try loadMasks(), grid: grid)
    }

    /// Deletes every mask and the stamp (Clear History). Raw history is the
    /// caller's: it deletes `WalkedPoint`s up to the tap itself (eng R9).
    func clear() throws {
        try Self.clearCache(in: container)
        masks = [:]
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
        for block in try context.fetch(FetchDescriptor<WalkedBlock>()) {
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
