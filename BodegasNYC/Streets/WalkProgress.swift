import Foundation

/// The Progress tab's ranges (#170 spec, design DS6, DS8.5): 1 week, 1
/// month, 3 months, 1 year and All, opening on 1 month.
nonisolated enum WalkProgressRange: Int, CaseIterable, Hashable, Sendable, Identifiable {
    case week, month, threeMonths, year, all

    static let initial = WalkProgressRange.month

    var id: Int { rawValue }

    /// Days in the domain, ending on today's walk day; `nil` for All, which
    /// starts on the first walked day.
    var dayCount: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .threeMonths: 90
        case .year: 365
        case .all: nil
        }
    }
}

/// Your Walks' Progress chart as data (#170 PR 2, design DS6): cumulative
/// walked blocks citywide, one value per walk day from the start of the
/// longest range through today, with the days that have no row filled flat
/// (`WalkedHistory.cumulative` has a point only per day with a row). Pure
/// and built from the history the view model already holds, so nothing
/// here touches SwiftData; the view slices it per range.
///
/// The headline and the line (eng A4, `WalkedHistory.cumulative`'s doc):
/// the line plots what the day rows know, so its last value can fall below
/// Your Blocks' citywide count when a saved block appears in no day (a
/// backfilled bit no re-match produced). The headline is Your Blocks'
/// number; the line is never shifted or topped up to meet it, because that
/// would date blocks to days they were not walked on. A gain is measured on
/// the line, so it counts only blocks whose day is known.
nonisolated struct WalkProgress: Equatable, Sendable {
    /// The walk day of `counts[0]`.
    let first: WalkedDayKey
    /// The walk day of `counts.last`.
    let today: WalkedDayKey
    /// Walked blocks citywide after each day, `first` through `today`.
    let counts: [Int]
    /// Where All starts: the first walked day, else the first day with a
    /// row, else today.
    let allStart: WalkedDayKey
    /// "312 blocks": Your Blocks' citywide count (never below the line).
    let headline: Int
    /// Blocks walked on each day, parallel to `counts` (#188): the day's
    /// `walkedIDs.count`, zero on a day without a row.
    let walked: [Int]
    /// New blocks on each day, parallel to `counts`: the day's `newCount`.
    let new: [Int]
    /// The Calendar tab's first weekday, 1 = Sunday (#188 eng E5).
    let firstWeekday: Int

    /// - Parameters:
    ///   - citywideWalked: Your Blocks' citywide count (`WalkedSummary`), or
    ///     `nil` before a count, when the line's last value stands in.
    ///   - today: today's walk day; a row dated later (a clock change)
    ///     extends the series to it.
    ///   - firstWeekday: where a weekly bar starts (#188 eng E5), the
    ///     Calendar grid's first weekday by default.
    init(
        history: WalkedHistory,
        citywideWalked: Int?,
        today: WalkedDayKey,
        firstWeekday: Int = YourWalksContent.layoutCalendar.firstWeekday
    ) {
        let end = max(today, history.days.last?.day ?? today)
        allStart = history.walkedDays.first?.day ?? history.days.first?.day ?? end
        let yearStart = end.dayNumber - (WalkProgressRange.year.dayCount ?? 1) + 1
        let firstNumber = min(yearStart, allStart.dayNumber)
        first = WalkedDayKey(dayNumber: firstNumber)
        self.today = end
        counts = Self.filled(history.cumulative, from: firstNumber, through: end.dayNumber)
        let lineLast = counts.last ?? 0
        headline = max(citywideWalked ?? lineLast, lineLast)
        let perDay = Self.perDay(history.days, from: firstNumber, count: counts.count)
        walked = perDay.walked
        new = perDay.new
        self.firstWeekday = firstWeekday
    }

    /// Each day's walked and new block counts from `start` (a day number)
    /// for `count` days, zero on a day without a row (#188 spec item 1).
    static func perDay(_ days: [WalkedDaySummary], from start: Int, count: Int) -> (walked: [Int], new: [Int]) {
        var walked = [Int](repeating: 0, count: count)
        var new = [Int](repeating: 0, count: count)
        for summary in days {
            let offset = summary.day.dayNumber - start
            guard offset >= 0, offset < count else { continue }
            walked[offset] = summary.walkedIDs.count
            new[offset] = summary.newCount
        }
        return (walked, new)
    }

    /// One count per day from `start` through `end` (day numbers): each
    /// day carries the last cumulative count on or before it, zero before
    /// the first. `points` is ascending by day, as `WalkedHistory` builds it.
    static func filled(_ points: [WalkedHistory.CumulativePoint], from start: Int, through end: Int) -> [Int] {
        guard end >= start else { return [] }
        var counts = [Int](repeating: 0, count: end - start + 1)
        var current = 0
        var next = points.startIndex
        for offset in counts.indices {
            let day = start + offset
            while next < points.endIndex, points[next].day.dayNumber <= day {
                current = points[next].count
                next += 1
            }
            counts[offset] = current
        }
        return counts
    }

    /// The count after `day`, zero before the series.
    func count(on day: WalkedDayKey) -> Int {
        let offset = day.dayNumber - first.dayNumber
        guard offset >= 0 else { return 0 }
        return counts.isEmpty ? 0 : counts[min(offset, counts.count - 1)]
    }

    /// `range`'s days, ending today.
    func slice(_ range: WalkProgressRange) -> WalkProgressSlice {
        let start = range.dayCount.map { today.advancedNumerically(by: -($0 - 1)) } ?? allStart
        let lower = start.dayNumber - first.dayNumber
        let days = max(0, lower) ..< counts.count
        let before = count(on: start.advancedNumerically(by: -1))
        let walked = Array(self.walked[days])
        let new = Array(self.new[days])
        return WalkProgressSlice(
            range: range,
            start: start,
            counts: Array(counts[days]),
            countBefore: before,
            walked: walked,
            new: new,
            bars: WalkDailyBars(start: start, walked: walked, new: new, firstWeekday: firstWeekday)
        )
    }
}

/// One range of the chart (DS6): its days, the gain over the range, the
/// y-domain, the axis ticks, the scrub lookup and the VoiceOver step.
nonisolated struct WalkProgressSlice: Equatable, Sendable {
    nonisolated struct Point: Equatable, Sendable, Identifiable {
        /// Days from the slice's start: the chart's x.
        let index: Int
        let day: WalkedDayKey
        let count: Int

        var id: Int { index }
    }

    /// How an axis tick names its day.
    nonisolated enum TickStyle: Equatable, Sendable {
        /// "Tue".
        case weekday
        /// "Nov 3".
        case monthDay
        /// "Nov".
        case month
        /// "2026".
        case year
    }

    nonisolated struct Tick: Equatable, Sendable {
        let index: Int
        let day: WalkedDayKey
        let style: TickStyle
    }

    let range: WalkProgressRange
    let start: WalkedDayKey
    /// The count after each day, `start` through today.
    let counts: [Int]
    /// The count just before `start` (DS6: the gain is measured from it).
    let countBefore: Int
    /// Blocks walked on each day, parallel to `counts` (#188).
    let walked: [Int]
    /// New blocks on each day, parallel to `counts` (#188).
    let new: [Int]
    /// The range's bars, built once with the slice (#188 eng E4).
    let bars: WalkDailyBars

    var dayCount: Int { counts.count }
    var lastIndex: Int { max(0, counts.count - 1) }
    /// A single datum draws a visible point, not a line (DS6).
    var isSingleDay: Bool { counts.count == 1 }
    /// New blocks over the range: "40 new in the past month".
    var gain: Int { (counts.last ?? countBefore) - countBefore }

    func day(at index: Int) -> WalkedDayKey { start.advancedNumerically(by: index) }

    /// The x-domain both charts share (#188 DS4): half a day past the
    /// first and last days, so a day's bar and the line's step sit on the
    /// same x; a single day spans -1 ... 1.
    var xDomain: ClosedRange<Double> {
        isSingleDay ? -1 ... 1 : -0.5 ... Double(lastIndex) + 0.5
    }

    func point(at index: Int) -> Point {
        Point(index: index, day: day(at: index), count: counts[index])
    }

    /// The points the line needs: the first, every day whose count changed,
    /// and the last. A step-end line through them draws exactly the daily
    /// series, with a few marks instead of hundreds.
    var linePoints: [Point] {
        counts.indices.compactMap { index in
            let keep = index == 0 || index == lastIndex || counts[index] != counts[index - 1]
            return keep ? point(at: index) : nil
        }
    }

    /// The scrubbed day (DS6): the day under the finger, clamped to the
    /// range; `nil` when nothing is selected (the finger lifted).
    func selection(at rawIndex: Int?) -> Point? {
        guard let rawIndex, !counts.isEmpty else { return nil }
        return point(at: min(max(rawIndex, 0), lastIndex))
    }

    /// VoiceOver's adjustable step (DS6): one day at a time, starting from
    /// today, stopping at both ends.
    func stepped(from index: Int?, by delta: Int) -> Int {
        guard let index else { return lastIndex }
        return min(max(index + delta, 0), lastIndex)
    }

    /// From the range's minimum to its maximum, or from zero for All (DS6).
    /// A flat range gets a one-block margin so the line is not on an edge
    /// that the axis hides; never below zero.
    var yDomain: ClosedRange<Int> {
        let low = range == .all ? 0 : (counts.min() ?? 0)
        let high = counts.max() ?? 0
        guard high > low else { return max(0, low - 1) ... high + 1 }
        return low ... high
    }

    var yTicks: [Int] { Self.yTicks(for: yDomain) }

    /// Whole-block gridlines whose top is always the domain's top (the
    /// range's maximum, usually the headline): every block for a span of 5
    /// or less; otherwise multiples of a 1, 2 or 5 times a power of ten step
    /// (about four across the domain) from the bottom up, then the top,
    /// leaving out a multiple less than a step below the top so no two
    /// labels crowd.
    static func yTicks(for domain: ClosedRange<Int>) -> [Int] {
        let span = domain.upperBound - domain.lowerBound
        guard span > 5 else { return Array(domain) }
        let step = niceStep(Double(span) / 4)
        let first = Int((Double(domain.lowerBound) / Double(step)).rounded(.up)) * step
        let below = stride(from: first, to: domain.upperBound, by: step).filter {
            domain.upperBound - $0 >= step
        }
        return below + [domain.upperBound]
    }

    static func niceStep(_ raw: Double) -> Int {
        guard raw > 1 else { return 1 }
        let magnitude = pow(10, floor(log10(raw)))
        let multiple = [1.0, 2, 5, 10].first { $0 * magnitude >= raw } ?? 10
        return Int(multiple * magnitude)
    }

    /// The narrowest plot the ticks are spaced for, in points: an iPhone SE
    /// (375 pt) less the 16 pt insets and the trailing y labels. Wider plots
    /// only widen the gaps.
    static let minimumPlotWidth: Double = 300
    /// A clear gap between neighbouring labels, in points.
    static let labelGap: Double = 8

    /// A label's width allowance in points at the default text size (the
    /// axis does not scale past it), measured on the simulator ("Nov 18"
    /// about 35 pt, "Wed" about 22 pt) and rounded up, plus Swift Charts'
    /// offset of a label after its gridline.
    static func labelWidth(_ style: TickStyle) -> Double {
        switch style {
        case .weekday, .month: 30
        case .monthDay: 46
        case .year: 38
        }
    }

    /// The x-axis labels. Today is always labelled, its label ending at the
    /// plot's trailing edge ("Wed" in a week, "Nov 18" otherwise); every
    /// other label sits after its gridline. Candidates: every day of a week,
    /// every seventh day back from today in a month, each month's first up
    /// to four months, each quarter's first (January as its year) up to two
    /// years, then each year's first. Walking back from today, a candidate
    /// is kept only when its label, and today's when the next kept tick is
    /// today, fit before the next kept gridline with `labelGap` to spare on
    /// a `minimumPlotWidth` plot, so neighbouring labels never touch. The
    /// plot spans `lastIndex + 1` days (`xDomain`, #188 DS4).
    var xTicks: [Tick] {
        let count = counts.count
        guard count > 1 else { return count == 1 ? [Tick(index: 0, day: start, style: .monthDay)] : [] }
        let today = Tick(index: lastIndex, day: day(at: lastIndex), style: count <= 7 ? .weekday : .monthDay)
        let pointsPerDay = Self.minimumPlotWidth / Double(lastIndex + 1)
        var kept = [today]
        for candidate in tickCandidates.reversed() where candidate.index < lastIndex {
            let next = kept[kept.count - 1]
            var needed = Self.labelWidth(candidate.style) + Self.labelGap
            if next.index == lastIndex { needed += Self.labelWidth(today.style) }
            if Double(next.index - candidate.index) * pointsPerDay >= needed { kept.append(candidate) }
        }
        return kept.reversed()
    }

    /// Every tick the range could label, oldest first, before spacing.
    private var tickCandidates: [Tick] {
        let count = counts.count
        if count <= 7 { return counts.indices.map { Tick(index: $0, day: day(at: $0), style: .weekday) } }
        if count <= 31 {
            return stride(from: lastIndex, through: 0, by: -7).reversed().map {
                Tick(index: $0, day: day(at: $0), style: .monthDay)
            }
        }
        return counts.indices.compactMap { index in
            let day = day(at: index)
            guard day.day == 1 else { return nil }
            if count <= 124 { return Tick(index: index, day: day, style: .month) }
            if count <= 731 {
                guard [1, 4, 7, 10].contains(day.month) else { return nil }
                return Tick(index: index, day: day, style: day.month == 1 ? .year : .month)
            }
            return day.month == 1 ? Tick(index: index, day: day, style: .year) : nil
        }
    }
}

// MARK: Day numbers

/// Whole days since 1970-01-01 for a key's civil date (Howard Hinnant's
/// `days_from_civil`), so filling a year of days is arithmetic, not a
/// `Calendar` call per day. Civil dates only: the 4 am start is already in
/// the key.
nonisolated extension WalkedDayKey {
    var dayNumber: Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    init(dayNumber: Int) {
        let shifted = dayNumber + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        self.init(year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }

    /// `advanced(by:)` without a `Calendar`: the same civil date arithmetic.
    func advancedNumerically(by days: Int) -> WalkedDayKey {
        days == 0 ? self : WalkedDayKey(dayNumber: dayNumber + days)
    }
}
