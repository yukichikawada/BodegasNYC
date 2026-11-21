import Foundation

/// The Progress tab's second chart as data (#188): blocks walked per day,
/// or per week, month or year over long ranges, each bar split into the
/// day's new blocks and the blocks walked before. Pure and built once per
/// slice (eng E4) from the slice's per-day arrays, with day arithmetic only
/// (`WalkedDayKey.dayNumber`), never a `Calendar` call per day (eng E9).
///
/// Every bucket of the range is kept, zeros included, for VoiceOver and the
/// Audio Graph (design DS17); only buckets with a block are drawn (`bars`).
/// The first and last buckets are clipped to the range, never padded.
nonisolated struct WalkDailyBars: Equatable, Sendable {
    nonisolated enum Unit: Equatable, Sendable {
        case day, week, month, year

        /// The unit for a slice of `dayCount` days (spec item 3, design
        /// DS3): up to 31 days daily, up to 124 weekly, up to 1,095 monthly
        /// (36 bars at most), beyond that yearly.
        static func forDayCount(_ dayCount: Int) -> Unit {
            switch dayCount {
            case ...31: .day
            case ...124: .week
            case ...1_095: .month
            default: .year
            }
        }

        /// A full bucket's nominal length in days, for the inset rule.
        var nominalDays: Double {
            switch self {
            case .day: 1
            case .week: 7
            case .month: 30
            case .year: 365
            }
        }
    }

    nonisolated struct Bar: Equatable, Sendable, Identifiable {
        /// The bucket's first day, as a slice day index.
        let startIndex: Int
        /// The bucket's last day inside the range, inclusive.
        let endIndex: Int
        /// The sum of the days' walked blocks (a block counts once a day).
        let total: Int
        /// The sum of the days' new blocks.
        let new: Int

        var repeated: Int { total - new }
        var spanDays: Int { endIndex - startIndex + 1 }
        var id: Int { startIndex }
    }

    let unit: Unit
    /// The slice's first day (index 0).
    let start: WalkedDayKey
    let dayCount: Int
    /// Every bucket of the range, ascending, zeros included (DS17).
    let buckets: [Bar]
    /// The drawn bars: buckets with at least one block, ascending.
    let bars: [Bar]
    /// Days with at least one block (DS7's rest value).
    let walkedDayCount: Int

    /// - Parameters:
    ///   - walked: each day's walked block count, index 0 at `start`.
    ///   - new: each day's new block count, parallel to `walked`.
    ///   - firstWeekday: the Calendar tab's first weekday, 1 = Sunday as
    ///     `Calendar.firstWeekday` (eng E5).
    init(start: WalkedDayKey, walked: [Int], new: [Int], firstWeekday: Int) {
        let count = walked.count
        let unit = Unit.forDayCount(count)
        self.unit = unit
        self.start = start
        dayCount = count
        var buckets: [Bar] = []
        var bucketStart = 0
        var total = 0
        var newSum = 0
        var walkedDays = 0
        let startNumber = start.dayNumber
        for index in 0 ..< count {
            if index > 0, Self.startsBucket(dayNumber: startNumber + index, unit: unit, firstWeekday: firstWeekday) {
                buckets.append(Bar(startIndex: bucketStart, endIndex: index - 1, total: total, new: newSum))
                bucketStart = index
                total = 0
                newSum = 0
            }
            let blocks = walked[index]
            total += blocks
            newSum += index < new.count ? new[index] : 0
            if blocks > 0 { walkedDays += 1 }
        }
        if count > 0 { buckets.append(Bar(startIndex: bucketStart, endIndex: count - 1, total: total, new: newSum)) }
        self.buckets = buckets
        bars = buckets.filter { $0.total > 0 }
        walkedDayCount = walkedDays
    }

    /// Whether a new bucket begins on this day: every day; the first
    /// weekday; the first of a month; January 1.
    static func startsBucket(dayNumber: Int, unit: Unit, firstWeekday: Int) -> Bool {
        switch unit {
        case .day: return true
        case .week: return weekday(dayNumber: dayNumber) == firstWeekday
        case .month: return WalkedDayKey(dayNumber: dayNumber).day == 1
        case .year:
            let key = WalkedDayKey(dayNumber: dayNumber)
            return key.month == 1 && key.day == 1
        }
    }

    /// 1 = Sunday through 7 = Saturday, as `Calendar`'s `.weekday`; day 0
    /// (1970-01-01) was a Thursday.
    static func weekday(dayNumber: Int) -> Int {
        ((dayNumber % 7 + 7 + 4) % 7) + 1
    }

    func day(at index: Int) -> WalkedDayKey { start.advancedNumerically(by: index) }

    /// Zero to the largest bar's total, never below 0 ... 1 (spec item 6).
    var yDomain: ClosedRange<Int> { 0 ... max(1, bars.map(\.total).max() ?? 0) }

    var yTicks: [Int] { WalkProgressSlice.yTicks(for: yDomain) }

    /// True when a month or year bucket covers its whole month or year; a
    /// bucket clipped by the range's start or by today reads its dates
    /// (eng E11). Days and weeks always read their dates.
    func isWholePeriod(_ bar: Bar) -> Bool {
        guard unit == .month || unit == .year else { return false }
        let first = day(at: bar.startIndex)
        let next = day(at: bar.endIndex + 1)
        return unit == .month
            ? first.day == 1 && next.day == 1
            : first.month == 1 && first.day == 1 && next.month == 1 && next.day == 1
    }

    // MARK: Scrub and VoiceOver

    /// The day under a continuous x (eng E2): the nearest whole day,
    /// clamped to the range; `nil` when nothing is selected.
    func dayIndex(forX value: Double?) -> Int? {
        guard let value, dayCount > 0, value.isFinite else { return nil }
        // Clamped as a Double first: `Int(_:)` traps on a huge finite value.
        return Int(min(max(value, 0), Double(dayCount - 1)).rounded())
    }

    /// The bucket holding `index`, clamped to the range (eng E3); a bucket
    /// with no walk is a zero bar with its clipped span. Total over every
    /// day of a non-empty slice.
    func bar(containing index: Int) -> Bar {
        guard !buckets.isEmpty else { return Bar(startIndex: 0, endIndex: 0, total: 0, new: 0) }
        return buckets[position(containing: index)]
    }

    /// The position in `buckets` of the bucket holding `index` (clamped).
    func position(containing index: Int) -> Int {
        let clamped = min(max(index, 0), max(0, dayCount - 1))
        var low = 0
        var high = buckets.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if buckets[middle].startIndex <= clamped { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// VoiceOver's adjustable step over every bucket, zeros included
    /// (DS17): starts at the latest, stops at both ends.
    func stepped(from position: Int?, by delta: Int) -> Int {
        let last = max(0, buckets.count - 1)
        guard let position else { return last }
        return min(max(position + delta, 0), last)
    }

    // MARK: Drawing

    /// A plot of the narrowest width the ticks are spaced for.
    private static let plotWidth = WalkProgressSlice.minimumPlotWidth
    /// No bar is wider than this on a `plotWidth` plot (DS10).
    static let maximumBarWidth: Double = 36

    /// Days in the shared x-domain (DS4): a single day spans -1 ... 1.
    var domainDays: Double { dayCount <= 1 ? 2 : Double(dayCount) }

    /// The inset on each side of a bar, in days (spec item 9, DS10): a
    /// tenth of the unit, or half a point on a 300 pt plot, whichever is
    /// more; never more than a quarter of the bar's own span; and always
    /// enough that the bar is no wider than 36 pt on that plot, which
    /// outranks the quarter-span cap.
    func inset(for bar: Bar) -> Double {
        let span = Double(bar.spanDays)
        let base = max(0.1 * unit.nominalDays, 0.5 * domainDays / Self.plotWidth)
        let capped = min(base, 0.25 * span)
        let widthCap = (span - Self.maximumBarWidth * domainDays / Self.plotWidth) / 2
        return max(capped, widthCap)
    }

    /// The bar's drawn x extent in day-index units, insets applied.
    func xExtent(of bar: Bar) -> ClosedRange<Double> {
        let inset = inset(for: bar)
        return (Double(bar.startIndex) - 0.5 + inset) ... (Double(bar.endIndex) + 0.5 - inset)
    }
}
