//
//  WalkProgressTests.swift
//  BodegasNYCTests
//
//  Your Walks' Progress chart (#170 PR 2, design DS6): the pure model
//  (`WalkProgress`, `WalkProgressSlice`): gap filling, each range's slice,
//  gain and second line, the y-domain, the single datum, the scrub lookup,
//  the VoiceOver step, the axis ticks, and how the headline reconciles with
//  the line. No views.
//

import CoreLocation
import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

@Suite
@MainActor
struct WalkProgressTests {
    private typealias F = StreetFixtures

    /// Blocks 100, 200, 201, 300 and 400 exist.
    private static let grid = F.cornerGrid()
    private static let today = WalkedDayKey(value: 20261117)

    private static func day(_ offset: Int) -> WalkedDayKey { today.advanced(by: -offset) }

    private static func history(_ masks: [WalkedDayKey: [UInt32: UInt16]], meters: [WalkedDayKey: Double] = [:]) -> WalkedHistory {
        WalkedHistory.build(dayMasks: masks, dayMeters: meters, grid: grid, estimatedThroughDay: nil, version: 1)
    }

    /// The UI fixture's shape: one new block 100, 35, 9 and 1 days back,
    /// and 3 days back a repeat of the 9-days-back block plus a new one.
    private static let fixtureHistory = history([
        day(100): [100: 0x3FF],
        day(35): [200: 0x3FF],
        day(9): [201: 0x3FF],
        day(3): [201: 0x3FF, 300: 0x3FF],
        day(1): [400: 0x3FF]
    ])

    private static func progress(_ history: WalkedHistory = fixtureHistory, citywide: Int? = 5) -> WalkProgress {
        WalkProgress(history: history, citywideWalked: citywide, today: today)
    }

    // MARK: Days and gap filling

    /// protects: the arithmetic day numbers agree with `advanced(by:)` (the
    /// `Calendar` path) across month and year ends, a leap day and both
    /// daylight-saving changes, and round-trip.
    /// fails_when: a filled series puts a count on the wrong date.
    /// no_claim: the 4 am rule (WalkedDayKeyTests; keys already carry it).
    @Test func dayNumbersMatchTheCalendar() {
        for value in [20240228, 20240229, 20241231, 20260308, 20261101, 20261117, 19700101] {
            let key = WalkedDayKey(value: value)
            #expect(WalkedDayKey(dayNumber: key.dayNumber) == key)
            for step in [-400, -31, -1, 1, 2, 29, 365] {
                #expect(key.advancedNumerically(by: step) == key.advanced(by: step), "\(key) by \(step)")
            }
        }
        #expect(WalkedDayKey(value: 19700101).dayNumber == 0)
    }

    /// protects: `cumulative` has a point only per day with a row; the
    /// chart fills every other day flat with the last count, zero before
    /// the first.
    /// fails_when: a gap day drops to zero, takes the next day's count, or
    /// the series is the wrong length.
    /// no_claim: how cumulative counts are built (YourWalksTests).
    @Test func gapsFillFlat() {
        let points = [
            WalkedHistory.CumulativePoint(day: WalkedDayKey(value: 20261102), count: 1),
            WalkedHistory.CumulativePoint(day: WalkedDayKey(value: 20261104), count: 3)
        ]
        let start = WalkedDayKey(value: 20261101).dayNumber
        #expect(WalkProgress.filled(points, from: start, through: start + 5) == [0, 1, 1, 3, 3, 3])
        #expect(WalkProgress.filled([], from: start, through: start + 2) == [0, 0, 0])
        #expect(WalkProgress.filled(points, from: start, through: start - 1).isEmpty)

        let progress = Self.progress()
        #expect(progress.today == Self.today)
        #expect(progress.first == Self.day(364), "a year back, the longest fixed range")
        #expect(progress.counts.count == 365)
        #expect(progress.count(on: Self.day(101)) == 0)
        #expect(progress.count(on: Self.day(100)) == 1)
        #expect(progress.count(on: Self.day(50)) == 1)
        #expect(progress.count(on: Self.day(4)) == 3)
        #expect(progress.count(on: Self.day(3)) == 4)
        #expect(progress.count(on: Self.today) == 5)
    }

    // MARK: Ranges (DS6)

    /// protects: each range's domain ends today and starts 6, 29, 89 or 364
    /// days back, All on the first walked day; the gain is measured from
    /// the count just before the range; the second line names the range,
    /// or "Since" the first walked month for All.
    /// fails_when: a range is a day short or long, the gain includes the
    /// day before the range, or the line names the wrong period.
    /// no_claim: how it looks (simulator captures).
    @Test func eachRangeSlicesAndSummarises() {
        let progress = Self.progress()
        let expected: [(WalkProgressRange, Int, Int, String)] = [
            (.week, 7, 2, "2 new in the past week."),
            (.month, 30, 3, "3 new in the past month."),
            (.threeMonths, 90, 4, "4 new in the past 3 months."),
            (.year, 365, 5, "5 new in the past year."),
            (.all, 101, 5, "Since Aug 2026.")
        ]
        for (range, days, gain, line) in expected {
            let slice = progress.slice(range)
            #expect(slice.dayCount == days, "\(range)")
            #expect(slice.day(at: slice.lastIndex) == Self.today, "\(range)")
            #expect(slice.gain == gain, "\(range)")
            #expect(AppCopy.walkProgressSummary(slice).text == line)
        }
        #expect(progress.slice(.week).start == Self.day(6))
        #expect(progress.slice(.week).countBefore == 3)
        #expect(progress.slice(.all).start == Self.day(100))
        #expect(progress.slice(.all).countBefore == 0)
        #expect(
            AppCopy.walkProgressRestValue(headline: 5, slice: progress.slice(.month)).text
                == "5 blocks, 3 new in the past month."
        )
        #expect(AppCopy.walkProgressRestValue(headline: 5, slice: progress.slice(.all)).text == "5 blocks since Aug 2026.")
        #expect(AppCopy.walkProgressRestValue(headline: 1, slice: progress.slice(.all)).text == "1 block since Aug 2026.")
    }

    /// protects: DS8.8's "1Y range over a week of history": a range longer
    /// than the history still spans the whole range, flat at zero before
    /// the first walk, and its gain is everything walked.
    /// fails_when: the domain shrinks to the history, or the zero days are
    /// left out.
    /// no_claim: the axis labels' fit on screen (captures).
    @Test func aYearOverAWeekOfWalks() {
        let history = Self.history([Self.day(6): [100: 0x3FF], Self.day(2): [200: 0x3FF, 300: 0x3FF]])
        let year = Self.progress(history, citywide: 3).slice(.year)
        #expect(year.dayCount == 365)
        #expect(year.counts.prefix(358).allSatisfy { $0 == 0 })
        #expect(year.counts.suffix(7) == [1, 1, 1, 1, 3, 3, 3])
        #expect(year.gain == 3)
        #expect(year.yDomain == 0 ... 3)
        #expect(AppCopy.walkProgressSummary(year).text == "3 new in the past year.")
        #expect(year.linePoints.map(\.index) == [0, 358, 362, 364], "flat runs collapse to their ends")
        let all = Self.progress(history, citywide: 3).slice(.all)
        #expect(all.dayCount == 7 && all.start == Self.day(6))
    }

    // MARK: Y-domain and the single datum (DS6)

    /// protects: the y-axis runs from the range's minimum to its maximum,
    /// from zero only for All; a flat range gets a one-block margin and
    /// never goes below zero; gridlines are whole blocks.
    /// fails_when: a fixed range starts at zero, All does not, or a flat
    /// range has an empty domain.
    /// no_claim: Swift Charts' rendering of the domain.
    @Test func yDomainRules() {
        let progress = Self.progress()
        #expect(progress.slice(.week).yDomain == 3 ... 5)
        #expect(progress.slice(.month).yDomain == 2 ... 5)
        #expect(progress.slice(.all).yDomain == 0 ... 5)
        #expect(progress.slice(.week).yTicks == [3, 4, 5])
        #expect(progress.slice(.threeMonths).yDomain == 1 ... 5)
        #expect(progress.slice(.threeMonths).yTicks == [1, 2, 3, 4, 5])
        #expect(progress.slice(.year).yTicks == [0, 1, 2, 3, 4, 5])
        #expect(progress.slice(.all).yTicks == [0, 1, 2, 3, 4, 5])

        let old = Self.progress(Self.history([Self.day(200): [100: 0x3FF, 200: 0x3FF]]), citywide: 2)
        #expect(old.slice(.week).counts.allSatisfy { $0 == 2 })
        #expect(old.slice(.week).yDomain == 1 ... 3)
        #expect(old.slice(.week).gain == 0)
        #expect(AppCopy.walkProgressSummary(old.slice(.week)).text == "0 new in the past week.")

        // History with no walked day (DS8.2's grid-without-dots analogue).
        let none = Self.progress(Self.history([Self.day(4): [100: 0b1]], meters: [Self.day(4): 40]), citywide: 0)
        #expect(none.slice(.month).yDomain == 0 ... 1)
        #expect(none.slice(.all).start == Self.day(4), "All starts on the first day with a row")
        #expect(none.headline == 0)

        #expect(old.slice(.week).yTicks == [1, 2, 3])
        #expect(none.slice(.month).yTicks == [0, 1])
    }

    /// protects: the top of the y-domain (the range's maximum, usually the
    /// headline) is always a labelled tick; spans of 5 or less tick every
    /// block; large spans keep whole, uncrowded ticks with no duplicates.
    /// fails_when: the maximum has no gridline, a tick repeats, or one
    /// lands less than a step below the top.
    /// no_claim: Swift Charts' label layout.
    @Test func yTicksAlwaysLabelTheTop() {
        typealias S = WalkProgressSlice
        #expect(S.yTicks(for: 4 ... 4) == [4], "a span of 0")
        #expect(S.yTicks(for: 0 ... 1) == [0, 1])
        #expect(S.yTicks(for: 1 ... 5) == [1, 2, 3, 4, 5])
        #expect(S.yTicks(for: 0 ... 5) == [0, 1, 2, 3, 4, 5])
        #expect(S.yTicks(for: 272 ... 312) == [280, 290, 300, 312], "310 is too close under the top")
        #expect(S.yTicks(for: 0 ... 1_204) == [0, 500, 1_204], "1,000 is too close under the top")
        #expect(S.yTicks(for: 0 ... 7) == [0, 2, 4, 7])
        #expect(S.yTicks(for: 990 ... 1_310) == [1_000, 1_100, 1_200, 1_310])
        for domain in [3 ... 9, 272 ... 312, 0 ... 1_204, 12 ... 13, 990 ... 1_310] {
            let ticks = S.yTicks(for: domain)
            #expect(ticks.last == domain.upperBound)
            #expect(Set(ticks).count == ticks.count)
            #expect(ticks.allSatisfy { domain.contains($0) })
        }
        #expect(WalkProgressSlice.niceStep(400) == 500)
        #expect(WalkProgressSlice.niceStep(0.3) == 1)
        #expect(WalkProgressSlice.niceStep(20) == 20)
    }

    /// protects: DS6's single datum: a first walk today gives All one day,
    /// which draws a point (a line of one point draws nothing).
    /// fails_when: the slice is empty, or not flagged single.
    /// no_claim: the point's size on screen (capture).
    @Test func aSingleDatumIsAPoint() {
        let progress = Self.progress(Self.history([Self.today: [100: 0x3FF]]), citywide: 1)
        let all = progress.slice(.all)
        #expect(all.isSingleDay)
        #expect(all.counts == [1])
        #expect(all.linePoints.map(\.count) == [1])
        #expect(all.yDomain == 0 ... 1)
        #expect(all.xTicks.map(\.style) == [.monthDay])
        #expect(!progress.slice(.week).isSingleDay)
    }

    // MARK: Scrubbing and VoiceOver (DS6)

    /// protects: the scrub reports the count and date of the day under the
    /// finger, clamped to the range; a lifted finger (nil) clears it.
    /// fails_when: the lookup is off by a day, runs past an end, or stays
    /// selected after lifting.
    /// no_claim: Swift Charts' gesture itself (live QA).
    @Test func scrubLooksUpAndClears() {
        let month = Self.progress().slice(.month)
        #expect(month.selection(at: nil) == nil)
        let threeBack = month.selection(at: month.lastIndex - 3)
        #expect(threeBack?.day == Self.day(3))
        #expect(threeBack?.count == 4)
        #expect(month.selection(at: -5)?.index == 0)
        #expect(month.selection(at: -5)?.day == Self.day(29))
        #expect(month.selection(at: 999)?.day == Self.today)
        #expect(month.selection(at: 999)?.count == 5)
        #expect(AppCopy.walkDayTitle(Self.day(3)).text == "Nov 14, 2026")
    }

    /// protects: VoiceOver's adjustable element steps one day at a time,
    /// starts from today, and stops at both ends; its value reads the day.
    /// fails_when: a step skips, wraps, or runs past an end.
    /// no_claim: VoiceOver's gesture (device pass).
    @Test func voiceOverStepsADayAtATime() {
        let week = Self.progress().slice(.week)
        #expect(week.stepped(from: nil, by: 1) == 6)
        #expect(week.stepped(from: nil, by: -1) == 6)
        #expect(week.stepped(from: 6, by: 1) == 6)
        #expect(week.stepped(from: 6, by: -1) == 5)
        #expect(week.stepped(from: 0, by: -1) == 0)
        #expect(week.stepped(from: 0, by: 1) == 1)
        let point = week.point(at: week.stepped(from: 6, by: -1))
        #expect(AppCopy.walkProgressValue(count: point.count, day: point.day).text == "5 blocks, Nov 16, 2026.")
    }

    // MARK: Headline (eng A4, AC 11)

    /// protects: the headline is Your Blocks' citywide count; the line is
    /// never shifted or topped up to meet it when a saved block has no day,
    /// and the gain counts dated blocks only; before a count the line's
    /// last value stands in; a stale lower count never shows under the line.
    /// fails_when: the line is moved, the headline reads the line when the
    /// totals are known, or the headline drops below the line.
    /// no_claim: how a block ends up with no day (WalkedBlockStore tests).
    @Test func headlineComesFromTheTotalsAndTheLineStaysHonest() {
        let undated = Self.progress(citywide: 7)
        #expect(undated.headline == 7)
        #expect(undated.counts.last == 5)
        #expect(undated.counts == Self.progress(citywide: 5).counts)
        #expect(undated.slice(.month).gain == 3)
        #expect(Self.progress(citywide: nil).headline == 5)
        #expect(Self.progress(citywide: 4).headline == 5)
        #expect(Self.progress(citywide: 5).headline == Self.fixtureHistory.cumulative.last?.count)
    }

    // MARK: Axis (DS6)

    /// protects: the x-axis tick days for every range (QA on an SE found
    /// "Nov 11" and "Nov 18" touching): today is always labelled, as a
    /// weekday in a week and "Nov 17" otherwise; the candidate before today
    /// is dropped when both labels would not fit in its gap on a 300 pt
    /// plot; a week's other days, a month's seventh days back, a quarter's
    /// month firsts and a year's quarter firsts (January as its year) stay.
    /// fails_when: a range drops today, keeps a tick that would touch its
    /// neighbour, or the days fall on the wrong dates.
    /// no_claim: Swift Charts' exact label metrics (the SE and branch
    /// device captures check them).
    @Test func axisTicksPerRange() {
        let progress = Self.progress()
        let expected: [(WalkProgressRange, [Int], [WalkProgressSlice.TickStyle])] = [
            (.week, [20261111, 20261112, 20261113, 20261114, 20261115, 20261117], Array(repeating: .weekday, count: 6)),
            (.month, [20261020, 20261027, 20261103, 20261117], Array(repeating: .monthDay, count: 4)),
            (.threeMonths, [20260901, 20261001, 20261117], [.month, .month, .monthDay]),
            (.year, [20260101, 20260401, 20260701, 20261117], [.year, .month, .month, .monthDay]),
            (.all, [20260901, 20261001, 20261117], [.month, .month, .monthDay])
        ]
        for (range, days, styles) in expected {
            let ticks = progress.slice(range).xTicks
            #expect(ticks.map(\.day.value) == days, "\(range)")
            #expect(ticks.map(\.style) == styles, "\(range)")
            #expect(ticks.last?.index == progress.slice(range).lastIndex, "\(range): today is labelled")
        }
        let week = progress.slice(.week).xTicks
        #expect(AppCopy.walkChartAxisLabel(week[5].day, style: .weekday).text == "Tue")
        #expect(AppCopy.walkChartAxisLabel(progress.slice(.month).xTicks[3].day, style: .monthDay).text == "Nov 17")
        #expect(AppCopy.walkChartAxisLabel(progress.slice(.threeMonths).xTicks[0].day, style: .month).text == "Sep")
        #expect(AppCopy.walkChartAxisLabel(progress.slice(.year).xTicks[0].day, style: .year).text == "2026")
    }

    /// protects: no two neighbouring x labels touch in any range, for
    /// histories from one day to three years, on the narrowest plot the
    /// ticks are spaced for (an SE's); today is always the last tick.
    /// fails_when: a pair of labels needs more room than its gap leaves.
    /// no_claim: the label width allowances themselves (measured on the
    /// simulator; the captures check them).
    @Test func neighbouringLabelsNeverTouch() {
        for back in [0, 3, 20, 60, 100, 200, 400, 1_100] {
            let progress = Self.progress(Self.history([Self.day(back): [100: 0x3FF], Self.day(1): [200: 0x3FF]]), citywide: 2)
            for range in WalkProgressRange.allCases {
                let slice = progress.slice(range)
                let ticks = slice.xTicks
                #expect(ticks.last?.index == slice.lastIndex, "\(range) over \(back) days")
                guard slice.lastIndex > 0 else { continue }
                let perDay = WalkProgressSlice.minimumPlotWidth / Double(slice.lastIndex)
                for (left, right) in zip(ticks, ticks.dropFirst()) {
                    var needed = WalkProgressSlice.labelWidth(left.style) + WalkProgressSlice.labelGap
                    if right.index == slice.lastIndex { needed += WalkProgressSlice.labelWidth(right.style) }
                    #expect(Double(right.index - left.index) * perDay >= needed, "\(range) over \(back) days")
                }
            }
        }
    }

    // MARK: Today at the 4 am boundary (eng A7)

    /// protects: the view model's `walkProgress(now:)` takes today from the
    /// New York walk day: at 3:59 am New York time today is still the
    /// previous date, so the chart ends, and its last point sits, on that
    /// date's key; at 4:00 am it moves on. Each `now` is written as a Tokyo
    /// wall-clock time (17:59 and 18:00, the next calendar date there), so a
    /// result that read the device's or Tokyo's zone would land a day late.
    /// fails_when: the chart's today follows midnight, or any zone but New
    /// York's.
    /// no_claim: the process's default time zone is not changed (tests run
    /// in parallel); the instant is fixed whatever zone it was written in.
    @Test func walkProgressTodayFollowsTheFourAMNewYorkDay() throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try #require(UserDefaults(suiteName: "WalkProgressTests.\(UUID().uuidString)"))
        let motion = FakeMotionProvider()
        let matcher = BlockMatchingActor(container: container, activityProvider: motion, loadGrid: { F.cornerGrid() }, onGridLoadFailure: { _ in })
        let recorder = WalkRecorder(
            modelContainer: container,
            userDefaults: defaults,
            access: { AuthorizationBox(.authorizedAlways).access },
            backend: FakeWalkBackend(),
            now: { Date() }
        )
        let viewModel = StreetsWalkedViewModel(
            locationPermissionClient: LocationPermissionClient(),
            modelContainer: container,
            recorder: recorder,
            userDefaults: defaults,
            motion: motion,
            matcher: matcher,
            firstCountRetryDelay: .zero
        )
        #expect(viewModel.walkProgress() == nil, "nothing before the first history read")
        let november17 = WalkedDayKey(value: 20261117)
        viewModel.walksHistory = Self.history([november17: [100: 0x3FF], november17.advanced(by: -3): [200: 0x3FF]])

        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let beforeFour = try #require(tokyo.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 17, minute: 59)))
        let atFour = try #require(tokyo.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 18)))
        #expect(beforeFour == WalkedDayKeyTests.newYork(2026, 11, 18, 3, 59))

        let late = try #require(viewModel.walkProgress(now: beforeFour))
        #expect(late.today == november17)
        let week = late.slice(.week)
        #expect(week.day(at: week.lastIndex) == november17)
        #expect(week.counts.last == 2)
        #expect(week.xTicks.last?.day == november17)

        let next = try #require(viewModel.walkProgress(now: atFour))
        #expect(next.today == WalkedDayKey(value: 20261118))
        #expect(next.slice(.week).day(at: next.slice(.week).lastIndex) == WalkedDayKey(value: 20261118))
        #expect(next.slice(.week).counts.suffix(2) == [2, 2], "the new day carries the count flat")
    }

    // MARK: Copy (DS8.5, DS8.7)

    /// protects: the range segments' visible and spoken names, and the
    /// menu hint's PR 2 wording.
    /// fails_when: a segment reads "1W" to VoiceOver, or the hint is PR 1's.
    /// no_claim: voice rules (AppCopyVoiceTests).
    @Test func rangeNamesAndMenuHint() {
        #expect(WalkProgressRange.allCases.map { AppCopy.walkRangeShort($0).text } == ["1W", "1M", "3M", "1Y", "All"])
        #expect(
            WalkProgressRange.allCases.map { AppCopy.walkRangeSpoken($0).text }
                == ["1 week", "1 month", "3 months", "1 year", "All"]
        )
        #expect(WalkProgressRange.initial == .month)
        #expect(AppCopy.YourWalks.menuHint.copy.text == "Shows the days you walked and your progress.")
    }
}
