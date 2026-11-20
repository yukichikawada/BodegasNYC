import Foundation

// MARK: - Your Walks Progress: blocks per day (#188, design DS6 to DS19)

/// The bars' templates. Counts and dates are data; the voice test runs
/// them over every unit, zero, one and many, and every span shape. Dates are
/// New York walk days in a fixed `en_US` locale, as the line chart's are.
nonisolated extension AppCopy {
    /// Between a span's two ends, spaced (eng E11): "Nov 9 – 15".
    static let walkSpanDash = " \u{2013} "

    /// The bars' heading (DS9): "Blocks per Day", "Blocks per Week",
    /// "Blocks per Month", "Blocks per Year". Also the Audio Graph's series.
    static func walkBarsHeading(_ unit: WalkDailyBars.Unit) -> CopyString {
        CopyString(kind: .label, text: "Blocks per \(unitName(unit).capitalized)")
    }

    /// The bars' VoiceOver label (DS18): "Bar chart of blocks per day.".
    static func walkBarsChartLabel(_ unit: WalkDailyBars.Unit) -> CopyString {
        CopyString(kind: .body, text: "Bar chart of blocks per \(unitName(unit)).")
    }

    /// A fixed range with no counted block (eng E10, DS11): "No blocks
    /// counted in the past week."; `nil` when the range has a block, and
    /// for All, whose empty state is the sheet's "No blocks counted yet.".
    static func walkBarsEmptyLine(_ slice: WalkProgressSlice) -> CopyString? {
        guard slice.range != .all, slice.bars.walkedDayCount == 0 else { return nil }
        return CopyString(kind: .body, text: "No blocks counted \(walkRangePhrase(slice)).")
    }

    /// The bars' VoiceOver value at rest (DS7): "Blocks counted on 12 days
    /// in the past month." or "Blocks counted on 68 days since Mar 2024.",
    /// counting days with at least one block; an empty range reads its
    /// empty line, an All with no counted block "No blocks counted yet.".
    static func walkBarsRestValue(_ slice: WalkProgressSlice) -> CopyString {
        let days = slice.bars.walkedDayCount
        guard days > 0 else { return walkBarsEmptyLine(slice) ?? YourWalks.noBlocksYet.copy }
        let count = days == 1 ? "1 day" : "\(groupedCount(days)) days"
        return CopyString(kind: .body, text: "Blocks counted on \(count) \(walkRangePhrase(slice)).")
    }

    /// A bar's counts (DS8), from the day strings: "19 blocks, 12 new",
    /// "7 blocks" (no new block), "0 blocks".
    static func walkBarCounts(total: Int, new: Int) -> CopyString {
        let text = new > 0 ? "\(walkDayBlocks(total).text), \(walkDayNew(new).text)" : walkDayBlocks(total).text
        return CopyString(kind: .value, text: text)
    }

    /// A bar's dates (DS8, eng E11): "Nov 3" for a day; "Nov 9 – 15",
    /// "Oct 30 – Nov 5" for a span, with ", 2025" when it is not in
    /// today's year and on both ends when its years differ ("Dec 28, 2026 –
    /// Jan 3, 2027"); a whole month "Nov 2026", a whole year "2026"; a month
    /// or year clipped by the range reads its dates. The cross-year shape
    /// runs past a value's four words, as `sharedWalkDates` does;
    /// `AppCopyVoiceTests` holds it to every other rule.
    static func walkBarDates(_ bar: WalkDailyBars.Bar, in bars: WalkDailyBars) -> CopyString {
        let first = bars.day(at: bar.startIndex)
        let last = bars.day(at: bar.endIndex)
        if bars.isWholePeriod(bar) {
            let format = bars.unit == .month ? walkDateStyle.month(.abbreviated).year() : walkDateStyle.year()
            return CopyString(kind: .value, text: first.noon.formatted(format))
        }
        let thisYear = bars.day(at: bars.dayCount - 1).year
        let short = { (day: WalkedDayKey, withYear: Bool) in monthDay(day, month: .abbreviated, withYear: withYear) }
        let text: String
        if first == last {
            text = short(first, first.year != thisYear)
        } else if first.year != last.year {
            text = short(first, true) + walkSpanDash + short(last, true)
        } else {
            let end = first.month == last.month ? "\(last.day)" : short(last, false)
            text = short(first, false) + walkSpanDash + end + (last.year == thisYear ? "" : ", \(last.year)")
        }
        return CopyString(kind: .value, text: text)
    }

    /// The bars' second line while scrubbing (DS8): the counts, then the
    /// dates, "19 blocks, 12 new · Nov 3". Two values; the view joins them
    /// with `walksSeparator`, or stacks them at accessibility sizes (DS13).
    static func walkBarReadout(_ bar: WalkDailyBars.Bar, in bars: WalkDailyBars) -> [String] {
        [walkBarCounts(total: bar.total, new: bar.new).text, walkBarDates(bar, in: bars).text]
    }

    /// The longest readout the slice can produce (DS13): its largest total
    /// and new count, and its longest dates, laid out hidden so the second
    /// line keeps one height while scrubbing.
    static func walkBarReserve(_ bars: WalkDailyBars) -> [String] {
        let total = bars.buckets.map(\.total).max() ?? 0
        let new = bars.buckets.map(\.new).max() ?? 0
        let dates = bars.buckets.map { walkBarDates($0, in: bars).text }.max { $0.count < $1.count } ?? ""
        return [walkBarCounts(total: total, new: new).text, dates]
    }

    /// The bars' VoiceOver value while stepping (DS18): "Tuesday, November
    /// 3, 14 blocks, 9 new."; "November 9 to 15, 64 blocks, 22 new.";
    /// "November 2026, 180 blocks, 40 new."; "2026, ..."; a clipped month
    /// "November 1 to 20, ..."; a bucket without a walk "..., 0 blocks.".
    /// Spans are spoken with "to", never a dash.
    static func walkBarSpokenValue(_ bar: WalkDailyBars.Bar, in bars: WalkDailyBars) -> CopyString {
        let counts = walkBarCounts(total: bar.total, new: bar.new).text
        return CopyString(kind: .body, text: "\(walkBarSpokenDates(bar, in: bars)), \(counts).")
    }

    /// "Tuesday, November 3" for a day (`walkDayDate`, as the Calendar
    /// reads it); "November 9 to 15", "October 30 to November 5", with
    /// ", 2025" outside today's year and on both ends across years;
    /// "November 2026" and "2026" for whole periods.
    static func walkBarSpokenDates(_ bar: WalkDailyBars.Bar, in bars: WalkDailyBars) -> String {
        let first = bars.day(at: bar.startIndex)
        let last = bars.day(at: bar.endIndex)
        if bars.unit == .day { return walkDayDate(first).text }
        if bars.isWholePeriod(bar) {
            let format = bars.unit == .month ? walkDateStyle.month(.wide).year() : walkDateStyle.year()
            return first.noon.formatted(format)
        }
        let thisYear = bars.day(at: bars.dayCount - 1).year
        let long = { (day: WalkedDayKey, withYear: Bool) in monthDay(day, month: .wide, withYear: withYear) }
        if first == last { return long(first, first.year != thisYear) }
        if first.year != last.year { return long(first, true) + " to " + long(last, true) }
        let end = first.month == last.month ? "\(last.day)" : long(last, false)
        return long(first, false) + " to " + end + (last.year == thisYear ? "" : ", \(last.year)")
    }

    /// "Nov 3", "November 3", with ", 2025" when `withYear`.
    private static func monthDay(_ day: WalkedDayKey, month: Date.FormatStyle.Symbol.Month, withYear: Bool) -> String {
        let format = walkDateStyle.month(month).day()
        return day.noon.formatted(withYear ? format.year() : format)
    }

    private static func unitName(_ unit: WalkDailyBars.Unit) -> String {
        switch unit {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .year: "year"
        }
    }
}
