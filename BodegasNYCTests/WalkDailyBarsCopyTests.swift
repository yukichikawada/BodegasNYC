//
//  WalkDailyBarsCopyTests.swift
//  BodegasNYCTests
//
//  The Progress bars' copy (#188): headings, legend, footnote, the scrub
//  readout's counts and dates (eng E11, DS8), the empty-range lines (E10),
//  and the VoiceOver label, rest value (DS7) and stepping values (DS18).
//  The voice rules run over the same templates in `AppCopyVoiceTests`.
//

import Foundation
import Testing

@testable import BodegasNYC

@Suite
@MainActor
struct WalkDailyBarsCopyTests {
    private typealias Bars = WalkDailyBars

    /// A Tuesday.
    private static let today = WalkedDayKey(value: 20261117)

    /// (days back, blocks walked, new blocks), as `WalkDailyBarsTests`.
    private static func progress(_ rows: [(back: Int, walked: Int, new: Int)]) -> WalkProgress {
        var running = 0
        var days: [WalkedDaySummary] = []
        var cumulative: [WalkedHistory.CumulativePoint] = []
        for row in rows.sorted(by: { $0.back > $1.back }) {
            let key = today.advanced(by: -row.back)
            running += row.new
            days.append(WalkedDaySummary(day: key, walkedIDs: Set(0 ..< UInt32(row.walked)), newCount: row.new, meters: 100))
            cumulative.append(WalkedHistory.CumulativePoint(day: key, count: running))
        }
        let history = WalkedHistory(days: days, cumulative: cumulative, estimatedThroughDay: nil, version: 1)
        return WalkProgress(history: history, citywideWalked: nil, today: today, firstWeekday: 1)
    }

    private static let repeats = progress([
        (400, 6, 6), (200, 9, 4), (120, 3, 0), (89, 12, 7), (60, 5, 5), (31, 8, 2),
        (29, 14, 9), (10, 4, 0), (7, 2, 2), (6, 0, 0), (3, 19, 12), (1, 7, 0), (0, 5, 5)
    ])

    /// One block every day from `start` (yyyymmdd), Sunday weeks.
    private static func daily(from start: Int, days: Int) -> Bars {
        Bars(start: WalkedDayKey(value: start), walked: Array(repeating: 1, count: days), new: Array(repeating: 0, count: days), firstWeekday: 1)
    }

    private static func readout(_ bars: Bars, at index: Int) -> String {
        AppCopy.walkBarReadout(bars.bar(containing: index), in: bars).joined(separator: AppCopy.walksSeparator)
    }

    private static func spoken(_ bars: Bars, at index: Int) -> String {
        AppCopy.walkBarSpokenValue(bars.bar(containing: index), in: bars).text
    }

    /// protects: DS9's headings in Title Case with "per", DS18's VoiceOver
    /// label, DS19's legend and DS6's footnote, with their kinds.
    /// fails_when: a string drifts from the design table or a kind changes.
    /// no_claim: where each is shown (captures; the view's code).
    @Test func headingsLegendAndFootnoteMatchTheDesignTable() {
        let units: [Bars.Unit] = [.day, .week, .month, .year]
        #expect(units.map { AppCopy.walkBarsHeading($0).text } == ["Blocks per Day", "Blocks per Week", "Blocks per Month", "Blocks per Year"])
        #expect(units.allSatisfy { AppCopy.walkBarsHeading($0).kind == .label })
        #expect(units.map { AppCopy.walkBarsChartLabel($0).text } == [
            "Bar chart of blocks per day.", "Bar chart of blocks per week.",
            "Bar chart of blocks per month.", "Bar chart of blocks per year."
        ])
        typealias Walks = AppCopy.YourWalks
        #expect(Walks.barsLegendNew.copy == CopyString(kind: .label, text: "New"))
        #expect(Walks.barsLegendWalkedBefore.copy == CopyString(kind: .label, text: "Walked Before"))
        #expect(Walks.barsFootnote.copy == CopyString(kind: .body, text: "Each bar adds up its days."))
    }

    /// protects: DS8's readout per unit: a day "19 blocks, 12 new · Nov
    /// 14"; "new" left out at zero ("7 blocks"); a day without a walk "0
    /// blocks"; a week "21 blocks, 14 new · Nov 8 – 14"; a whole month "May
    /// 2026"; a clipped month its dates (E11, "Nov 1 – 17"); a whole year
    /// "2024".
    /// fails_when: a unit reads another's shape, zero reads "0 new", or a
    /// clipped month reads its name.
    /// no_claim: the line's layout at a fixed height (captures).
    @Test func scrubReadoutPerUnit() {
        let week = Self.repeats.slice(.week).bars
        #expect(Self.readout(week, at: 3) == "19 blocks, 12 new \u{00B7} Nov 14")
        #expect(Self.readout(week, at: 5) == "7 blocks \u{00B7} Nov 16")
        #expect(Self.readout(week, at: 4) == "0 blocks \u{00B7} Nov 15")
        let quarter = Self.repeats.slice(.threeMonths).bars
        #expect(Self.readout(quarter, at: 84) == "21 blocks, 14 new \u{00B7} Nov 8 \u{2013} 14")
        #expect(Self.readout(quarter, at: 12) == "0 blocks \u{00B7} Aug 30 \u{2013} Sep 5", "across months")
        let year = Self.repeats.slice(.year).bars
        #expect(year.buckets.count == 13)
        #expect(Self.readout(year, at: 0) == "0 blocks \u{00B7} Nov 18 \u{2013} 30, 2025", "clipped, last year")
        #expect(Self.readout(year, at: 20) == "0 blocks \u{00B7} Dec 2025")
        #expect(AppCopy.walkBarReadout(year.buckets[6], in: year) == ["9 blocks, 4 new", "May 2026"])
        #expect(AppCopy.walkBarReadout(year.buckets[11], in: year) == ["22 blocks, 11 new", "Oct 2026"])
        #expect(AppCopy.walkBarReadout(year.buckets[12], in: year) == ["37 blocks, 19 new", "Nov 1 \u{2013} 17"])
        let years = Self.daily(from: 20230601, days: 1_200)
        #expect(AppCopy.walkBarReadout(years.buckets[0], in: years) == ["214 blocks", "Jun 1 \u{2013} Dec 31, 2023"])
        #expect(AppCopy.walkBarReadout(years.buckets[1], in: years) == ["366 blocks", "2024"])
        #expect(AppCopy.walkBarReadout(years.buckets[3], in: years) == ["255 blocks", "Jan 1 \u{2013} Sep 12"])
        #expect(AppCopy.walkBarCounts(total: 1_204, new: 1).text == "1,204 blocks, 1 new")
        #expect(AppCopy.walkBarCounts(total: 1, new: 0).text == "1 block")
    }

    /// protects: eng E11's span rules across a year end: both ends carry
    /// their years when they differ, a span outside today's year carries it
    /// once, today's year is left out, and a day outside today's year
    /// carries it; the longest readout reserves that span (DS13).
    /// fails_when: a year is dropped or repeated, or the reserve is shorter
    /// than a readout the slice can show.
    /// no_claim: the reserve's rendered width (AX5 capture).
    @Test func spansAcrossAYearEnd() {
        let bars = Self.daily(from: 20261201, days: 40)
        #expect(bars.unit == .week)
        #expect(AppCopy.walkBarDates(bars.buckets[0], in: bars).text == "Dec 1 \u{2013} 5, 2026")
        #expect(AppCopy.walkBarDates(bars.buckets[4], in: bars).text == "Dec 27, 2026 \u{2013} Jan 2, 2027")
        #expect(AppCopy.walkBarDates(bars.buckets[5], in: bars).text == "Jan 3 \u{2013} 9")
        #expect(AppCopy.walkBarReserve(bars) == ["7 blocks", "Dec 27, 2026 \u{2013} Jan 2, 2027"])
        let days = Self.daily(from: 20261220, days: 20)
        #expect(Self.readout(days, at: 11) == "1 block \u{00B7} Dec 31, 2026")
        #expect(Self.readout(days, at: 19) == "1 block \u{00B7} Jan 8")
    }

    /// protects: DS18's stepping values: a day as the Calendar reads it, a
    /// week, a whole and a clipped month, a whole year, a span across
    /// months and years, spoken with "to", zero read as "0 blocks".
    /// fails_when: a dash is spoken, a span loses a year, or zero is read
    /// as "0 blocks, 0 new".
    /// no_claim: VoiceOver's own reading (device pass).
    @Test func voiceOverSteppingValues() {
        let week = Self.repeats.slice(.week).bars
        #expect(Self.spoken(week, at: 3) == "Saturday, November 14, 19 blocks, 12 new.")
        #expect(Self.spoken(week, at: 4) == "Sunday, November 15, 0 blocks.")
        let quarter = Self.repeats.slice(.threeMonths).bars
        #expect(Self.spoken(quarter, at: 84) == "November 8 to 14, 21 blocks, 14 new.")
        #expect(Self.spoken(quarter, at: 12) == "August 30 to September 5, 0 blocks.")
        let year = Self.repeats.slice(.year).bars
        #expect(AppCopy.walkBarSpokenValue(year.buckets[6], in: year).text == "May 2026, 9 blocks, 4 new.")
        #expect(AppCopy.walkBarSpokenValue(year.buckets[12], in: year).text == "November 1 to 17, 37 blocks, 19 new.")
        #expect(AppCopy.walkBarSpokenValue(year.buckets[0], in: year).text == "November 18 to 30, 2025, 0 blocks.")
        let years = Self.daily(from: 20230601, days: 1_200)
        #expect(AppCopy.walkBarSpokenValue(years.buckets[1], in: years).text == "2024, 366 blocks.")
        let cross = Self.daily(from: 20261201, days: 40)
        #expect(AppCopy.walkBarSpokenValue(cross.buckets[4], in: cross).text == "December 27, 2026 to January 2, 2027, 7 blocks.")
        let days = Self.daily(from: 20261220, days: 20)
        #expect(Self.spoken(days, at: 11) == "Thursday, December 31, 1 block.")
    }

    /// protects: DS7's rest value: the walked days (at least one block) of
    /// the range, "Blocks counted on 6 days in the past month.", one day
    /// singular, All "since" its first month; an empty range reads its E10
    /// line; and the UI fixture's shape gives the UI test's strings (3
    /// days in the month, 5 in the year, 2 in the week).
    /// fails_when: a calendar day or a distance-only day is counted, or the
    /// rest value quotes a block total.
    /// no_claim: the app's launch-time seeding (the UI test runs it).
    @Test func restValuesCountWalkedDays() {
        #expect(AppCopy.walkBarsRestValue(Self.repeats.slice(.month)).text == "Blocks counted on 6 days in the past month.")
        #expect(AppCopy.walkBarsRestValue(Self.repeats.slice(.week)).text == "Blocks counted on 3 days in the past week.")
        #expect(AppCopy.walkBarsRestValue(Self.repeats.slice(.all)).text == "Blocks counted on 12 days since Oct 2025.")
        let one = Self.progress([(2, 1, 1)])
        #expect(AppCopy.walkBarsRestValue(one.slice(.week)).text == "Blocks counted on 1 day in the past week.")
        let old = Self.progress([(200, 3, 3)])
        #expect(AppCopy.walkBarsRestValue(old.slice(.threeMonths)).text == "No blocks counted in the past 3 months.")

        // `-UITestWalkedDays`: one block 100, 35, 9 and 1 days back, two
        // (one new) 3 days back (YourWalksTests.uiFixtureWalksFiveDays).
        let fixture = Self.progress([(100, 1, 1), (35, 1, 1), (9, 1, 1), (3, 2, 1), (1, 1, 1)])
        #expect(AppCopy.walkBarsRestValue(fixture.slice(.month)).text == "Blocks counted on 3 days in the past month.")
        #expect(AppCopy.walkBarsRestValue(fixture.slice(.year)).text == "Blocks counted on 5 days in the past year.")
        #expect(AppCopy.walkBarsRestValue(fixture.slice(.week)).text == "Blocks counted on 2 days in the past week.")
    }
}
