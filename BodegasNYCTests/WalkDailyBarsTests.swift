//
//  WalkDailyBarsTests.swift
//  BodegasNYCTests
//
//  Your Walks' Progress bars (#188): the per-day arrays on `WalkProgress`,
//  the bucketing in `WalkDailyBars` (units, week start, month and year
//  boundaries, clipping, sums), the y-domain, the shared x-domain, the scrub
//  and VoiceOver lookups, the inset rule, the build time, and the bars'
//  copy. No views.
//

import Foundation
import Testing

@testable import BodegasNYC

@Suite
@MainActor
struct WalkDailyBarsTests {
    private typealias Bars = WalkDailyBars

    /// A Tuesday.
    private static let today = WalkedDayKey(value: 20261117)

    /// A history from (days back, blocks walked, new blocks) rows, built
    /// directly: `cumulative` is the running sum of the new counts, as
    /// `WalkedHistory.build` makes it, and each day walks block ids
    /// 0 ..< walked (a block counts once a day).
    private static func history(_ rows: [(back: Int, walked: Int, new: Int)], today: WalkedDayKey = today) -> WalkedHistory {
        var running = 0
        var days: [WalkedDaySummary] = []
        var cumulative: [WalkedHistory.CumulativePoint] = []
        for row in rows.sorted(by: { $0.back > $1.back }) {
            let key = today.advanced(by: -row.back)
            running += row.new
            days.append(WalkedDaySummary(day: key, walkedIDs: Set(0 ..< UInt32(row.walked)), newCount: row.new, meters: 100))
            cumulative.append(WalkedHistory.CumulativePoint(day: key, count: running))
        }
        return WalkedHistory(days: days, cumulative: cumulative, estimatedThroughDay: nil, version: 1)
    }

    /// Repeats on most days, walked-before-only days, a distance-only day
    /// (no block, 6 back), and a first walk 400 days back so All is monthly.
    private static let repeatHistory = history([
        (400, 6, 6), (200, 9, 4), (120, 3, 0), (89, 12, 7), (60, 5, 5), (31, 8, 2),
        (29, 14, 9), (10, 4, 0), (7, 2, 2), (6, 0, 0), (3, 19, 12), (1, 7, 0), (0, 5, 5)
    ])

    private static func progress(_ history: WalkedHistory = repeatHistory, firstWeekday: Int = 1) -> WalkProgress {
        WalkProgress(history: history, citywideWalked: nil, today: today, firstWeekday: firstWeekday)
    }

    /// `days` days from `start` (yyyymmdd), each walking `walked` blocks.
    private static func bars(from start: Int, days: Int, firstWeekday: Int = 1, walked: Int = 1) -> Bars {
        Bars(
            start: WalkedDayKey(value: start),
            walked: Array(repeating: walked, count: days),
            new: Array(repeating: 0, count: days),
            firstWeekday: firstWeekday
        )
    }

    private static func span(_ bar: Bars.Bar, _ bars: Bars) -> [Int] {
        [bars.day(at: bar.startIndex).value, bars.day(at: bar.endIndex).value]
    }

    // MARK: Per-day arrays (spec item 1)

    /// protects: `walked` and `new` run parallel to `counts`, carrying each
    /// day's `walkedIDs.count` and `newCount`, zero on a day without a row
    /// or with distance only, and a row dated after today extends all
    /// three; a slice carries the same days.
    /// fails_when: a day's count lands on the wrong index, a gap day is not
    /// zero, or the arrays and `counts` differ in length.
    /// no_claim: how `WalkedHistory` derives the counts (YourWalksTests).
    @Test func perDayArraysAreZeroFilledBesideTheLine() {
        let progress = Self.progress()
        #expect(progress.walked.count == progress.counts.count && progress.new.count == progress.counts.count)
        #expect(progress.walked.suffix(4) == [19, 0, 7, 5])
        #expect(progress.new.suffix(4) == [12, 0, 0, 5])
        let week = progress.slice(.week)
        #expect(week.walked == [0, 0, 0, 19, 0, 7, 5])
        #expect(week.new == [0, 0, 0, 12, 0, 0, 5])
        #expect(week.bars.walkedDayCount == 3, "the distance-only day is not a walked day")

        let late = WalkProgress(history: Self.history([(-1, 3, 1)]), citywideWalked: nil, today: Self.today)
        #expect(late.today == Self.today.advanced(by: 1), "a row after today extends the series")
        #expect(late.walked.last == 3 && late.new.last == 1)
        #expect(late.walked.count == late.counts.count)
    }

    // MARK: Units and buckets (spec items 2 to 5, DS3)

    /// protects: the unit follows the slice's day count: daily to 31 days,
    /// weekly to 124, monthly to 1,095 (DS3), yearly beyond; 1W and 1M are
    /// daily, 3M weekly, 1Y monthly.
    /// fails_when: a boundary is off by one, or a range name, not its day
    /// count, picks the unit.
    /// no_claim: none beyond protects.
    @Test func unitFollowsTheDayCount() {
        let expected: [(Int, Bars.Unit)] = [(1, .day), (31, .day), (32, .week), (124, .week), (125, .month), (1_095, .month), (1_096, .year)]
        for (days, unit) in expected {
            #expect(Bars.Unit.forDayCount(days) == unit, "\(days) days")
            #expect(Self.bars(from: 20200101, days: days).unit == unit, "\(days) days")
        }
        let progress = Self.progress()
        #expect(WalkProgressRange.allCases.map { progress.slice($0).bars.unit } == [.day, .day, .week, .month, .month])
        let daily = progress.slice(.month).bars
        #expect(daily.buckets.count == 30 && daily.buckets.allSatisfy { $0.spanDays == 1 })
        #expect(daily.bars.map(\.total) == [14, 4, 2, 19, 7, 5], "one bar per walked day, none for the rest")
        #expect(daily.bars.first.map { [$0.total, $0.new, $0.repeated] } == [14, 9, 5])
    }

    /// protects: eng E5: a week starts on the Calendar's first weekday,
    /// Sunday (1) or Monday (2), from day-number arithmetic; the first and
    /// last weeks are clipped to the range (AC 4: a 90-day slice starting
    /// on a Thursday has a first bar at index 0 under 7 days long).
    /// fails_when: a week starts on another day, the weekday arithmetic is
    /// off, or a clipped week is padded to 7 days.
    /// no_claim: the phone's locale; the default comes from
    /// `YourWalksContent.layoutCalendar`.
    @Test func weeksStartOnTheCalendarsFirstWeekday() {
        #expect(Bars.weekday(dayNumber: 0) == 5, "1970-01-01 was a Thursday")
        #expect(Bars.weekday(dayNumber: Self.today.dayNumber) == 3, "Nov 17, 2026 is a Tuesday")
        #expect(Bars.weekday(dayNumber: -1) == 4)

        let sunday = Self.progress(firstWeekday: 1).slice(.threeMonths).bars
        #expect(sunday.start == WalkedDayKey(value: 20260820), "a Thursday")
        #expect(sunday.buckets.count == 14)
        #expect(Self.span(sunday.buckets[0], sunday) == [20260820, 20260822])
        #expect(sunday.buckets[0].startIndex == 0 && sunday.buckets[0].spanDays == 3)
        #expect(Self.span(sunday.buckets[1], sunday) == [20260823, 20260829])
        #expect(Self.span(sunday.buckets[13], sunday) == [20261115, 20261117])
        #expect(sunday.buckets.dropFirst().dropLast().allSatisfy { $0.spanDays == 7 })

        let monday = Self.progress(firstWeekday: 2).slice(.threeMonths).bars
        #expect(Self.span(monday.buckets[0], monday) == [20260820, 20260823])
        #expect(Self.span(monday.buckets[1], monday) == [20260824, 20260830])
        #expect(Self.span(monday.buckets.last!, monday) == [20261116, 20261117])
        // Sunday Nov 15 opens today's week on a Sunday start, and closes
        // Nov 9 – 15 on a Monday start.
        #expect(Self.span(sunday.bar(containing: 87), sunday) == [20261115, 20261117])
        #expect(Self.span(monday.bar(containing: 87), monday) == [20261109, 20261115])
        #expect(sunday.buckets.last.map { [$0.total, $0.new] } == [12, 5])
    }

    /// protects: months and years are civil: a month bucket starts on the
    /// 1st (a leap February is 29 days), a year bucket on January 1, and
    /// both are clipped at the range's ends.
    /// fails_when: a month runs 30 days, a leap day is lost, or a year
    /// starts on the range's first day.
    /// no_claim: none beyond protects.
    @Test func monthsAndYearsAreCivil() {
        let months = Self.bars(from: 20240115, days: 200)
        #expect(months.unit == .month)
        #expect(Self.span(months.buckets[0], months) == [20240115, 20240131])
        #expect(Self.span(months.buckets[1], months) == [20240201, 20240229], "a leap February")
        #expect(months.buckets[1].spanDays == 29)
        #expect(Self.span(months.buckets[6], months) == [20240701, 20240731])
        #expect(Self.span(months.buckets.last!, months) == [20240801, 20240801], "today, Aug 1, is its own bucket")
        #expect(months.isWholePeriod(months.buckets[1]) && months.isWholePeriod(months.buckets[6]))
        #expect(!months.isWholePeriod(months.buckets[0]) && !months.isWholePeriod(months.buckets.last!))

        let years = Self.bars(from: 20230601, days: 1_200)
        #expect(years.unit == .year)
        #expect(years.buckets.map { Self.span($0, years) } == [
            [20230601, 20231231], [20240101, 20241231], [20250101, 20251231], [20260101, 20260912]
        ])
        #expect(years.buckets[1].spanDays == 366)
        #expect(years.buckets.map(years.isWholePeriod) == [false, true, true, false])
    }

    /// protects: AC 5: for all five ranges the bars' new counts sum to the
    /// slice's gain and their totals to the days' walked counts, with
    /// repeats on most days; zero buckets are kept and not drawn.
    /// fails_when: a day is dropped or counted twice at a bucket edge, or
    /// the new part drifts from the line's gain.
    /// no_claim: that grouped sums are what a reader expects (DS6's
    /// footnote states it).
    @Test func barsAddUpToTheLineAndTheDays() {
        for firstWeekday in [1, 2] {
            let progress = Self.progress(firstWeekday: firstWeekday)
            for range in WalkProgressRange.allCases {
                let slice = progress.slice(range)
                let bars = slice.bars
                #expect(bars.bars.reduce(0) { $0 + $1.new } == slice.gain, "\(range)")
                #expect(bars.bars.reduce(0) { $0 + $1.total } == slice.walked.reduce(0, +), "\(range)")
                #expect(bars.buckets.reduce(0) { $0 + $1.spanDays } == slice.dayCount, "\(range): every day in one bucket")
                #expect(bars.bars.allSatisfy { $0.total > 0 && $0.repeated >= 0 }, "\(range)")
                #expect(bars.buckets.filter { $0.total > 0 } == bars.bars, "\(range)")
            }
        }
        let all = Self.progress().slice(.all)
        #expect(all.dayCount == 401 && all.bars.unit == .month)
        #expect(all.gain == 52)
    }

    // MARK: Domains (spec item 6, DS4)

    /// protects: the y-axis runs from zero to the largest bar's total, its
    /// top a labelled tick; a range with no counted block has 0 ... 1, no
    /// bars and its empty line (E10), All excepted; both charts share
    /// `xDomain`, half a day past each end, -1 ... 1 for one day.
    /// fails_when: the domain starts above zero, a no-walk range has an
    /// empty domain or a bar, or the line's domain is the old 0 ... last.
    /// no_claim: Swift Charts' rendering of either domain (captures).
    @Test func domainsAndTheEmptyRange() {
        let week = Self.progress().slice(.week)
        #expect(week.bars.yDomain == 0 ... 19)
        #expect(week.bars.yTicks.last == 19 && week.bars.yTicks.first == 0)
        #expect(week.xDomain == -0.5 ... 6.5)

        let old = Self.progress(Self.history([(200, 3, 3)]))
        for range in [WalkProgressRange.week, .month, .threeMonths] {
            let slice = old.slice(range)
            #expect(slice.bars.yDomain == 0 ... 1 && slice.bars.bars.isEmpty, "\(range)")
            #expect(slice.bars.yTicks == [0, 1])
        }
        #expect(AppCopy.walkBarsEmptyLine(old.slice(.week))?.text == "No blocks counted in the past week.")
        #expect(AppCopy.walkBarsEmptyLine(old.slice(.month))?.text == "No blocks counted in the past month.")
        #expect(AppCopy.walkBarsEmptyLine(old.slice(.threeMonths))?.text == "No blocks counted in the past 3 months.")
        #expect(AppCopy.walkBarsEmptyLine(old.slice(.year)) == nil, "the year has the walk")
        #expect(AppCopy.walkBarsEmptyLine(old.slice(.all)) == nil)

        let none = Self.progress(Self.history([(40, 0, 0)]))
        #expect(AppCopy.walkBarsEmptyLine(none.slice(.year))?.text == "No blocks counted in the past year.")
        #expect(AppCopy.walkBarsEmptyLine(none.slice(.all)) == nil, "All's empty state is the sheet's line")
        #expect(none.slice(.all).bars.bars.isEmpty)

        let single = Self.progress(Self.history([(0, 2, 2)])).slice(.all)
        #expect(single.isSingleDay && single.xDomain == -1 ... 1)
        #expect(single.bars.buckets.count == 1 && single.bars.bars.count == 1)
    }

    // MARK: Scrub and VoiceOver (eng E2, E3, DS17)

    /// protects: eng E2: the bars map a continuous x to the nearest day
    /// themselves, clamped to the range; a lifted finger (nil) is nil.
    /// fails_when: x truncates instead of rounding, a half-day edge goes
    /// to the wrong side, an x past the plot leaves the range, or a huge
    /// finite x traps converting to Int.
    /// no_claim: what Swift Charts hands the binding (simulator probe).
    @Test func continuousXRoundsToADay() {
        let bars = Self.progress().slice(.week).bars
        #expect(bars.dayIndex(forX: nil) == nil)
        #expect(bars.dayIndex(forX: 2.49) == 2)
        #expect(bars.dayIndex(forX: 2.5) == 3, "a half-day edge belongs to the later day")
        #expect(bars.dayIndex(forX: 2.51) == 3)
        #expect(bars.dayIndex(forX: -0.49) == 0)
        #expect(bars.dayIndex(forX: -3) == 0)
        #expect(bars.dayIndex(forX: 6.5) == 6)
        #expect(bars.dayIndex(forX: 40) == 6)
        #expect(bars.dayIndex(forX: .nan) == nil)
        #expect(bars.dayIndex(forX: .infinity) == nil)
        #expect(bars.dayIndex(forX: 1e300) == 6, "a huge finite x clamps, never traps")
        #expect(bars.dayIndex(forX: -1e300) == 0)
        #expect(bars.dayIndex(forX: Double.greatestFiniteMagnitude) == 6)
    }

    /// protects: eng E3 and spec item 7: `bar(containing:)` finds the
    /// bucket of any day, a bucket without a walk as a zero bar with its
    /// clipped span, and clamps an index outside the range; the readout
    /// (DS8) names that bucket's dates.
    /// fails_when: a day in a no-walk week reads another week, a day
    /// outside the range crashes or reads nothing.
    /// no_claim: Swift Charts' gesture (live QA).
    @Test func barContainingADay() {
        let bars = Self.progress().slice(.threeMonths).bars
        let walked = bars.bar(containing: 84)
        #expect(Self.span(walked, bars) == [20261108, 20261114])
        #expect(walked.total == 21 && walked.new == 14, "7, 6 and 3 days back")
        let quiet = bars.bar(containing: 40)
        #expect(quiet.total == 0 && quiet.spanDays == 7)
        #expect(AppCopy.walkBarReadout(quiet, in: bars) == ["0 blocks", "Sep 27 \u{2013} Oct 3"])
        #expect(bars.bar(containing: -9) == bars.buckets[0])
        #expect(bars.bar(containing: 500) == bars.buckets.last)
        #expect(AppCopy.walkBarReadout(bars.bar(containing: 0), in: bars) == ["12 blocks, 7 new", "Aug 20 \u{2013} 22"])
    }

    /// protects: DS17: VoiceOver steps through every bucket, zeros
    /// included, from the latest, stopping at both ends.
    /// fails_when: a step skips a zero bucket, wraps, or runs past an end.
    /// no_claim: VoiceOver's gesture (device pass).
    @Test func voiceOverStepsEveryBucket() {
        let bars = Self.progress().slice(.threeMonths).bars
        let last = bars.buckets.count - 1
        #expect(bars.stepped(from: nil, by: 1) == last)
        #expect(bars.stepped(from: nil, by: -1) == last)
        #expect(bars.stepped(from: last, by: 1) == last)
        #expect(bars.stepped(from: last, by: -1) == last - 1)
        #expect(bars.stepped(from: 0, by: -1) == 0)
        #expect(bars.buckets.contains { $0.total == 0 }, "the walk through reaches zero buckets")
        #expect(bars.position(containing: 3) == 1)
    }

    /// protects: Clear History with the sheet open: the slice shrinks to
    /// one empty day while a day is still selected; every lookup clamps
    /// and nothing is drawn.
    /// fails_when: a stale index past the one day crashes or reads a bar.
    /// no_claim: the view model's clearing (YourWalksTests).
    @Test func clearedHistoryIsOneEmptyDay() {
        let all = WalkProgress(history: .empty, citywideWalked: nil, today: Self.today).slice(.all)
        let bars = all.bars
        #expect(bars.dayCount == 1 && bars.bars.isEmpty && bars.buckets.count == 1)
        #expect(bars.bar(containing: 29).total == 0)
        #expect(bars.dayIndex(forX: 29) == 0)
        #expect(bars.stepped(from: 12, by: 1) == 0)
        #expect(AppCopy.walkBarsRestValue(all).text == "No blocks counted yet.")
        #expect(WalkProgress(history: .empty, citywideWalked: nil, today: Self.today).slice(.week).bars.buckets.count == 7)
    }

    // MARK: Insets (spec item 9, DS10)

    /// protects: a bar's inset per side: a tenth of its unit, at least half
    /// a point on a 300 pt plot, at most a quarter of its own span, so a
    /// clipped one-day bar keeps half its width; and never wider than 36 pt
    /// (DS10), which outranks the quarter cap (a 1-day and a 3-day slice);
    /// a 1W bar is about 34 pt; neighbours keep at least 1 pt apart.
    /// fails_when: a short history draws a full-width slab, a clipped bar
    /// vanishes, or bars touch.
    /// no_claim: the drawn widths on screen (captures), which follow the
    /// plot's real width, not 300 pt.
    @Test func insetsKeepBarsApartAndNarrow() {
        func width(_ bar: Bars.Bar, _ bars: Bars) -> Double {
            let extent = bars.xExtent(of: bar)
            return (extent.upperBound - extent.lowerBound) * 300 / bars.domainDays
        }
        let week = Self.progress().slice(.week).bars
        #expect(abs(week.inset(for: week.bars[0]) - 0.1) < 1e-9)
        #expect(abs(width(week.bars[0], week) - 34.29) < 0.01)

        let one = Self.bars(from: 20261117, days: 1)
        #expect(abs(width(one.buckets[0], one) - 36) < 1e-9, "one day spans -1 ... 1, capped at 36 pt")
        let three = Self.bars(from: 20261115, days: 3)
        #expect(three.buckets.allSatisfy { abs(width($0, three) - 36) < 1e-9 })

        let quarter = Self.progress().slice(.threeMonths).bars
        let lastWeek = quarter.buckets.last!
        #expect(abs(quarter.inset(for: lastWeek) - 0.7) < 1e-9, "a tenth of a week")
        // Tuesday Aug 25 to Sunday Nov 22: today's week is one day.
        let clipped = Self.bars(from: 20260825, days: 90)
        let oneDay = clipped.buckets.last!
        #expect(oneDay.spanDays == 1 && abs(clipped.inset(for: oneDay) - 0.25) < 1e-9, "a quarter of its one day")

        for bars in [week, quarter, clipped, Self.progress().slice(.year).bars, Self.bars(from: 20160101, days: 3_660)] {
            for bar in bars.buckets { #expect(width(bar, bars) <= 36 + 1e-9, "\(bars.unit) at \(bar.startIndex)") }
            for (left, right) in zip(bars.buckets, bars.buckets.dropFirst()) {
                let gap = (bars.xExtent(of: right).lowerBound - bars.xExtent(of: left).upperBound) * 300 / bars.domainDays
                #expect(gap >= 1 - 1e-9, "\(bars.unit) at \(right.startIndex)")
            }
        }
    }

    // MARK: Build time (eng E9)

    /// protects: eng E9: building `WalkProgress` and its All slice, bars
    /// included, from 3,660 days with a walk every day stays under 100 ms,
    /// with day arithmetic and no `Calendar` call per day.
    /// fails_when: bucketing goes quadratic or calls `Calendar` per day.
    /// no_claim: a Release build or a device (this is the Debug test run on
    /// the simulator); the history's own build (YourWalksTests).
    @Test func tenYearsBuildFast() {
        let rows = (0 ..< 3_660).map { (back: $0, walked: 9, new: $0 % 3) }
        let history = Self.history(rows)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let progress = WalkProgress(history: history, citywideWalked: nil, today: Self.today)
            let all = progress.slice(.all)
            #expect(all.bars.unit == .year && all.bars.buckets.count == 11)
        }
        #expect(elapsed < .milliseconds(100), "took \(elapsed)")
    }
}
