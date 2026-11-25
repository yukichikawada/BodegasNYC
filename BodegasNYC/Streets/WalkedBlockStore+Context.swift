import Foundation
import SwiftData

nonisolated extension WalkedBlockStore.Plan {
    /// The fixes the pass's legs touch: from the predecessor on (#192).
    var legSnapshots: [WalkedPointSnapshot] { Array(snapshots.dropFirst(firstNewIndex - 1)) }

    /// The span the pass's legs cover, which CoreMotion is asked about; the
    /// look-back fixes before the predecessor form no leg (#192).
    var range: DateInterval? {
        let legs = snapshots.dropFirst(firstNewIndex - 1)
        guard let first = legs.first, let last = legs.last else { return nil }
        return DateInterval(start: first.recordedAt, end: last.recordedAt)
    }
}

// The fixes a pass reads but does not match (#192): an incremental pass's
// standing-still look-back, and a backfill's saved estimate.
nonisolated extension WalkedBlockStore {
    /// An incremental pass's leading context (#192 eng E3), in history
    /// order: the matched fixes recorded within
    /// `BlockMatcher.dwellWindowSeconds` before `oldestNew`, the newest
    /// `BlockMatcher.dwellMaxFixes` at most, and always `newest` (the
    /// newest matched fix, which closes the first new leg) even when it is
    /// older than the window. That covers every fix the dwell look-back of
    /// any new end fix can read, so incremental passes give the same meters
    /// as one pass over all history.
    func matchedContext(
        _ context: ModelContext,
        before oldestNew: WalkedPointSnapshot,
        newest: WalkedPointSnapshot
    ) throws -> [WalkedPointSnapshot] {
        let cutoff = oldestNew.recordedAt.addingTimeInterval(-BlockMatcher.dwellWindowSeconds)
        var descriptor = FetchDescriptor<WalkedPoint>(
            predicate: #Predicate { $0.isMatched == true && $0.recordedAt >= cutoff },
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse), SortDescriptor(\.id, order: .reverse)]
        )
        descriptor.fetchLimit = BlockMatcher.dwellMaxFixes
        let window = Self.ordered(try context.fetch(descriptor))
        return window.isEmpty ? [newest] : window
    }

    /// Every matched fix, to re-derive the day rows from (#170 eng A1). A
    /// store that already had day rows (saved version 1 or more) keeps its
    /// saved estimate: a backfill asks no CoreMotion, so its own rule would
    /// mark every day up to the newest unknown fix an estimate, including
    /// recent days CoreMotion could still answer for (#192 eng E4). Only a
    /// store that never had day rows (version 0) uses that rule.
    func backfillPlan(_ context: ModelContext, state: WalkedMatchState) throws -> Plan {
        let matched = Self.ordered(try fetchPaged(context, predicate: #Predicate { $0.isMatched == true }))
        return Plan(
            kind: .backfill,
            context: context,
            snapshots: matched,
            unmatched: [],
            evidenceRows: [],
            keepsSavedEstimate: state.dayIndexVersion >= 1,
            savedEstimate: state.estimatedThroughDay.map(WalkedDayKey.init(value:))
        )
    }
}
