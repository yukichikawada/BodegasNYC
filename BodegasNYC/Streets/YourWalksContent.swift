import Foundation

/// One day cell of the calendar (#170 design DS1, DS3, DS8.1, DS8.5).
struct WalkCalendarDay: Equatable, Identifiable {
    let key: WalkedDayKey
    /// `nil` on a day with no row; a row with no walked block is no dot.
    let summary: WalkedDaySummary?
    let isToday: Bool
    let isEstimate: Bool

    var id: Int { key.value }
    var number: Int { key.day }
    /// A dot, and a button into the day (eng E3).
    var isWalked: Bool { summary?.isWalked == true }

    var accessibilityLabel: String {
        guard let summary, summary.isWalked else {
            return AppCopy.walkPlainDayLabel(key, isToday: isToday).text
        }
        return AppCopy.walkDayLabel(summary, isToday: isToday, isEstimate: isEstimate).text
    }
}

/// One month of the vertical scroll (DS2): its header, its summary in
/// walked days and new blocks, and its grid, with leading blanks for the
/// weekday the month starts on.
struct WalkMonth: Equatable, Identifiable {
    /// The first of the month.
    let first: WalkedDayKey
    let leadingBlanks: Int
    let days: [WalkCalendarDay]

    var id: Int { first.value }
    var title: String { AppCopy.walkMonthTitle(first).text }
    var walkedDays: [WalkCalendarDay] { days.filter(\.isWalked) }
    var walkedDayCount: Int { walkedDays.count }
    var newBlockCount: Int { walkedDays.reduce(0) { $0 + ($1.summary?.newCount ?? 0) } }
    /// "Older days are estimates." goes under this month (DS5).
    var hasEstimate: Bool { walkedDays.contains(where: \.isEstimate) }
    /// "8 days", "24 new blocks"; none for a month without walks.
    var summaryParts: [String] {
        guard walkedDayCount > 0 else { return [] }
        return [AppCopy.walkMonthDays(walkedDayCount).text, AppCopy.walkMonthNewBlocks(newBlockCount).text]
    }

    /// The months from `start`'s through `end`'s, in order. `layout` places
    /// the weekdays (`Calendar.current` in New York time, eng A7); the days
    /// themselves are always New York walk days.
    static func months(
        from start: WalkedDayKey,
        through end: WalkedDayKey,
        history: WalkedHistory?,
        today: WalkedDayKey,
        layout: Calendar
    ) -> [WalkMonth] {
        var months: [WalkMonth] = []
        var first = WalkedDayKey(year: start.year, month: start.month, day: 1)
        let last = WalkedDayKey(year: end.year, month: end.month, day: 1)
        while first <= last {
            months.append(month(first, history: history, today: today, layout: layout))
            let next = first.month == 12 ? (first.year + 1, 1) : (first.year, first.month + 1)
            first = WalkedDayKey(year: next.0, month: next.1, day: 1)
        }
        return months
    }

    static func month(
        _ first: WalkedDayKey,
        history: WalkedHistory?,
        today: WalkedDayKey,
        layout: Calendar
    ) -> WalkMonth {
        let noon = first.noon
        let count = layout.range(of: .day, in: .month, for: noon)?.count ?? 30
        let weekday = layout.component(.weekday, from: noon)
        let blanks = (weekday - layout.firstWeekday + 7) % 7
        let days = (1 ... count).map { number in
            let key = WalkedDayKey(year: first.year, month: first.month, day: number)
            let summary = history?.summary(for: key)
            return WalkCalendarDay(
                key: key,
                summary: summary,
                isToday: key == today,
                isEstimate: summary?.isWalked == true && history?.isEstimate(key) == true
            )
        }
        return WalkMonth(first: first, leadingBlanks: blanks, days: days)
    }
}

/// What the Your Walks sheet shows (#170 PR 1, design DS2, DS5, DS8.2), as a
/// pure function of the view model's state, so the precedence is
/// unit-tested without a view.
struct YourWalksContent: Equatable {
    /// DS8.2, in the Your Blocks order: failure > loading > empty.
    enum Phase: Equatable {
        /// The street data did not load: Your Blocks' line, no grid.
        case streetMapUnavailable
        /// The day rows could not be read (eng A6): one line, no grid.
        case historyFailed
        /// No fix stored: no grid, the no-streets copy.
        case noHistory
        /// The first read is running: this month's grid, numbers muted, no
        /// dots, "Finding your walks…" under the title from 0 s.
        case loading
        /// History, but no day with a walked block: grid without dots and
        /// "No blocks counted yet." under the title.
        case noWalkedDay
        case ready
    }

    var phase: Phase
    /// First walked month (or this one) through this month, oldest first.
    var months: [WalkMonth]
    var isRecording: Bool
    var isRecordingOff: Bool
    var pausedProblem: RecorderProblem?
    /// The walked days, so an open day closes when Clear History empties it
    /// (DS8.3).
    var walkedDays: Set<WalkedDayKey>

    var showsGrid: Bool { Self.showsGrid(phase) }

    static func showsGrid(_ phase: Phase) -> Bool {
        switch phase {
        case .loading, .noWalkedDay, .ready: true
        case .streetMapUnavailable, .historyFailed, .noHistory: false
        }
    }

    /// The one line under the title (DS8.2), if any.
    var statusLine: String? {
        switch phase {
        case .loading: AppCopy.YourWalks.findingWalks.withTrailingEllipsis
        case .noWalkedDay: AppCopy.YourWalks.noBlocksYet.copy.text
        default: nil
        }
    }

    var showsPausedSettingsRow: Bool { pausedProblem?.opensSettings == true }

    init(
        countState: StreetsWalkedViewModel.CountState,
        hasHistory: Bool,
        history: WalkedHistory?,
        historyFailed: Bool,
        isRecording: Bool,
        pausedProblem: RecorderProblem?,
        now: Date,
        layout: Calendar
    ) {
        let phase = Self.phase(
            countState: countState,
            hasHistory: hasHistory,
            history: history,
            historyFailed: historyFailed
        )
        self.phase = phase
        let today = WalkedDayKey(date: now)
        let walked = history?.walkedDays ?? []
        walkedDays = Set(walked.map(\.day))
        let start = switch phase {
        case .ready: walked.first?.day ?? today
        case .noWalkedDay: history?.days.first?.day ?? today
        default: today
        }
        months = Self.showsGrid(phase)
            ? WalkMonth.months(from: min(start, today), through: today, history: history, today: today, layout: layout)
            : []
        self.isRecording = isRecording
        isRecordingOff = !isRecording && pausedProblem == nil
        self.pausedProblem = pausedProblem
    }

    static func phase(
        countState: StreetsWalkedViewModel.CountState,
        hasHistory: Bool,
        history: WalkedHistory?,
        historyFailed: Bool
    ) -> Phase {
        if countState == .unavailable { return .streetMapUnavailable }
        if history == nil, historyFailed { return .historyFailed }
        guard hasHistory else { return .noHistory }
        guard let history else { return .loading }
        return history.days.contains(where: \.isWalked) ? .ready : .noWalkedDay
    }

    /// The months the grid draws for `layout`, as `Calendar.current` with
    /// New York's zone (eng A7).
    static var layoutCalendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = WalkedDayKey.timeZone
        return calendar
    }
}
