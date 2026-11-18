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
        /// The menu item's VoiceOver hint (DS8.7, PR 1 wording).
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

        var copy: CopyString {
            switch self {
            case .title: CopyString(kind: .label, text: "Your Walks")
            case .menuHint: CopyString(kind: .body, text: "Shows the days you walked.")
            case .findingWalks: CopyString(kind: .value, text: "Finding your walks")
            case .noBlocksYet: CopyString(kind: .body, text: "No blocks counted yet.")
            case .historyFailed:
                CopyString(kind: .body, text: "Your days couldn't be loaded. Your walks are still saved.")
            case .estimates: CopyString(kind: .body, text: "Older days are estimates. Some rides may be counted.")
            case .footer:
                CopyString(kind: .body, text: "A block counts once a day. Miles include repeats. Days start at 4 a.m.")
            case .todayPending: CopyString(kind: .body, text: "Today shows up once it's counted.")
            case .dayMapLabel: CopyString(kind: .body, text: "Map of this day's walk.")
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

    /// A day's distance in spelled-out miles (DS4): "1.4 miles", "1 mile".
    static func walkDayDistance(meters: Double) -> CopyString {
        distanceValue(.miles(max(0, meters) / BlockDistance.metersPerMile))
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

    private static var walkDateStyle: Date.FormatStyle {
        Date.FormatStyle(
            locale: Locale(identifier: "en_US"),
            calendar: WalkedDayKey.calendar,
            timeZone: WalkedDayKey.timeZone
        )
    }

    private static func groupedCount(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}
