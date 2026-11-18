import Foundation

/// One walk day as Your Walks shows it (#170 spec rule 5, owner D1): every
/// block walked that day, repeats included, how many were new, and the
/// day's distance.
nonisolated struct WalkedDaySummary: Sendable, Equatable, Identifiable {
    let day: WalkedDayKey
    /// Blocks walked on the day: the day's own mask passes
    /// `BlockMatcher.isWalked`, or the block's running total first passes
    /// it on this day.
    let walkedIDs: Set<UInt32>
    /// Walked IDs whose running total first passed on this day.
    let newCount: Int
    let meters: Double

    var id: WalkedDayKey { day }

    /// A day earns a calendar dot only when a block was walked (eng E3):
    /// distance alone, or walking outside the five boroughs, is not enough.
    var isWalked: Bool { !walkedIDs.isEmpty }
}

/// Your Walks' data (#170 spec rule 5, eng A3, A4): every walk day with a
/// row, oldest first, and the cumulative walked-block count after each.
/// Built off the main actor by `WalkedBlockStore`; `version` advances only
/// when the history changes, so the view model compares an integer.
nonisolated struct WalkedHistory: Sendable, Equatable {
    nonisolated struct CumulativePoint: Sendable, Equatable {
        let day: WalkedDayKey
        let count: Int
    }

    /// Ascending by day; every day that has a block row or a distance.
    var days: [WalkedDaySummary]
    /// One point per entry of `days`: walked blocks citywide after the day.
    /// Its last value equals Your Blocks' citywide count only when every
    /// saved total is the OR of its days. A backfilled saved bit that no
    /// re-match of history produces stays in the totals with no day, so the
    /// last value can fall below the Your Blocks total; a headline count
    /// (PR 2) comes from the totals (`WalkedSummary`), not from here.
    var cumulative: [CumulativePoint]
    /// Days up to this one were rebuilt without saved ride evidence (E2).
    var estimatedThroughDay: WalkedDayKey?
    var version: Int

    static let empty = WalkedHistory(days: [], cumulative: [], estimatedThroughDay: nil, version: 0)

    var walkedDays: [WalkedDaySummary] { days.filter(\.isWalked) }

    func isEstimate(_ day: WalkedDayKey) -> Bool {
        estimatedThroughDay.map { day <= $0 } ?? false
    }

    /// The summary for `day`, or `nil` when it has no row.
    func summary(for day: WalkedDayKey) -> WalkedDaySummary? {
        var low = 0
        var high = days.count
        while low < high {
            let middle = (low + high) / 2
            if days[middle].day < day { low = middle + 1 } else { high = middle }
        }
        return low < days.count && days[low].day == day ? days[low] : nil
    }

    /// Builds the history from the day rows. Physical ids missing from
    /// `grid` are skipped exactly as `WalkedSummary.init(masks:grid:)` skips
    /// them (A4), so the last cumulative count equals Your Blocks' citywide
    /// count whenever the totals are the OR of the days (A2).
    static func build(
        dayMasks: [WalkedDayKey: [UInt32: UInt16]],
        dayMeters: [WalkedDayKey: Double],
        grid: StreetGrid,
        estimatedThroughDay: WalkedDayKey?,
        version: Int
    ) -> WalkedHistory {
        let keys = Set(dayMasks.keys).union(dayMeters.keys).sorted()
        var running: [UInt32: UInt16] = [:]
        var count = 0
        var days: [WalkedDaySummary] = []
        var cumulative: [CumulativePoint] = []
        days.reserveCapacity(keys.count)
        cumulative.reserveCapacity(keys.count)
        for day in keys {
            var walked: Set<UInt32> = []
            var new = 0
            for (physicalID, mask) in dayMasks[day] ?? [:] where grid.index(ofPhysicalID: physicalID) != nil {
                let before = running[physicalID] ?? 0
                let after = before | mask
                running[physicalID] = after
                let isNew = !BlockMatcher.isWalked(mask: before) && BlockMatcher.isWalked(mask: after)
                if isNew { new += 1 }
                if isNew || BlockMatcher.isWalked(mask: mask) { walked.insert(physicalID) }
            }
            count += new
            days.append(WalkedDaySummary(day: day, walkedIDs: walked, newCount: new, meters: dayMeters[day] ?? 0))
            cumulative.append(CumulativePoint(day: day, count: count))
        }
        return WalkedHistory(
            days: days,
            cumulative: cumulative,
            estimatedThroughDay: estimatedThroughDay,
            version: version
        )
    }
}
