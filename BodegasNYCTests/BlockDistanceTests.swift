//
//  BlockDistanceTests.swift
//  BodegasNYCTests
//
//  `BlockDistance(meters:horizontalAccuracy:)` (#68: spec D2, eng F1, design
//  D3/D6) and the `Coordinate` helpers the list row and detail header share
//  (eng S1: tested here, no separate CoordinateTests).
//
//  Miles are asserted within ±0.0001 throughout.
//

import CoreLocation
import Foundation
import Testing

@testable import BodegasNYC

struct BlockDistanceTests {
    private static let preciseAccuracy = 30.0

    private static func distance(_ meters: Double, accuracy: Double? = preciseAccuracy) -> BlockDistance? {
        BlockDistance(meters: meters, horizontalAccuracy: accuracy)
    }

    private static func expectMiles(_ distance: BlockDistance?, _ expected: Double) {
        guard case .miles(let miles) = distance else {
            Issue.record("expected miles(\(expected)), got \(String(describing: distance))")
            return
        }
        #expect(abs(miles - expected) <= 0.0001, "miles \(miles) is not within 0.0001 of \(expected)")
    }

    /// protects: whole-block counts at the schoolbook-rounding boundaries
    /// (1 block = 80.4672 m), including the corrected F1 fixtures.
    /// fails_when: banker's rounding, truncation, a different block length,
    /// or 120.6 m reading as 2 blocks.
    /// no_claim: the copy shown for a count (AppCopyVoiceTests).
    @Test func roundsToTheNearestWholeBlock() {
        #expect(Self.distance(40.2) == .aroundTheCorner)
        #expect(Self.distance(40.3) == .blocks(1))
        #expect(Self.distance(80.5) == .blocks(1))
        #expect(Self.distance(120.6) == .blocks(1))
        #expect(Self.distance(120.8) == .blocks(2))
        #expect(Self.distance(804.7) == .blocks(10))
        #expect(Self.distance(844.9) == .blocks(10))
        #expect(Self.distance(845) == .blocks(11))
    }

    /// protects: blocks run through 20 (20.49 blocks) and miles start at
    /// 20.5 blocks (design D6).
    /// fails_when: the cap is 10, or 1648.8 m reads as miles, or 1650 m
    /// reads as blocks.
    /// no_claim: how the miles number is formatted.
    @Test func blocksStopAtTwentyThenMiles() {
        #expect(BlockDistance.maxBlocks == 20)
        #expect(Self.distance(1648.8) == .blocks(20))
        Self.expectMiles(Self.distance(1650), 1650 / 1609.344)
        Self.expectMiles(Self.distance(1650), 1.0253)
        // Exactly one mile is exactly 20 blocks, so under design D6 it reads
        // as blocks; the spec's "1609.344 → miles(1.0)" fixture predates D6.
        #expect(Self.distance(1609.344) == .blocks(20))
        Self.expectMiles(Self.distance(16093.44), 10.0)
    }

    /// protects: "Around the corner" only on a fix accurate to 50 m or better
    /// (design D3).
    /// fails_when: a 60 m or unknown-accuracy fix claims the corner, or a
    /// 30 m / 50 m fix does not.
    /// no_claim: whether CoreLocation's reported accuracy is truthful.
    @Test func cornerNeedsAnAccurateFix() {
        #expect(Self.distance(0, accuracy: 30) == .aroundTheCorner)
        #expect(Self.distance(0, accuracy: 50) == .aroundTheCorner)
        #expect(Self.distance(0, accuracy: 60) == .blocks(1))
        #expect(Self.distance(40.2, accuracy: 60) == .blocks(1))
        #expect(Self.distance(0, accuracy: nil) == .blocks(1))
    }

    /// protects: a huge distance becomes miles without converting to Int.
    /// fails_when: the initializer traps (overflow) or returns blocks.
    /// no_claim: that such a distance is meaningful on Earth.
    @Test func hugeDistanceIsMilesWithoutOverflow() {
        guard case .miles(let miles) = Self.distance(1e300) else {
            Issue.record("1e300 m did not read as miles")
            return
        }
        // 6.21e296 mi; at this magnitude ±0.0001 is below one ulp, so the
        // check is relative.
        #expect(abs(miles / 6.2137e296 - 1) <= 0.0001)
    }

    /// protects: invalid input never produces a distance.
    /// fails_when: negative, NaN or infinite metres return a value.
    /// no_claim: anything about valid inputs.
    @Test func invalidMetresAreNil() {
        #expect(Self.distance(-1) == nil)
        #expect(Self.distance(-.ulpOfOne) == nil)
        #expect(Self.distance(.nan) == nil)
        #expect(Self.distance(.infinity) == nil)
        #expect(Self.distance(-.infinity) == nil)
    }

    /// protects: `Coordinate.distance(to:)` is metres along the ground
    /// (0.001° of latitude is about 111.2 m) and `blockDistance(from:)` uses
    /// it with the fix's accuracy.
    /// fails_when: degrees, kilometres or swapped lat/long are returned, or
    /// the fix's accuracy is ignored.
    /// no_claim: walking distance (it is straight-line by design, eng D12).
    @Test func coordinateHelpersMeasureFromTheFix() {
        let pin = Coordinate(latitude: 40.7291, longitude: -73.9965)
        let north = Coordinate(latitude: 40.7301, longitude: -73.9965)
        #expect(abs(pin.distance(to: north) - 111.2) <= 0.5)

        let fix = UserFix(coordinate: north, horizontalAccuracy: 10, timestamp: .now)
        #expect(pin.blockDistance(from: fix) == .blocks(1))
        let sameSpot = UserFix(coordinate: pin, horizontalAccuracy: 30, timestamp: .now)
        #expect(pin.blockDistance(from: sameSpot) == .aroundTheCorner)
        let coarse = UserFix(coordinate: pin, horizontalAccuracy: 60, timestamp: .now)
        #expect(pin.blockDistance(from: coarse) == .blocks(1))
        #expect(pin.blockDistance(from: nil) == nil)
    }
}
