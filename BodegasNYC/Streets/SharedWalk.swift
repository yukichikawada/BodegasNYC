import Foundation

/// What one share sends (#177 eng PR 1, E6, E7): a range of walk days and
/// what was walked in it. The form's preview, the picture and the share
/// text are all made from one of these, frozen when the picture is made
/// (design review, "History changes while open"), so what is approved is
/// what is sent. PR 2's link is made from the same value.
nonisolated struct SharedWalk: Sendable, Equatable {
    let firstDay: WalkedDayKey
    let lastDay: WalkedDayKey
    /// The union of the days' walked blocks (`physicalid`s).
    let blockIDs: Set<UInt32>
    /// The distance of the days in range that have a walked block (E6),
    /// rounded once to the nearest whole metre.
    let meters: Int
    /// The sum of the days' new blocks.
    let newCount: Int
    /// Some day in range is an estimate (`WalkedHistory.isEstimate`, E7).
    let isEstimate: Bool

    var blockCount: Int { blockIDs.count }
}

nonisolated extension WalkedHistory {
    /// The walk between `first` and `last`, both included, from the history
    /// already in memory (no SwiftData read). Days with no row add nothing;
    /// a day with no walked block adds no metres (E6: a day's distance
    /// includes walking that matched no block). `first` after `last` is the
    /// empty range.
    func shareSummary(from first: WalkedDayKey, to last: WalkedDayKey) -> SharedWalk {
        var ids: Set<UInt32> = []
        var meters = 0.0
        var newCount = 0
        if first <= last {
            for summary in days where summary.day >= first && summary.day <= last {
                ids.formUnion(summary.walkedIDs)
                newCount += summary.newCount
                if summary.isWalked { meters += summary.meters }
            }
        }
        return SharedWalk(
            firstDay: first,
            lastDay: last,
            blockIDs: ids,
            meters: Int(meters.rounded()),
            newCount: newCount,
            // Days up to `estimatedThroughDay` are estimates, so the range
            // holds one exactly when its first day is one.
            isEstimate: first <= last && isEstimate(first)
        )
    }
}

nonisolated extension WalkedDayKey {
    /// The key for the calendar date `date` shows in New York, whatever its
    /// hour: a date picker's value, which carries the time of day it was
    /// seeded with, not a walk's 4 a.m. boundary.
    init(calendarDate date: Date) {
        let parts = Self.calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }
}
