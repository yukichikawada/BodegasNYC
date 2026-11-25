//
//  StreetMetersTests.swift
//  BodegasNYCTests
//
//  A day's miles measured along the streets (#192, eng E1 to E3): each fix
//  snaps to its nearest block within 30 m, a creditable leg adds the
//  shorter of its straight length and the distance between its snapped
//  ends, and a leg whose end fix is standing still adds nothing. Block
//  credit is unchanged. Walks run on fixture blocks in the matcher's own
//  metre plane, at noon New York time.
//

import Foundation
import Testing

@testable import BodegasNYC

@MainActor
struct StreetMetersTests {
    private typealias F = StreetFixtures
    private typealias K = WalkedDayKeyTests

    private static let noon = K.newYork(2027, 1, 15, 12)

    /// Fixes at `points` (metres), `seconds` apart, the first `start`
    /// seconds after noon.
    static func fixes(_ points: [(Double, Double)], every seconds: TimeInterval, from start: TimeInterval = 0) -> [WalkedPointSnapshot] {
        points.enumerated().map { index, point in
            WalkedPointSnapshot(
                coordinate: F.coordinate(x: point.0, y: point.1),
                recordedAt: noon.addingTimeInterval(start + Double(index) * seconds)
            )
        }
    }

    /// A fixture walk at 1.4 m/s, fixes 10 m apart, from `start` seconds
    /// after noon.
    static func walk(_ from: (Double, Double), _ to: (Double, Double), from start: TimeInterval = 0) -> [WalkedPointSnapshot] {
        K.walk(from, to, at: noon.addingTimeInterval(start))
    }

    /// Every day's meters of one match, summed.
    static func meters(_ walk: [WalkedPointSnapshot], _ grid: StreetGrid) -> Double {
        BlockMatcher.matchByDay(walk, grid: grid).days.values.reduce(0) { $0 + $1.meters }
    }

    /// Each leg's street meters as the matcher counts it, look-back
    /// included: a match of the history up to the leg's end fix that forms
    /// only that leg (`firstLegEnd`). Index 0 is the leg ending at fix 1.
    static func legMeters(_ walk: [WalkedPointSnapshot], _ grid: StreetGrid) -> [Double] {
        (1 ..< walk.count).map { end in
            BlockMatcher.matchByDay(Array(walk[...end]), grid: grid, firstLegEnd: end)
                .days.values.reduce(0) { $0 + $1.meters }
        }
    }

    /// Two 80 m blocks meeting at a right angle at (80, 0).
    static let rightAngle = StreetGrid(segments: [F.segment(1, [(0, 0), (80, 0)]), F.segment(2, [(80, 0), (80, 80)])])

    // MARK: Fixture walks (AC 1, 4, 5, 5a, 5b; 5c reads them all)

    /// AC 1: six fixes 16 m apart along an 80 m block, alternately 8 m left
    /// and right of it, 12 s apart.
    static let wobble: [WalkedPointSnapshot] = {
        let points: [(Double, Double)] = (0 ..< 6).map { step in (Double(step) * 16, step % 2 == 0 ? 8.0 : -8.0) }
        return fixes(points, every: 12)
    }()
    /// AC 4: a 100 m block walked out and back, 4 m beside it.
    static let outAndBack: [WalkedPointSnapshot] = walk((0, 4), (100, 4)) + walk((100, 4), (0, 4), from: 100 / 1.4 + 7)
    /// AC 5: fixes every 16 m on the centerlines, one on the corner.
    static let roundTheCorner: [WalkedPointSnapshot] = {
        let east: [(Double, Double)] = (0 ... 5).map { step in (Double(step) * 16, 0.0) }
        let north: [(Double, Double)] = (1 ... 5).map { step in (80.0, Double(step) * 16) }
        return fixes(east + north, every: 12)
    }()
    /// AC 5a: one fix 40 m before the corner, the next 40 m after it.
    static let cutTheCorner: [WalkedPointSnapshot] = fixes([(40, 0), (80, 40)], every: 20)
    /// AC 5b: 10 m beside blocks 100 and 400, straight across cross street
    /// 201's centerline at x = 100, fixes every 16 m over 96 m.
    static let acrossAStreet: [WalkedPointSnapshot] = {
        let points: [(Double, Double)] = (0 ... 6).map { step in (52 + Double(step) * 16, 10.0) }
        return fixes(points, every: 12)
    }()

    /// protects: AC 1: GPS wobble across a block does not add miles: six
    /// fixes zigzagging 8 m either side of an 80 m block measure 80 m along
    /// it (the straight legs sum to 113 m).
    /// fails_when: meters are the straight-leg sum (the pre-#192 rule), or
    /// a snapped position is off the centerline.
    /// no_claim: real GPS noise, which is not a clean zigzag (QA's replay,
    /// AC 11).
    @Test func wobbleAcrossABlockMeasuresTheBlock() {
        let grid = F.loneBlockGrid(length: 80)
        let straight = zip(Self.wobble, Self.wobble.dropFirst()).reduce(0) { $0 + BlockMatcher.distance($1.0.coordinate, $1.1.coordinate) }
        #expect(straight > 113)
        #expect(abs(Self.meters(Self.wobble, grid) - 80) < 1)
    }

    /// protects: AC 3: the distance between two clusters of walking never
    /// enters the day's miles: two walks 3 miles and 30 minutes apart on
    /// one day measure exactly the sum of each walk alone.
    /// fails_when: the 4.8 km gap leg (or any part of it) is counted.
    /// no_claim: the gap rules themselves (`isCreditableLeg`, unchanged).
    @Test func theGapBetweenTwoClustersAddsNothing() {
        let threeMiles = 3 * BlockDistance.metersPerMile
        let grid = StreetGrid(segments: [
            F.segment(100, [(0, 0), (100, 0)]),
            F.segment(500, [(threeMiles, 0), (threeMiles + 100, 0)])
        ])
        let first = Self.walk((0, 0), (100, 0))
        let firstEnds = (first.last?.recordedAt ?? Self.noon).timeIntervalSince(Self.noon)
        let second = Self.walk((threeMiles, 0), (threeMiles + 100, 0), from: firstEnds + 1_800)
        let gap = BlockMatcher.distance(first[first.count - 1].coordinate, second[0].coordinate)
        // The gap leg: from the first walk's end (x = 100) to the second's
        // start (x = 4,828), 4,728 m in 30 minutes.
        #expect(abs(gap - (threeMiles - 100)) < 0.5)
        let both = BlockMatcher.matchByDay(first + second, grid: grid)
        #expect(both.days.count == 1)
        let alone = Self.meters(first, grid) + Self.meters(second, grid)
        #expect(abs(Self.meters(first + second, grid) - alone) < 0.01)
        #expect(abs(alone - 200) < 0.01)
    }

    /// protects: AC 4: repeats count: one block walked out and back
    /// measures twice its length.
    /// fails_when: a repeat is dropped, or the turn adds a spurious leg.
    /// no_claim: blocks, which count once (unchanged).
    @Test func outAndBackCountsTwice() {
        #expect(abs(Self.meters(Self.outAndBack, F.loneBlockGrid()) - 200) < 2)
    }

    /// protects: AC 5, 5a: round a corner with a fix on it, two 80 m blocks
    /// measure 160 m; a leg that cuts the corner measures the diagonal
    /// between its snapped ends, 56.6 m (accepted, eng E1).
    /// fails_when: the corner fix is dropped or double-counted, or the cut
    /// leg measures along both blocks (80 m) or nothing.
    /// no_claim: corners that are not right angles.
    @Test func aCornerMeasuresBothBlocksOrTheDiagonal() {
        #expect(abs(Self.meters(Self.roundTheCorner, Self.rightAngle) - 160) < 1)
        #expect(abs(Self.meters(Self.cutTheCorner, Self.rightAngle) - 40 * 2.0.squareRoot()) < 1)
    }

    /// protects: AC 5b: crossing a street keeps its distance: a walk 10 m
    /// beside a block, straight across a cross street's centerline,
    /// measures its 96 m even where the fix on the crossing snaps to the
    /// cross street.
    /// fails_when: the crossing loses distance (the spec's sampled rule,
    /// replaced by eng E1), or a leg into or out of the cross street
    /// counts more than its straight length.
    /// no_claim: wide avenues where both sidewalks are over 30 m apart.
    @Test func crossingAStreetKeepsItsDistance() {
        #expect(abs(Self.meters(Self.acrossAStreet, F.cornerGrid()) - 96) < 4)
    }

    /// protects: AC 5c: no leg of any fixture walk in these tests measures
    /// more than its straight length (plus 0.01 m).
    /// fails_when: a leg adds the snapped distance when it is the longer
    /// one (a snap across a corner, a wobble).
    /// no_claim: walks other than these fixtures.
    @Test func noLegMeasuresMoreThanItsStraightLength() {
        let walks: [(String, [WalkedPointSnapshot], StreetGrid)] = [
            ("wobble", Self.wobble, F.loneBlockGrid(length: 80)),
            ("out and back", Self.outAndBack, F.loneBlockGrid()),
            ("round the corner", Self.roundTheCorner, Self.rightAngle),
            ("cut the corner", Self.cutTheCorner, Self.rightAngle),
            ("across a street", Self.acrossAStreet, F.cornerGrid()),
            ("dwell then walk", Self.dwellThenWalk, Self.longBlock),
            ("dense 3 s", Self.pacing(every: 3), F.loneBlockGrid()),
            ("dense 4 s", Self.pacing(every: 4), F.loneBlockGrid())
        ]
        for (name, walk, grid) in walks {
            for (index, meters) in Self.legMeters(walk, grid).enumerated() {
                let straight = BlockMatcher.distance(walk[index].coordinate, walk[index + 1].coordinate)
                #expect(meters <= straight + 0.01, "\(name) leg \(index + 1): \(meters) > \(straight)")
            }
        }
    }

    // MARK: Standing still (AC 6, eng E2, E3)

    /// A 300 m block, so the walk after the dwell stays on it.
    static let longBlock = F.loneBlockGrid(length: 300)

    /// AC 6: twenty fixes 30 s apart alternating between (40, 0) and
    /// (60, 0), ten minutes in all, then ten fixes on along the block 16 m
    /// and 12 s apart (x = 76 to 220).
    static let dwellThenWalk: [WalkedPointSnapshot] = {
        let pacing: [(Double, Double)] = (0 ..< 20).map { step in (step % 2 == 0 ? 40.0 : 60.0, 0.0) }
        let onward: [(Double, Double)] = (1 ... 10).map { step in (60 + Double(step) * 16, 0.0) }
        return fixes(pacing, every: 30) + fixes(onward, every: 12, from: 570 + 12)
    }()

    /// protects: AC 6 and eng E2: standing still adds no miles but keeps
    /// block credit. Pacing 20 m back and forth adds 20 m a leg until the
    /// end fix is 240 s after the first fix, then nothing; walking on, the
    /// leg to x = 76 (36 m from the dwell's far point) still adds nothing,
    /// the first leg past 50 m from every fix of its window (x = 92) adds
    /// its 16 m again, and so does every leg after it. The masks equal
    /// those of crediting every creditable leg with the dwell rule off.
    /// fails_when: the dwell starts early or late, is judged on the leg's
    /// start, never ends, or touches block credit.
    /// no_claim: real pacing with "walking" evidence, which the rule also
    /// leaves out (accepted, E2).
    @Test func standingStillAddsNoMetersButKeepsBlocks() {
        let walk = Self.dwellThenWalk
        let legs = Self.legMeters(walk, Self.longBlock)
        for (index, meters) in legs.enumerated() {
            let end = walk[index + 1]
            let seconds = end.recordedAt.timeIntervalSince(walk[0].recordedAt)
            let x = (end.coordinate.longitude - F.originLongitude)
                * cos(F.originLatitude * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator
            let expected: Double = switch index + 1 {
            case 1 ..< 20: seconds < 240 ? 20 : 0
            case 20: 0
            default: 16
            }
            #expect(abs(meters - expected) < 0.01, "leg \(index + 1) to x = \(x) at \(seconds) s: \(meters)")
        }
        #expect(abs(Self.meters(walk, Self.longBlock) - (7 * 20 + 9 * 16)) < 0.01)

        let withDwell = BlockMatcher.matchByDay(walk, grid: Self.longBlock).masks
        var withoutDwell: [UInt32: UInt16] = [:]
        for (start, end) in zip(walk, walk.dropFirst())
        where BlockMatcher.isCreditableLeg(from: start, to: end, activity: .unavailable) {
            BlockMatcher.creditLeg(from: start.coordinate, to: end.coordinate, grid: Self.longBlock, into: &withoutDwell)
        }
        #expect(withDwell == withoutDwell)
        #expect(!withDwell.isEmpty)
    }

    /// 100 fixes alternating between (40, 0) and (50, 0), `seconds` apart.
    static func pacing(every seconds: TimeInterval) -> [WalkedPointSnapshot] {
        let points: [(Double, Double)] = (0 ..< 100).map { step in (step % 2 == 0 ? 40.0 : 50.0, 0.0) }
        return fixes(points, every: seconds)
    }

    /// protects: AC 6's bound (eng E3): the look-back reads at most the 64
    /// fixes before the end fix. Pacing with fixes 3 s apart puts about
    /// 100 fixes in the 300 s window, but the newest 64 reach back only
    /// 192 s, so no leg is standing still and all 99 add 10 m; 4 s apart,
    /// the 64 reach back 256 s, so legs from the 60th (240 s) add nothing.
    /// fails_when: the cap is missing (3 s pacing would dwell from 240 s),
    /// or a capped window that does not reach back 240 s counts as
    /// standing still.
    /// no_claim: performance on a real dense import.
    @Test func theLookBackReadsAtMostSixtyFourFixes() {
        #expect(BlockMatcher.dwellMaxFixes == 64)
        let grid = F.loneBlockGrid()
        #expect(abs(Self.meters(Self.pacing(every: 3), grid) - 99 * 10) < 0.01)
        let slower = Self.legMeters(Self.pacing(every: 4), grid)
        #expect(slower.prefix(59).allSatisfy { abs($0 - 10) < 0.01 })
        #expect(slower.dropFirst(59).allSatisfy { $0 == 0 })
    }
}
