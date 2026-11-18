//
//  WalkedDayKeyTests.swift
//  BodegasNYCTests
//
//  Walk days (#170 PR 1, spec rules 1 and 2, eng A7, E2): the 4 am New York
//  day start across midnight and daylight saving, the matcher's per-day
//  split and distance, and the `estimatedThroughDay` rule. Times are New
//  York wall-clock instants; the walks run on the fixture corner grid.
//

import Foundation
import Testing

@testable import BodegasNYC

@MainActor
struct WalkedDayKeyTests {
    private typealias F = StreetFixtures

    /// A New York wall-clock instant.
    static func newYork(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return WalkedDayKey.calendar.date(from: parts) ?? Date.distantPast
    }

    /// A fixture walk whose first fix is at `start`.
    static func walk(_ from: (Double, Double), _ to: (Double, Double), at start: Date) -> [WalkedPointSnapshot] {
        F.walk(from: from, to: to, startTime: start.timeIntervalSince(F.baseDate))
    }

    // MARK: WalkedDayKey

    /// protects: spec rule 1's boundary: an instant before 4:00 am New York
    /// time belongs to the previous date, 4:00 am exactly to its own, and a
    /// 10 pm to 2 am night out is one day.
    /// fails_when: the day starts at midnight, or 4:00 belongs to the day before.
    /// no_claim: daylight-saving dates (the next test).
    @Test func aDayStartsAtFourAmNewYorkTime() {
        #expect(WalkedDayKey(date: Self.newYork(2026, 11, 3, 3, 59, 59)) == WalkedDayKey(value: 20261102))
        #expect(WalkedDayKey(date: Self.newYork(2026, 11, 3, 4)) == WalkedDayKey(value: 20261103))
        #expect(WalkedDayKey(date: Self.newYork(2026, 11, 3, 22)) == WalkedDayKey(value: 20261103))
        #expect(WalkedDayKey(date: Self.newYork(2026, 11, 4, 2)) == WalkedDayKey(value: 20261103))
        #expect(WalkedDayKey(date: Self.newYork(2027, 1, 1, 0, 30)) == WalkedDayKey(value: 20261231))
    }

    /// protects: daylight saving does not move the boundary (spec rule 1,
    /// AC 3): 3:59 am on the spring-forward and fall-back dates belongs to
    /// the date before, 4:00 am to its own, and the walk days around them
    /// are 23 and 25 hours long.
    /// fails_when: the key subtracts four hours instead of reading the hour
    /// (the fall-back night would then split at 3 am).
    /// no_claim: the ambiguous 1 am hour on the fall-back night (it is
    /// before 4 am either way).
    @Test func daylightSavingDoesNotMoveTheBoundary() {
        // 2026-03-08 springs forward at 2 am; 2026-11-01 falls back at 2 am.
        #expect(WalkedDayKey(date: Self.newYork(2026, 3, 8, 3, 59)) == WalkedDayKey(value: 20260307))
        #expect(WalkedDayKey(date: Self.newYork(2026, 3, 8, 4)) == WalkedDayKey(value: 20260308))
        #expect(WalkedDayKey(date: Self.newYork(2026, 11, 1, 3, 59)) == WalkedDayKey(value: 20261031))
        #expect(WalkedDayKey(date: Self.newYork(2026, 11, 1, 4)) == WalkedDayKey(value: 20261101))
        #expect(WalkedDayKey(value: 20260307).interval.duration == 23 * 3_600)
        #expect(WalkedDayKey(value: 20261031).interval.duration == 25 * 3_600)
        #expect(WalkedDayKey(value: 20261103).interval.duration == 24 * 3_600)
    }

    /// protects: day arithmetic and noon (eng A7) across month, year and
    /// daylight-saving edges, and the key's calendar is New York's whatever
    /// the device's zone.
    /// fails_when: `advanced(by:)` drifts an hour across a DST change and
    /// lands on the wrong date, or the calendar follows the device.
    /// no_claim: a device actually set to another zone (the key never reads
    /// `TimeZone.current`, so changing the process's zone would only race the
    /// parallel suite).
    @Test func dayArithmeticAndNoon() {
        let key = WalkedDayKey(value: 20261231)
        #expect(key.advanced(by: 1) == WalkedDayKey(value: 20270101))
        #expect(key.advanced(by: -31) == WalkedDayKey(value: 20261130))
        #expect(WalkedDayKey(value: 20260301).advanced(by: 7) == WalkedDayKey(value: 20260308))
        #expect(WalkedDayKey(value: 20261101).advanced(by: -1) == WalkedDayKey(value: 20261031))
        #expect(WalkedDayKey(date: key.noon) == key)
        #expect(WalkedDayKey.calendar.component(.hour, from: key.noon) == 12)
        #expect(WalkedDayKey.calendar.timeZone.identifier == "America/New_York")
        #expect((key.year, key.month, key.day) == (2026, 12, 31))
    }

    // MARK: matchByDay

    /// protects: a walk that crosses 4:00 am splits at the leg whose end
    /// fix is at or past 4:00 (AC 3), each day carries its own meters, and
    /// `match` still returns the OR of the days, unchanged (eng A9).
    /// fails_when: a leg is keyed by its start fix, the split is off by a
    /// leg, or the totals differ from the day masks' OR.
    /// no_claim: where a block's tenths fall (BlockMatcherTests).
    @Test func aWalkAcrossFourAmSplitsAtTheLegEndingAtFour() {
        // Fixes every 10 m at 1.4 m/s from 3:59:30: the fifth leg ends at
        // 4:00:05.7, the fourth at 3:59:58.6.
        let walk = Self.walk((0, 12), (100, 12), at: Self.newYork(2027, 1, 15, 3, 59, 30))
        let result = BlockMatcher.matchByDay(walk, grid: F.cornerGrid())
        let before = WalkedDayKey(value: 20270114)
        let after = WalkedDayKey(value: 20270115)
        #expect(Set(result.days.keys) == [before, after])
        #expect(abs((result.days[before]?.meters ?? 0) - 40) < 0.01)
        #expect(abs((result.days[after]?.meters ?? 0) - 60) < 0.01)
        let union = result.days.values.reduce(into: [UInt32: UInt16]()) { $0.merge($1.masks) { $0 | $1 } }
        #expect(result.masks == union)
        #expect(result.masks == BlockMatcher.match(walk, grid: F.cornerGrid()))
        #expect(BlockMatcher.isWalked(mask: result.masks[100] ?? 0))
    }

    /// protects: a 10 pm to 2 am night out is one walk day (spec rule 1,
    /// AC 3).
    /// fails_when: the 1:30 am walk lands on the next date.
    /// no_claim: sessions (a walk is never kept together by session).
    @Test func aNightOutIsOneDay() {
        let evening = Self.walk((0, 12), (100, 12), at: Self.newYork(2027, 1, 15, 22))
        let lateNight = Self.walk((0, 68), (100, 68), at: Self.newYork(2027, 1, 16, 1, 30))
        let result = BlockMatcher.matchByDay(evening + lateNight, grid: F.cornerGrid())
        let day = WalkedDayKey(value: 20270115)
        #expect(Array(result.days.keys) == [day])
        let walked = (result.days[day]?.masks ?? [:]).filter { BlockMatcher.isWalked(mask: $0.value) }
        #expect(Set(walked.keys) == [100, 300])
    }

    /// protects: spec rule 2: meters sum every creditable leg, matched or
    /// not, and nothing for legs that fail the walk rules (gaps, speed).
    /// fails_when: meters count only matched legs, or count a ride or gap.
    /// no_claim: the ride evidence rules (RideEvidenceTests).
    @Test func metersCountEveryCreditableLegMatchedOrNot() {
        let noon = Self.newYork(2027, 1, 15, 12)
        // 500 m north of the grid: matches nothing, still walked.
        let offGrid = Self.walk((0, 500), (100, 500), at: noon)
        let taxi = F.walk(from: (0, 12), to: (100, 12), speed: 12, startTime: noon.timeIntervalSince(F.baseDate) + 600)
        let result = BlockMatcher.matchByDay(offGrid + taxi, grid: F.cornerGrid())
        let day = WalkedDayKey(value: 20270115)
        #expect(result.masks.isEmpty)
        #expect(abs((result.days[day]?.meters ?? 0) - 100) < 0.01)
        #expect(result.days[day]?.masks.isEmpty == true)
    }

    // MARK: estimatedThroughDay (eng E2)

    private static let now = newYork(2027, 2, 1, 12)

    private static func fix(daysBefore days: Double, _ ride: RideEvidence) -> WalkedPointSnapshot {
        WalkedPointSnapshot(coordinate: F.coordinate(x: 0, y: 0), recordedAt: now.addingTimeInterval(-days * 86_400), ride: ride)
    }

    /// protects: the estimate is the day of the newest fix older than 7
    /// days whose leg has no evidence (saved or found this pass); the first
    /// fix, which ends no leg, never counts; nil when every old leg is known.
    /// fails_when: a recent unknown fix, the first fix, or a fix whose
    /// evidence this pass found marks days as estimates, or an older
    /// unknown fix is chosen over a newer one.
    /// no_claim: the pending device check on CoreMotion settling; this is
    /// the one function to change if it lands.
    @Test func estimatedThroughDayIsTheNewestOldUnknownLeg() {
        let first = Self.fix(daysBefore: 30, .unknown)
        let oldUnknown = Self.fix(daysBefore: 20, .unknown)
        let olderKnown = Self.fix(daysBefore: 10, .walking)
        let newestOldUnknown = Self.fix(daysBefore: 8, .unknown)
        let recentUnknown = Self.fix(daysBefore: 2, .unknown)
        let history = [first, oldUnknown, olderKnown, newestOldUnknown, recentUnknown]

        #expect(WalkedEstimate.throughDay(history, found: [:], now: Self.now) == WalkedDayKey(date: newestOldUnknown.recordedAt))
        #expect(
            WalkedEstimate.throughDay(history, found: [newestOldUnknown.id: .walking], now: Self.now)
                == WalkedDayKey(date: oldUnknown.recordedAt)
        )
        #expect(WalkedEstimate.throughDay([first, olderKnown, recentUnknown], found: [:], now: Self.now) == nil)
        #expect(WalkedEstimate.throughDay([first], found: [:], now: Self.now) == nil)
        #expect(WalkedEstimate.throughDay([], found: [:], now: Self.now) == nil)
    }

    /// protects: E2's intent for the backfill, which never asks CoreMotion
    /// (eng A1): with a zero window every unknown leg counts, however recent,
    /// so a recent unknown day is an estimate; known and found legs still do
    /// not, and rebuild and incremental passes keep the 7-day window.
    /// fails_when: a backfill leaves recent speed-only days unlabelled, or a
    /// rebuild labels days CoreMotion could still answer for.
    /// no_claim: the store passing the window (WalkedDayStoreTests).
    @Test func aBackfillCountsUnknownLegsOfAnyAge() {
        let first = Self.fix(daysBefore: 30, .unknown)
        let oldUnknown = Self.fix(daysBefore: 20, .unknown)
        let recentUnknown = Self.fix(daysBefore: 2, .unknown)
        let recentKnown = Self.fix(daysBefore: 1, .walking)
        let history = [first, oldUnknown, recentUnknown, recentKnown]

        #expect(WalkedEstimate.throughDay(history, found: [:], now: Self.now, window: 0) == WalkedDayKey(date: recentUnknown.recordedAt))
        #expect(
            WalkedEstimate.throughDay(history, found: [recentUnknown.id: .walking], now: Self.now, window: 0)
                == WalkedDayKey(date: oldUnknown.recordedAt)
        )
        #expect(WalkedEstimate.throughDay(history, found: [:], now: Self.now) == WalkedDayKey(date: oldUnknown.recordedAt))
        #expect(WalkedEstimate.askableWindow(for: .backfill) == 0)
        #expect(WalkedEstimate.askableWindow(for: .rebuild) == WalkedEstimate.window)
        #expect(WalkedEstimate.askableWindow(for: .incremental) == WalkedEstimate.window)
        #expect(WalkedEstimate.window == 7 * 86_400)
    }
}
