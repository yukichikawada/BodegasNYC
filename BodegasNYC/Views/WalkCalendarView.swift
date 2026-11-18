import SwiftUI

/// Your Walks' calendar (#170 design DS1 to DS3, DS5, DS8): one vertical
/// scroll of months, first walked month to this one, opened at the bottom.
/// Each month is a header ("November 2026", `.headline`, header trait) over
/// "8 days · 24 new blocks" in `textMuted`, then an edge-to-edge seven-column
/// grid (DESIGN.md Layout's centred-grid exception). At accessibility sizes
/// each month lists its walked days instead, date over counts, fully
/// scaling; the swap is the app's 0.25 s opacity change.
struct WalkCalendarView: View {
    let content: YourWalksContent
    /// A change scrolls to the current month (the title tap, DS2).
    let scrollToCurrentMonth: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let usesList = dynamicTypeSize.isAccessibilitySize
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(content.months) { month in
                        WalkMonthSection(month: month, usesList: usesList)
                            .id(month.id)
                    }
                    footer
                }
                .padding(.vertical, 16)
                .animation(.easeInOut(duration: 0.25), value: usesList)
            }
            .defaultScrollAnchor(.bottom)
            .safeAreaInset(edge: .top, spacing: 0) { statusLine }
            .onChange(of: scrollToCurrentMonth) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(Self.footerID, anchor: .bottom)
                }
            }
        }
    }

    private static let footerID = "yourWalks.footer"

    /// "Finding your walks…" or "No blocks counted yet." under the title.
    @ViewBuilder
    private var statusLine: some View {
        if let line = content.statusLine {
            Text(line)
                .font(.subheadline)
                .foregroundStyle(Color.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))
        }
    }

    /// The sheet's footer (DS5), and the recording line (DS8.2).
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.YourWalks.footer.copy.text)
            if content.isRecording {
                Text(AppCopy.YourWalks.todayPending.copy.text)
            }
        }
        .font(.footnote)
        .foregroundStyle(Color.textMuted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .id(Self.footerID)
    }
}

/// One month: header, grid or list, and the estimate line (DS5).
private struct WalkMonthSection: View {
    let month: WalkMonth
    let usesList: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .padding(.horizontal, 16)
            Group {
                if usesList {
                    WalkDayList(days: month.walkedDays)
                } else {
                    WalkMonthGrid(month: month)
                }
            }
            .transition(.opacity)
            if month.hasEstimate {
                Text(AppCopy.YourWalks.estimates.copy.text)
                    .font(.footnote)
                    .foregroundStyle(Color.textMuted)
                    .padding(.horizontal, 16)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(month.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            let parts = month.summaryParts
            if !parts.isEmpty {
                Text(parts.joined(separator: AppCopy.walksSeparator))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Color.textMuted)
                    .accessibilityLabel(parts.joined(separator: ", "))
            }
        }
    }
}

/// The seven-column grid: weekday initials (hidden from VoiceOver), then a
/// cell per day, at least 44 pt tall, numbers capped at `.xxxLarge` (DS3).
private struct WalkMonthGrid: View {
    let month: WalkMonth
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(Array(Self.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption)
                        .foregroundStyle(Color.textMuted)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            LazyVGrid(columns: Self.columns, spacing: 0) {
                ForEach(0 ..< month.leadingBlanks, id: \.self) { _ in
                    Color.clear
                        .frame(minHeight: 44)
                        .accessibilityHidden(true)
                }
                ForEach(month.days) { day in
                    WalkDayCell(day: day)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// The very short weekday names from the layout calendar, starting on
    /// its first weekday.
    private static var weekdaySymbols: [String] {
        let calendar = YourWalksContent.layoutCalendar
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
}

/// A day: its number (`.body`, monospaced; `.primary` when walked,
/// `textMuted` otherwise; bold today, never green, DS1) over a 6 pt `walked`
/// dot when a block was walked (E3). A walked day is one button into its
/// map; any other day reads its date only and is not a button (DS8.5).
private struct WalkDayCell: View {
    let day: WalkCalendarDay
    @ScaledMetric(relativeTo: .body) private var dotGap: CGFloat = 4

    var body: some View {
        if day.isWalked {
            NavigationLink(value: day.key) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(day.accessibilityLabel)
                .accessibilityIdentifier("yourWalks.day.\(day.key.value)")
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.accessibilityLabel)
        }
    }

    private var label: some View {
        VStack(spacing: dotGap) {
            Text(String(day.number))
                .font(.body)
                .fontWeight(day.isToday ? .bold : .regular)
                .monospacedDigit()
                .foregroundStyle(day.isWalked ? Color.primary : Color.textMuted)
            Circle()
                .fill(Color.walked)
                .frame(width: 6, height: 6)
                .opacity(day.isWalked ? 1 : 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

/// The accessibility-size list (DS3): each walked day as date over counts,
/// the stacked `YourBlocksRow` idiom, one button per day.
private struct WalkDayList: View {
    let days: [WalkCalendarDay]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(days) { day in
                NavigationLink(value: day.key) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppCopy.walkDayDate(day.key).text)
                            .font(.body)
                            .fontWeight(day.isToday ? .bold : .regular)
                            .foregroundStyle(.primary)
                        if let summary = day.summary {
                            Text(Self.counts(summary))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(Color.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.accessibilityLabel)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("yourWalks.day.\(day.key.value)")
            }
        }
    }

    /// "14 blocks, 9 new · 1.4 miles".
    static func counts(_ summary: WalkedDaySummary) -> String {
        var blocks = AppCopy.walkDayBlocks(summary.walkedIDs.count).text
        if summary.newCount > 0 { blocks += ", " + AppCopy.walkDayNew(summary.newCount).text }
        return blocks + AppCopy.walksSeparator + AppCopy.walkDayDistance(meters: summary.meters).text
    }
}
