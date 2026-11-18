//
//  YourWalksTests.swift
//  BodegasNYCTests
//
//  Your Walks (#170 PR 1): `WalkedHistory.build` (walked versus new, the
//  grid filter, the E3 dot rule), the calendar's months and state
//  precedence (`YourWalksContent`, design DS2, DS8.2), the copy templates,
//  the view model's open/clear path, and the UI fixture's days. No views.
//

import CoreLocation
import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

@Suite
@MainActor
struct YourWalksTests {
    private typealias F = StreetFixtures

    private static let day1 = WalkedDayKey(value: 20261102)
    private static let day2 = WalkedDayKey(value: 20261103)
    private static let day3 = WalkedDayKey(value: 20261105)

    /// Blocks 100, 200, 201, 300 and 400 exist; 999 does not.
    private static let grid = F.cornerGrid()

    private static func build(
        _ masks: [WalkedDayKey: [UInt32: UInt16]],
        meters: [WalkedDayKey: Double] = [:],
        estimatedThroughDay: WalkedDayKey? = nil
    ) -> WalkedHistory {
        WalkedHistory.build(dayMasks: masks, dayMeters: meters, grid: grid, estimatedThroughDay: estimatedThroughDay, version: 1)
    }

    // MARK: WalkedHistory.build (spec rule 5, AC 4, eng E3, A4)

    /// protects: AC 4: a block half walked on day 1 and finished on day 2 is
    /// walked and new on day 2 only; a block walked fully on days 1 and 3
    /// is walked on both and new on day 1 only; the cumulative count adds
    /// the new blocks day by day.
    /// fails_when: a repeat counts as new, a half walk counts as walked, or
    /// a block finished across two days is not walked on the second.
    /// no_claim: how masks are matched (the store and matcher tests).
    @Test func walkedAndNewFollowTheRunningTotal() {
        let history = Self.build([
            Self.day1: [100: 0b1_1111, 200: 0x3FF],
            Self.day2: [100: 0b11_1110_0000],
            Self.day3: [200: 0x3FF]
        ])
        #expect(history.days.map(\.day) == [Self.day1, Self.day2, Self.day3])
        #expect(history.days.map(\.walkedIDs) == [[200], [100], [200]])
        #expect(history.days.map(\.newCount) == [1, 1, 0])
        #expect(history.cumulative.map(\.count) == [1, 2, 2])
    }

    /// protects: E3 and A4: a day with distance but no walked block (a
    /// sub-block walk, or walking where no block is) gets no dot; ids missing
    /// from the grid are skipped, so the last cumulative count equals the
    /// summary's citywide count.
    /// fails_when: meters alone make a day walked, or an unknown id counts.
    /// no_claim: the bundle's ids (the 1.0.0 store test).
    @Test func aDotNeedsAWalkedBlockInTheGrid() {
        let history = Self.build(
            [Self.day1: [100: 0b111], Self.day2: [999: 0x3FF, 300: 0x3FF]],
            meters: [Self.day1: 120, Self.day2: 300, Self.day3: 800]
        )
        #expect(history.days.map(\.isWalked) == [false, true, false])
        #expect(history.walkedDays.map(\.day) == [Self.day2])
        #expect(history.summary(for: Self.day2)?.walkedIDs == [300])
        #expect(history.summary(for: Self.day3)?.meters == 800)
        #expect(history.summary(for: WalkedDayKey(value: 20261104)) == nil)
        let totals: [UInt32: UInt16] = [100: 0b111, 999: 0x3FF, 300: 0x3FF]
        #expect(history.cumulative.last?.count == WalkedSummary(masks: totals, grid: Self.grid).citywide.walked)
        #expect(Self.build([:]).days.isEmpty && Self.build([:]).cumulative.isEmpty)
    }

    /// protects: E2's label: days up to `estimatedThroughDay` are estimates.
    /// fails_when: the boundary day, or a later one, is labelled wrongly.
    /// no_claim: how the day is computed (WalkedDayKeyTests).
    @Test func estimatesRunThroughTheirDay() {
        let history = Self.build([Self.day1: [100: 0x3FF]], estimatedThroughDay: Self.day2)
        #expect(history.isEstimate(Self.day1) && history.isEstimate(Self.day2))
        #expect(!history.isEstimate(Self.day3))
        #expect(!Self.build([Self.day1: [100: 0x3FF]]).isEstimate(Self.day1))
    }

    // MARK: Calendar content (DS2, DS8.2)

    /// Sunday first, New York, as the grid lays out an en_US phone.
    private static var sundayFirst: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WalkedDayKey.timeZone
        calendar.firstWeekday = 1
        return calendar
    }

    private static let november17 = WalkedDayKeyTests.newYork(2026, 11, 17, 18)

    private static func content(
        countState: StreetsWalkedViewModel.CountState = .ready,
        hasHistory: Bool = true,
        history: WalkedHistory?,
        historyFailed: Bool = false,
        isRecording: Bool = true,
        layout: Calendar = sundayFirst
    ) -> YourWalksContent {
        YourWalksContent(
            countState: countState,
            hasHistory: hasHistory,
            history: history,
            historyFailed: historyFailed,
            isRecording: isRecording,
            pausedProblem: nil,
            now: november17,
            layout: layout
        )
    }

    /// protects: DS2's months: first walked month through this month, in
    /// order, each with its weekday offset for the layout calendar, its
    /// walked days and new blocks; a month with no walks has no summary;
    /// today is flagged; estimates mark only walked days in their month.
    /// fails_when: a month is skipped or doubled, the offset ignores the
    /// first weekday, a repeat counts as new, or a sub-block day gets a dot.
    /// no_claim: how it looks (the simulator captures).
    @Test func monthsRunFromTheFirstWalkedMonthToToday() {
        let history = Self.build(
            [
                WalkedDayKey(value: 20260915): [100: 0x3FF],
                Self.day1: [100: 0x3FF, 200: 0x3FF, 300: 0b1],
                Self.day2: [300: 0x3FF],
                WalkedDayKey(value: 20261104): [400: 0b11]
            ],
            meters: [Self.day1: 2_253],
            estimatedThroughDay: WalkedDayKey(value: 20260915)
        )
        let content = Self.content(history: history)
        #expect(content.phase == .ready)
        #expect(content.months.map(\.title) == ["September 2026", "October 2026", "November 2026"])
        // 2026-09-01 is a Tuesday, 2026-11-01 a Sunday.
        #expect(content.months.map(\.leadingBlanks) == [2, 4, 0])
        #expect(content.months.map(\.days.count) == [30, 31, 30])
        let november = content.months[2]
        #expect(november.walkedDays.map(\.key) == [Self.day1, Self.day2])
        #expect(november.summaryParts == ["2 days", "2 new blocks"])
        #expect(content.months[1].summaryParts.isEmpty)
        #expect(content.months[0].summaryParts == ["1 day", "1 new block"])
        #expect(content.months[0].hasEstimate && !november.hasEstimate)
        #expect(november.days.filter(\.isToday).map(\.number) == [17])
        #expect(november.days[3].isWalked == false, "a sub-block day has no dot")
        #expect(content.walkedDays == [WalkedDayKey(value: 20260915), Self.day1, Self.day2])

        var mondayFirst = Self.sundayFirst
        mondayFirst.firstWeekday = 2
        #expect(Self.content(history: history, layout: mondayFirst).months.map(\.leadingBlanks) == [1, 3, 6])
    }

    /// protects: DS8.2's precedence, failure > loading > empty: the street
    /// data failing, then the day rows failing with nothing to show, then no
    /// history, then a first read, then history with no walked day; a
    /// refresh that fails keeps the last result; the status line and the
    /// months per state.
    /// fails_when: a failure shows a grid, loading hides it, or a failed
    /// refresh replaces a shown calendar with the failure line.
    /// no_claim: the 0 s timing of the status line (the view shows it at once).
    @Test func statePrecedence() {
        let walked = Self.build([Self.day1: [100: 0x3FF]])
        let unwalked = Self.build([WalkedDayKey(value: 20261010): [100: 0b1]], meters: [WalkedDayKey(value: 20261010): 40])

        #expect(Self.content(countState: .unavailable, history: walked).phase == .streetMapUnavailable)
        #expect(Self.content(history: nil, historyFailed: true).phase == .historyFailed)
        #expect(Self.content(history: walked, historyFailed: true).phase == .ready)
        #expect(Self.content(hasHistory: false, history: nil).phase == .noHistory)
        #expect(Self.content(hasHistory: false, history: nil).months.isEmpty)

        let loading = Self.content(history: nil)
        #expect(loading.phase == .loading)
        #expect(loading.months.map(\.title) == ["November 2026"])
        #expect(loading.months[0].walkedDays.isEmpty)
        #expect(loading.statusLine == "Finding your walks\u{2026}")

        let none = Self.content(history: unwalked)
        #expect(none.phase == .noWalkedDay)
        #expect(none.months.map(\.title) == ["October 2026", "November 2026"])
        #expect(none.statusLine == "No blocks counted yet.")
        #expect(Self.content(history: walked).statusLine == nil)
    }

    // MARK: Copy (DS4, DS5, DS8.5)

    /// protects: DS4's two lines and DS8.5's VoiceOver label: blocks
    /// (singular at one), new (left out at zero), miles spelled out through
    /// `distanceValue`; today and estimate in the label; other days read
    /// the date only; the day title carries the year.
    /// fails_when: "1 blocks", "0 new", kilometres or "mi", or a label that
    /// misses the date, today or the estimate.
    /// no_claim: voice rules (AppCopyVoiceTests).
    @Test func dayCopy() {
        let summary = WalkedDaySummary(day: Self.day2, walkedIDs: Set(1 ... 14), newCount: 9, meters: 2_253)
        #expect(AppCopy.walkDaySummary(summary).text == "14 blocks, 9 new, 1.4 miles.")
        #expect(
            AppCopy.walkDayLabel(summary, isToday: false, isEstimate: false).text
                == "Tuesday, November 3, 14 blocks, 9 new, 1.4 miles."
        )
        #expect(
            AppCopy.walkDayLabel(summary, isToday: true, isEstimate: true).text
                == "Tuesday, November 3, today, 14 blocks, 9 new, 1.4 miles, estimate."
        )
        let one = WalkedDaySummary(day: Self.day2, walkedIDs: [1], newCount: 0, meters: BlockDistance.metersPerMile)
        #expect(AppCopy.walkDaySummary(one).text == "1 block, 1 mile.")
        #expect(AppCopy.walkPlainDayLabel(Self.day1, isToday: false).text == "Monday, November 2")
        #expect(AppCopy.walkPlainDayLabel(Self.day1, isToday: true).text == "Monday, November 2, today")
        #expect(AppCopy.walkDayTitle(WalkedDayKey(value: 20251103)).text == "Nov 3, 2025")
        #expect(AppCopy.walkMonthTitle(Self.day1).text == "November 2026")
        #expect(AppCopy.walkMonthDays(1).text == "1 day" && AppCopy.walkMonthDays(8).text == "8 days")
        #expect(AppCopy.walkMonthNewBlocks(1).text == "1 new block")
        #expect(AppCopy.walkMonthNewBlocks(1_204).text == "1,204 new blocks")
        #expect(AppCopy.YourWalks.footer.copy.text == "A block counts once a day. Miles include repeats. Days start at 4 a.m.")
        #expect(AppCopy.YourWalks.estimates.copy.text == "Older days are estimates. Some rides may be counted.")
        #expect(AppCopy.YourWalks.menuHint.copy.text == "Shows the days you walked.")
    }

    // MARK: View model (DS8.3)

    /// protects: opening Your Walks reads the history after the pass it
    /// schedules; Clear History with the sheet open empties it (no walked
    /// day left, so an open day pops, DS8.3) and the state becomes no
    /// history.
    /// fails_when: the sheet never gets history, or keeps cleared days.
    /// no_claim: the navigation pop itself (the view's `onChange`).
    @Test func clearHistoryWithTheSheetOpenEmptiesIt() async throws {
        let container = try makeInMemoryModelContainer()
        let defaults = try #require(UserDefaults(suiteName: "YourWalksTests.\(UUID().uuidString)"))
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
        try F.seed(F.walk(from: (0, 12), to: (100, 12)), in: container.mainContext)

        viewModel.yourWalksDidOpen()
        while viewModel.isRefreshing { await Task.yield() }
        #expect(viewModel.walksHistory?.walkedDays.map(\.walkedIDs) == [[100]])
        #expect(viewModel.yourWalks(now: F.baseDate).walkedDays.count == 1)

        try await viewModel.clearHistory(at: F.baseDate.addingTimeInterval(86_400))
        #expect(viewModel.walksHistory?.days.isEmpty == true)
        let cleared = viewModel.yourWalks(now: F.baseDate)
        #expect(cleared.walkedDays.isEmpty)
        #expect(cleared.phase == .noHistory)
        viewModel.yourWalksDidClose()
        #expect(!viewModel.isYourWalksOpen)
    }

    // MARK: UI fixture (eng A10)

    /// protects: the `-UITestWalkedDays` fixture, matched against the real
    /// bundle, walks one block on each of four noon-anchored days, the
    /// 3-days-back day repeating the 9-days-back block before a new one, so
    /// the calendar shows four dots and that day reads "2 blocks, 1 new".
    /// fails_when: a walk lands on the wrong day, misses its block, or the
    /// repeat counts as new.
    /// no_claim: the app's launch-time seeding (the UI test covers it).
    @Test func uiFixtureWalksFourDays() throws {
        let grid = try StreetGrid.loadBundled()
        let now = WalkedDayKeyTests.newYork(2026, 11, 18, 2)
        let fixes = UITestFixtures.walkedDaysFixture(grid: grid, now: now)
        let result = BlockMatcher.matchByDay(fixes, grid: grid)
        let today = WalkedDayKey(date: now)
        #expect(today == WalkedDayKey(value: 20261117))
        let history = WalkedHistory.build(
            dayMasks: result.days.mapValues(\.masks),
            dayMeters: result.days.mapValues(\.meters),
            grid: grid,
            estimatedThroughDay: nil,
            version: 1
        )
        #expect(history.walkedDays.map(\.day) == UITestFixtures.walkedDayOffsets.map { today.advanced(by: -$0) })
        #expect(history.walkedDays.map(\.walkedIDs.count) == [1, 1, 2, 1])
        #expect(history.walkedDays.map(\.newCount) == [1, 1, 1, 1])
    }
}
