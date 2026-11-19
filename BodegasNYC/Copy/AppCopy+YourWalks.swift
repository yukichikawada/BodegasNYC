import Foundation

// MARK: - Your Walks (#170 PR 1, design DS1 to DS8)

nonisolated extension AppCopy {
    /// The Your Walks strings, nested like `YourBlocks` (`AppCopy`'s body
    /// sits at SwiftLint's type length): one case per string, an exhaustive
    /// `copy`, and `allCases` in `AppCopyVoiceTests`. The failure, recording
    /// and Open Settings lines are Your Blocks' own (design DS8.2).
    nonisolated enum YourWalks: CaseIterable, Hashable, Sendable {
        /// The menu item and the sheet's title.
        case title
        /// The menu item's VoiceOver hint (DS8.7, PR 2 wording).
        case menuHint
        /// Under the title on a first load, from 0 s (DS8.2); shown with a
        /// trailing ellipsis (`withTrailingEllipsis`).
        case findingWalks
        /// History, but no day with a walked block yet (DS8.2).
        case noBlocksYet
        /// The day rows could not be read (eng A6, DS8.2); `.primary`.
        case historyFailed
        /// Under a month with estimated days, and on an estimated day (DS5).
        case estimates
        /// The sheet's footer (DS5).
        case footer
        /// While recording (DS8.2).
        case todayPending
        /// The day map's one VoiceOver element (DS7).
        case dayMapLabel
        /// A walked day's distance when it rounds to "0" miles: a walked day
        /// always went somewhere, so it never reads "0 miles".
        case underATenthOfAMile
        /// The title's VoiceOver action: what a tap on it does (DS2).
        case showThisMonth
        /// The switch under the title (PR 2, DS6): its label and segments.
        case tabPicker
        case calendarTab
        case progressTab
        /// The range picker under the chart (DS6).
        case rangePicker
        /// The chart's one adjustable VoiceOver element (DS6).
        case chartLabel
        /// The Audio Graph's axes and series (spec AC 13).
        case chartDayAxis
        case chartBlocksAxis
        case chartSeries

        var copy: CopyString {
            switch self {
            case .title: CopyString(kind: .label, text: "Your Walks")
            case .menuHint: CopyString(kind: .body, text: "Shows the days you walked and your progress.")
            case .findingWalks: CopyString(kind: .value, text: "Finding your walks")
            case .noBlocksYet: CopyString(kind: .body, text: "No blocks counted yet.")
            case .historyFailed:
                CopyString(kind: .body, text: "Your days couldn't be loaded. Your walks are still saved.")
            // #180 DS5: an imported day can be last week's, so not "Older".
            case .estimates: CopyString(kind: .body, text: "Some days are estimates. Rides may be counted.")
            case .footer:
                CopyString(kind: .body, text: "A block counts once a day. Miles include repeats. Days start at 4 a.m.")
            case .todayPending: CopyString(kind: .body, text: "Today shows up once it's counted.")
            case .dayMapLabel: CopyString(kind: .body, text: "Map of this day's walk.")
            case .underATenthOfAMile: CopyString(kind: .value, text: "Less than 0.1 miles")
            case .showThisMonth: CopyString(kind: .label, text: "Show This Month")
            case .tabPicker: CopyString(kind: .label, text: "Calendar or Progress")
            case .calendarTab: CopyString(kind: .label, text: "Calendar")
            case .progressTab: CopyString(kind: .label, text: "Progress")
            case .rangePicker: CopyString(kind: .label, text: "Range")
            case .chartLabel: CopyString(kind: .body, text: "Chart of the blocks you walked.")
            case .chartDayAxis: CopyString(kind: .label, text: "Day")
            case .chartBlocksAxis: CopyString(kind: .label, text: "Blocks")
            case .chartSeries: CopyString(kind: .label, text: "Blocks Walked")
            }
        }

        /// The text with a trailing "…" (a status still in progress).
        var withTrailingEllipsis: String {
            copy.text + "\u{2026}"
        }
    }
}

/// Dates and counts are data, so these are templates; the voice test runs
/// them over fixtures covering zero, one and many. Dates are New York walk
/// days in a fixed `en_US` locale (the app is English-only).
nonisolated extension AppCopy {
    /// Between a month's two counts and a list row's counts and miles.
    static let walksSeparator = " \u{00B7} "

    /// A month header (DS2): "November 2026".
    static func walkMonthTitle(_ day: WalkedDayKey) -> CopyString {
        CopyString(kind: .value, text: day.noon.formatted(walkDateStyle.month(.wide).year()))
    }

    /// A month's walked days (DS2): "8 days", "1 day", "0 days".
    static func walkMonthDays(_ count: Int) -> CopyString {
        CopyString(kind: .value, text: count == 1 ? "1 day" : "\(groupedCount(count)) days")
    }

    /// A month's new blocks (DS2): "24 new blocks", "1 new block".
    static func walkMonthNewBlocks(_ count: Int) -> CopyString {
        CopyString(kind: .value, text: count == 1 ? "1 new block" : "\(groupedCount(count)) new blocks")
    }

    /// A day's blocks (DS4): "14 blocks", "1 block".
    static func walkDayBlocks(_ count: Int) -> CopyString {
        CopyString(kind: .value, text: count == 1 ? "1 block" : "\(groupedCount(count)) blocks")
    }

    /// A day's new blocks (DS4), omitted by the views at zero: "9 new".
    static func walkDayNew(_ count: Int) -> CopyString {
        CopyString(kind: .value, text: "\(groupedCount(count)) new")
    }

    /// A day's distance in spelled-out miles (DS4): "1.4 miles", "1 mile",
    /// and "Less than 0.1 miles" for a positive distance that would round to
    /// "0 miles" (under 0.05 miles, about 80 m). Decided on the rendered
    /// text, so the boundary is exactly `distanceValue`'s rounding.
    static func walkDayDistance(meters: Double) -> CopyString {
        let distance = distanceValue(.miles(max(0, meters) / BlockDistance.metersPerMile))
        return meters > 0 && distance.text == "0 miles" ? YourWalks.underATenthOfAMile.copy : distance
    }

    /// The day detail's title (DS8.4): "Nov 3, 2025".
    static func walkDayTitle(_ day: WalkedDayKey) -> CopyString {
        CopyString(kind: .value, text: day.noon.formatted(walkDateStyle.month(.abbreviated).day().year()))
    }

    /// A day in the accessibility list and in VoiceOver: "Tuesday, November 3".
    static func walkDayDate(_ day: WalkedDayKey) -> CopyString {
        CopyString(kind: .value, text: day.noon.formatted(walkDateStyle.weekday(.wide).month(.wide).day()))
    }

    /// A walked day's one VoiceOver element (DS8.5, DS1, DS5): "Tuesday,
    /// November 3, 14 blocks, 9 new, 1.4 miles.", with "today" after the
    /// date and "estimate" at the end when they apply.
    static func walkDayLabel(_ summary: WalkedDaySummary, isToday: Bool, isEstimate: Bool) -> CopyString {
        var parts = [walkDayDate(summary.day).text]
        if isToday { parts.append("today") }
        parts.append(walkDaySummaryParts(summary).joined(separator: ", "))
        if isEstimate { parts.append("estimate") }
        return CopyString(kind: .body, text: parts.joined(separator: ", ") + ".")
    }

    /// A day without walks reads its date only, plus "today" (DS8.5, DS1).
    static func walkPlainDayLabel(_ day: WalkedDayKey, isToday: Bool) -> CopyString {
        let date = walkDayDate(day).text
        return CopyString(kind: .value, text: isToday ? "\(date), today" : date)
    }

    /// The day map's value (spec, DS7): "14 blocks, 9 new, 1.4 miles.".
    static func walkDaySummary(_ summary: WalkedDaySummary) -> CopyString {
        CopyString(kind: .body, text: walkDaySummaryParts(summary).joined(separator: ", ") + ".")
    }

    /// "14 blocks", "9 new" (omitted at zero), "1.4 miles".
    private static func walkDaySummaryParts(_ summary: WalkedDaySummary) -> [String] {
        var parts = [walkDayBlocks(summary.walkedIDs.count).text]
        if summary.newCount > 0 { parts.append(walkDayNew(summary.newCount).text) }
        parts.append(walkDayDistance(meters: summary.meters).text)
        return parts
    }

    // MARK: Progress (PR 2, DS6)

    /// A range segment as shown: "1W", "1M", "3M", "1Y", "All".
    static func walkRangeShort(_ range: WalkProgressRange) -> CopyString {
        let text = switch range {
        case .week: "1W"
        case .month: "1M"
        case .threeMonths: "3M"
        case .year: "1Y"
        case .all: "All"
        }
        return CopyString(kind: .value, text: text)
    }

    /// A range segment as VoiceOver reads it (DS8.5): "1 week", "1 month",
    /// "3 months", "1 year", "All".
    static func walkRangeSpoken(_ range: WalkProgressRange) -> CopyString {
        let text = switch range {
        case .week: "1 week"
        case .month: "1 month"
        case .threeMonths: "3 months"
        case .year: "1 year"
        case .all: "All"
        }
        return CopyString(kind: .value, text: text)
    }

    /// The header's second line at rest (DS6): "40 new in the past month."
    /// for a fixed range, "Since Mar 2024." for All (from the first walked
    /// day). A sentence, so it ends with a period like the status lines
    /// under the title; it is too long for a value's four words.
    static func walkProgressSummary(_ slice: WalkProgressSlice) -> CopyString {
        let text = walkProgressSummaryText(slice)
        return CopyString(kind: .body, text: text.prefix(1).uppercased() + text.dropFirst() + ".")
    }

    /// The chart's VoiceOver value at rest (DS6): "312 blocks, 40 new in
    /// the past month." or "312 blocks since Mar 2024.".
    static func walkProgressRestValue(headline: Int, slice: WalkProgressSlice) -> CopyString {
        let separator = slice.range == .all ? " " : ", "
        let text = walkDayBlocks(headline).text + separator + walkProgressSummaryText(slice)
        return CopyString(kind: .body, text: text + ".")
    }

    /// "40 new in the past month", "since Mar 2024".
    private static func walkProgressSummaryText(_ slice: WalkProgressSlice) -> String {
        let period = switch slice.range {
        case .week: "week"
        case .month: "month"
        case .threeMonths: "3 months"
        case .year: "year"
        case .all: ""
        }
        guard slice.range != .all else {
            return "since " + slice.start.noon.formatted(walkDateStyle.month(.abbreviated).year())
        }
        return "\(groupedCount(slice.gain)) new in the past \(period)"
    }

    /// The chart's VoiceOver value while stepping (DS6): "298 blocks, Nov 3,
    /// 2025.".
    static func walkProgressValue(count: Int, day: WalkedDayKey) -> CopyString {
        CopyString(kind: .body, text: "\(walkDayBlocks(count).text), \(walkDayTitle(day).text).")
    }

    /// An x-axis label: "Tue", "Nov 3", "Nov", "2026".
    static func walkChartAxisLabel(_ day: WalkedDayKey, style: WalkProgressSlice.TickStyle) -> CopyString {
        let format = switch style {
        case .weekday: walkDateStyle.weekday(.abbreviated)
        case .monthDay: walkDateStyle.month(.abbreviated).day()
        case .month: walkDateStyle.month(.abbreviated)
        case .year: walkDateStyle.year()
        }
        return CopyString(kind: .value, text: day.noon.formatted(format))
    }

    private static var walkDateStyle: Date.FormatStyle {
        Date.FormatStyle(
            locale: Locale(identifier: "en_US"),
            calendar: WalkedDayKey.calendar,
            timeZone: WalkedDayKey.timeZone
        )
    }

    /// "1,204", en_US grouping (also the Shared Walk sheet's coverage line).
    static func groupedCount(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}
