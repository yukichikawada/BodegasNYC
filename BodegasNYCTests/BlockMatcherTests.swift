//
//  BlockMatcherTests.swift
//  BodegasNYCTests
//
//  Map-matching raw fixes into walked blocks (#108 spec Implementation 3,
//  AC1-AC6, AC10a; eng R6, R7, R10). Fixture blocks live in a local metre
//  plane (`StreetFixtures`); walks are straight lines of fixes at a speed.
//

import Foundation
import Testing

@testable import BodegasNYC

struct BlockMatcherTests {
    private typealias F = StreetFixtures

    /// protects: walking a whole block on its sidewalk (12 m off the
    /// centerline) at 1.4 m/s marks that block walked, and only it (AC1).
    /// fails_when: the sidewalk offset loses the block, or a cross street
    /// picks up 6 tenths from the corners.
    /// no_claim: real GPS noise.
    @Test func walkingAWholeBlockOnTheSidewalkWalksItAlone() {
        let masks = BlockMatcher.match(F.walk(from: (0, 12), to: (100, 12)), grid: F.cornerGrid())
        #expect(BlockMatcher.isWalked(mask: masks[100] ?? 0))
        for (id, mask) in masks where id != 100 {
            #expect(!BlockMatcher.isWalked(mask: mask), "block \(id) has \(F.bins(mask))")
        }
    }

    /// protects: the honest coverage band (AC2): on a 100 m block a
    /// contiguous 40% never reaches 6 tenths from any start in 0...60 m, and
    /// 60% always does from any start in 0...40 m, at 1 m steps.
    /// fails_when: the threshold, bin math or interval fill moves the band.
    /// no_claim: coverage between 40% and 60% (depends on the start).
    @Test func fortyPercentNeverAndSixtyPercentAlways() {
        let grid = F.loneBlockGrid()
        for start in 0 ... 60 {
            let walk = F.walk(from: (Double(start), 0), to: (Double(start) + 40, 0))
            let mask = BlockMatcher.match(walk, grid: grid)[100] ?? 0
            #expect(!BlockMatcher.isWalked(mask: mask), "40% from \(start) m walked \(F.bins(mask))")
        }
        for start in 0 ... 40 {
            let walk = F.walk(from: (Double(start), 0), to: (Double(start) + 60, 0))
            let mask = BlockMatcher.match(walk, grid: grid)[100] ?? 0
            #expect(BlockMatcher.isWalked(mask: mask), "60% from \(start) m only \(F.bins(mask))")
        }
    }

    /// protects: a 10 m block walked end to end is walked (eng R10:
    /// consecutive samples on one block fill the tenths between them).
    /// fails_when: short blocks need more samples than they can get.
    /// no_claim: blocks under one 2 m sample spacing.
    @Test func aTenMetreBlockWalkedEndToEndIsWalked() {
        let grid = F.loneBlockGrid(length: 10)
        let masks = BlockMatcher.match(F.walk(from: (-3, 2), to: (13, 2), spacing: 8), grid: grid)
        #expect(F.bins(masks[100]) == Set(0 ... 9))
    }

    /// protects: a taxi along the same block earns nothing (AC3).
    /// fails_when: the 4 m/s cap is not applied per leg.
    /// no_claim: cycling at walking speed without Motion data.
    @Test func theSamePathAtTaxiSpeedMarksNothing() {
        let masks = BlockMatcher.match(F.walk(from: (0, 12), to: (100, 12), speed: 10), grid: F.cornerGrid())
        #expect(masks.isEmpty)
    }

    /// protects: fixes 35 m from every block credit nothing (AC4).
    /// fails_when: the 30 m radius is ignored.
    /// no_claim: the radius suits every street (wide avenues are its case).
    @Test func fixesBeyondThirtyMetresCreditNothing() {
        let masks = BlockMatcher.match(F.walk(from: (40, 35), to: (60, 35), spacing: 5), grid: F.cornerGrid())
        #expect(masks.isEmpty)
    }

    /// protects: two walks an hour apart do not credit the blocks between
    /// their endpoints (AC5).
    /// fails_when: the walk-gap rule is skipped and the gap leg is sampled.
    /// no_claim: gaps under 20 minutes (the leg cap covers those).
    @Test func walksAnHourApartDoNotJoin() {
        let first = F.walk(from: (0, 0), to: (10, 0))
        let second = F.walk(from: (90, 0), to: (100, 0), startTime: 3_600)
        let mask = BlockMatcher.match(first + second, grid: F.loneBlockGrid())[100]
        #expect(F.bins(mask) == [0, 1, 9])
    }

    /// protects: turning tracking off and on 200 m further along (a pause,
    /// a subway ride, a GPS dropout) at a walking pace earns nothing
    /// between (eng R7: a leg over 60 m credits nothing).
    /// fails_when: a long leg at walking speed is sampled.
    /// no_claim: legs between 10 and 60 m that cut a corner.
    @Test func aLegOverSixtyMetresCreditsNothing() {
        let grid = F.loneBlockGrid(length: 300)
        let off = WalkedPointSnapshot(coordinate: F.coordinate(x: 0, y: 0), recordedAt: F.baseDate)
        let on = WalkedPointSnapshot(coordinate: F.coordinate(x: 200, y: 0), recordedAt: F.baseDate.addingTimeInterval(150))
        #expect(BlockMatcher.match([off, on], grid: grid).isEmpty)
        let pause = WalkedPointSnapshot(coordinate: F.coordinate(x: 61, y: 0), recordedAt: F.baseDate.addingTimeInterval(60))
        #expect(BlockMatcher.match([off, pause], grid: grid).isEmpty)
    }

    /// protects: a fix credits nothing on its own (spec Implementation 3).
    /// fails_when: an isolated fix, or one whose only legs are too fast or
    /// a zero-duration jump of 5 m or more, earns a bin.
    /// no_claim: the zero-duration rule for legs under 5 m beyond its bin.
    @Test func aFixAloneCreditsNothing() {
        let grid = F.loneBlockGrid()
        let alone = WalkedPointSnapshot(coordinate: F.coordinate(x: 50, y: 0), recordedAt: F.baseDate)
        #expect(BlockMatcher.match([alone], grid: grid).isEmpty)
        let fastNeighbour = WalkedPointSnapshot(coordinate: F.coordinate(x: 100, y: 0), recordedAt: F.baseDate.addingTimeInterval(5))
        #expect(BlockMatcher.match([alone, fastNeighbour], grid: grid).isEmpty)
        let sameInstantFar = WalkedPointSnapshot(coordinate: F.coordinate(x: 56, y: 0), recordedAt: F.baseDate)
        #expect(BlockMatcher.match([alone, sameInstantFar], grid: grid).isEmpty)
        let sameInstantNear = WalkedPointSnapshot(coordinate: F.coordinate(x: 53, y: 0), recordedAt: F.baseDate)
        #expect(F.bins(BlockMatcher.match([alone, sameInstantNear], grid: grid)[100]) == [5])
    }

    /// protects: a 3 m/s leg (under the speed cap) during an automotive
    /// stretch CoreMotion saw earns nothing; outside its coverage (denied,
    /// unavailable, older than 7 days) the speed rule alone decides (eng R6).
    /// fails_when: the ride filter is skipped, or applied without coverage.
    /// no_claim: CoreMotion's own classification (`CoreMotionActivityProvider`).
    @Test func aSlowLegDuringARideEarnsNothing() {
        let walk = F.walk(from: (0, 0), to: (100, 0), speed: 3)
        let span = DateInterval(start: F.baseDate.addingTimeInterval(-60), end: F.baseDate.addingTimeInterval(600))
        let ride = VehicleActivity(intervals: [span], coverage: span)
        #expect(BlockMatcher.match(walk, grid: F.loneBlockGrid(), activity: ride).isEmpty)
        let uncovered = VehicleActivity(
            intervals: [span],
            coverage: DateInterval(start: F.baseDate.addingTimeInterval(1_000), duration: 600)
        )
        #expect(BlockMatcher.isWalked(mask: BlockMatcher.match(walk, grid: F.loneBlockGrid(), activity: uncovered)[100] ?? 0))
        let walkingOnly = VehicleActivity(intervals: [], coverage: span)
        #expect(BlockMatcher.isWalked(mask: BlockMatcher.match(walk, grid: F.loneBlockGrid(), activity: walkingOnly)[100] ?? 0))
    }

    /// protects: rides are read from CoreMotion's entries: each lasts until
    /// the next starts, and only rides become intervals.
    /// fails_when: a ride's end is taken from its own start, or a walking
    /// entry becomes a ride.
    /// no_claim: CoreMotion's confidence levels (mapped in the provider).
    @Test func rideIntervalsSpanUntilTheNextEntry() {
        let t0 = F.baseDate
        let samples = [
            CoreMotionActivityProvider.Sample(startDate: t0, isRide: false),
            CoreMotionActivityProvider.Sample(startDate: t0.addingTimeInterval(60), isRide: true),
            CoreMotionActivityProvider.Sample(startDate: t0.addingTimeInterval(300), isRide: false),
            CoreMotionActivityProvider.Sample(startDate: t0.addingTimeInterval(400), isRide: true)
        ]
        let intervals = CoreMotionActivityProvider.rideIntervals(samples, until: t0.addingTimeInterval(500))
        #expect(intervals == [
            DateInterval(start: t0.addingTimeInterval(60), end: t0.addingTimeInterval(300)),
            DateInterval(start: t0.addingTimeInterval(400), end: t0.addingTimeInterval(500))
        ])
    }

    /// protects: matching is idempotent, and incremental matching split at
    /// every point (the last matched fix closing the next batch's first leg)
    /// equals one full match, including a split right after a fix whose next
    /// leg is too fast (AC6).
    /// fails_when: a fix credits on its own, or a batch boundary drops or
    /// adds a leg.
    /// no_claim: the store's choice of predecessor (BlockMatchingActorTests).
    @Test func incrementalMatchingEqualsAFullMatchAtEverySplit() {
        let grid = F.cornerGrid()
        let walk = F.walk(from: (0, 12), to: (60, 12))
            + F.walk(from: (60, 12), to: (100, 12), speed: 9, startTime: 60 / 1.4).dropFirst()
            + F.walk(from: (100, 12), to: (100, 70), startTime: 60 / 1.4 + 40 / 9).dropFirst()
        let points = Array(walk)
        let full = BlockMatcher.match(points, grid: grid)
        #expect(full == BlockMatcher.match(points, grid: grid))
        #expect(!full.isEmpty)
        for split in 1 ..< points.count {
            let first = BlockMatcher.match(Array(points[..<split]), grid: grid)
            let second = BlockMatcher.match(Array(points[(split - 1)...]), grid: grid)
            let merged = first.merging(second) { $0 | $1 }
            #expect(merged == full, "split at \(split)")
        }
    }

    /// protects: samples equidistant from two blocks credit the lower
    /// physicalid (AC10a), end to end through the matcher.
    /// fails_when: both blocks, or the higher id, get the bins.
    /// no_claim: near-ties beyond 0.01 m.
    @Test func equidistantSamplesCreditTheLowerID() {
        let grid = StreetGrid(segments: [
            F.segment(7, [(0, 10), (100, 10)]),
            F.segment(5, [(0, -10), (100, -10)])
        ])
        let masks = BlockMatcher.match(F.walk(from: (0, 0), to: (100, 0)), grid: grid)
        #expect(Array(masks.keys) == [5])
        #expect(F.bins(masks[5]) == Set(0 ... 9))
    }
}
