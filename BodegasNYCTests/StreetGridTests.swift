//
//  StreetGridTests.swift
//  BodegasNYCTests
//
//  The bundled street data and its lookup (#108 spec Implementation 1-2,
//  AC9, AC10a, eng A1/R5).
//

import Foundation
import Testing

@testable import BodegasNYC

struct StreetGridTests {
    private typealias F = StreetFixtures

    /// protects: the binary layout parses into the same ids, boroughs,
    /// vertices and header counts the script writes.
    /// fails_when: a field is read at the wrong offset or endianness, a
    /// borough code maps wrong, or segments come back out of order.
    /// no_claim: the script's own output (the bundle sanity test covers the
    /// shipped file).
    @Test func parsesTheBinaryLayout() throws {
        let segments = [
            F.segment(11, [(0, 0), (100, 0)], borough: .manhattan),
            F.segment(12, [(0, 0), (0, 50), (10, 80)], borough: .brooklyn),
            F.segment(13, [(500, 500), (520, 500)], borough: .queens),
            F.segment(14, [(900, 0), (900, 90)], borough: .statenIsland)
        ]
        let grid = try StreetGrid(data: F.binary(segments: segments, stamp: 1_792_226_103))

        #expect(grid.datasetStamp == 1_792_226_103)
        #expect(grid.segmentCount == 4)
        #expect(grid.physicalIDs == [11, 12, 13, 14])
        #expect(grid.boroughs == [.manhattan, .brooklyn, .queens, .statenIsland])
        #expect(grid.blockCounts == [.manhattan: 1, .bronx: 0, .brooklyn: 1, .queens: 1, .statenIsland: 1])
        let parsed = grid.polyline(for: 1)
        #expect(parsed.count == 3)
        for (got, want) in zip(parsed, segments[1].coordinates) {
            // Float32 storage: about 1e-5 degrees at worst.
            #expect(abs(got.latitude - want.latitude) < 1e-5)
            #expect(abs(got.longitude - want.longitude) < 1e-5)
        }
    }

    /// protects: a damaged or foreign file is rejected instead of read as
    /// garbage (eng R5's failure path starts here).
    /// fails_when: a bad magic, version, borough or length parses.
    /// no_claim: what the app does with the error (BlockMatchingActorTests).
    @Test func rejectsDamagedFiles() {
        let segments = [F.segment(1, [(0, 0), (10, 0)])]
        let good = F.binary(segments: segments)
        #expect(throws: StreetGrid.LoadError.badMagic) {
            try StreetGrid(data: F.binary(segments: segments, magic: Array("NOPE".utf8)))
        }
        #expect(throws: StreetGrid.LoadError.unsupportedVersion(9)) {
            try StreetGrid(data: F.binary(segments: segments, version: 9))
        }
        #expect(throws: StreetGrid.LoadError.truncated) {
            try StreetGrid(data: good.prefix(good.count - 3))
        }
        #expect(throws: StreetGrid.LoadError.countMismatch) {
            try StreetGrid(data: good + Data([0, 0]))
        }
        #expect(throws: StreetGrid.LoadError.truncated) {
            try StreetGrid(data: Data("NYCS".utf8))
        }
    }

    /// protects: at a corner the nearest block wins, and a sample
    /// equidistant from two blocks credits the lower physicalid (AC10a).
    /// fails_when: the tie goes to the higher id or to whichever edge was
    /// indexed first.
    /// no_claim: ties further apart than 0.01 m.
    @Test func nearestAtACornerAndTiesToTheLowerID() throws {
        let grid = StreetGrid(segments: [
            F.segment(7, [(0, 0), (100, 0)]),
            F.segment(5, [(0, 0), (0, 100)])
        ])
        let nearEast = try #require(grid.nearestSegment(to: F.coordinate(x: 20, y: 5), within: 30))
        #expect(grid.physicalIDs[nearEast.segment] == 7)
        let nearNorth = try #require(grid.nearestSegment(to: F.coordinate(x: 5, y: 20), within: 30))
        #expect(grid.physicalIDs[nearNorth.segment] == 5)
        let diagonal = try #require(grid.nearestSegment(to: F.coordinate(x: 10, y: 10), within: 30))
        #expect(grid.physicalIDs[diagonal.segment] == 5)
        #expect(abs(diagonal.distance - 10) < 0.01)
    }

    /// protects: a block is found from the neighbouring cell when the sample
    /// sits across a cell boundary from it (eng A1, 3x3 search), and nothing
    /// is found past 30 m.
    /// fails_when: the lookup reads only the sample's own cell, or ignores
    /// the radius.
    /// no_claim: cells two away (the radius is smaller than a cell).
    @Test func findsBlocksInNeighbouringCellsWithinTheRadius() throws {
        let grid = StreetGrid(segments: [F.segment(1, [(0, 0), (100, 0)])])
        // About 133 m per cell row: walk north until the cell changes, then
        // test 25 m and 35 m away on either side of that boundary.
        for y in stride(from: 1.0, through: 160.0, by: 3.0) {
            let sample = F.coordinate(x: 50, y: y)
            let match = grid.nearestSegment(to: sample, within: 30)
            if y <= 30 {
                #expect(match != nil, "missed at \(y) m")
            } else {
                #expect(match == nil, "matched at \(y) m")
            }
        }
        for y in stride(from: -1.0, through: -40.0, by: -3.0) {
            #expect((grid.nearestSegment(to: F.coordinate(x: 50, y: y), within: 30) != nil) == (y >= -30))
        }
    }

    /// protects: the bin math at both ends of a block: 0 is the first
    /// tenth, exactly 1 is the last, never an eleventh.
    /// fails_when: fraction 1.0 lands in bin 10, or a tenth's boundary goes
    /// to the lower bin.
    /// no_claim: the projection that produces the fraction.
    @Test func binsAtBothEnds() throws {
        #expect(BlockMatcher.bin(for: 0) == 0)
        #expect(BlockMatcher.bin(for: 0.0999) == 0)
        #expect(BlockMatcher.bin(for: 0.1) == 1)
        #expect(BlockMatcher.bin(for: 0.95) == 9)
        #expect(BlockMatcher.bin(for: 1) == 9)
        let grid = F.loneBlockGrid()
        let start = try #require(grid.nearestSegment(to: F.coordinate(x: -3, y: 4), within: 30))
        let end = try #require(grid.nearestSegment(to: F.coordinate(x: 103, y: 4), within: 30))
        #expect(start.fraction == 0)
        #expect(end.fraction == 1)
        #expect(BlockMatcher.bin(for: start.fraction) == 0)
        #expect(BlockMatcher.bin(for: end.fraction) == 9)
    }

    /// protects: the shipped `nyc-streets.bin` parses with unique ids and a
    /// header that matches its contents, and its totals are what Your Blocks
    /// will show (AC9).
    /// fails_when: the bundle is missing, stale against the parser, has a
    /// repeated physicalid, or its header counts disagree with its rows.
    /// no_claim: that the data matches the live CSCL dataset today.
    @Test func bundledStreetsAreSane() throws {
        let grid = try StreetGrid.loadBundled()
        #expect(Set(grid.physicalIDs).count == grid.segmentCount)
        #expect(grid.totalBlockCount == grid.segmentCount)
        var parsed: [Borough: Int] = [:]
        for borough in grid.boroughs { parsed[borough, default: 0] += 1 }
        #expect(parsed == grid.blockCounts)
        // 99,360 as of the 2026-10 data (spec Street data).
        #expect(grid.segmentCount > 95_000 && grid.segmentCount < 105_000)
        #expect(grid.blockCounts[.manhattan] == 9_300)
        #expect(zip(grid.physicalIDs, grid.physicalIDs.dropFirst()).allSatisfy { $0 < $1 })
        // Every block is in the city's bounding box.
        for index in stride(from: 0, to: grid.segmentCount, by: 997) {
            for point in grid.polyline(for: index) {
                #expect((40.47 ... 40.93).contains(point.latitude))
                #expect((-74.27 ... -73.68).contains(point.longitude))
            }
        }
    }
}
