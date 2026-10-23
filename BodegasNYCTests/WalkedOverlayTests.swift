//
//  WalkedOverlayTests.swift
//  BodegasNYCTests
//
//  The walked-block overlay's pure rules (#108 spec Implementation 6, AC10;
//  eng R3; design D1-D3).
//

import Foundation
import MapKit
import Testing
import UIKit

@testable import BodegasNYC

struct WalkedOverlayTests {
    private typealias F = StreetFixtures

    /// protects: blocks sharing an endpoint chain into one run keyed by its
    /// first block's physicalid, a run turns no corner at a junction (the
    /// two straight-through blocks there join, the turning one ends), and a
    /// run's id does not change when an unrelated block is walked (eng R3).
    /// fails_when: runs are keyed by list position, a straight chain draws
    /// as separate lines, or a run turns a corner at a junction.
    /// no_claim: how MapKit diffs the `ForEach`.
    @Test func runsChainAtSharedEndpointsWithStableIDs() {
        let grid = StreetGrid(segments: [
            F.segment(10, [(0, 0), (100, 0)]),
            F.segment(30, [(200, 0), (100, 0)]),
            F.segment(20, [(200, 0), (300, 0)]),
            F.segment(40, [(300, 0), (300, 100)]),
            F.segment(41, [(300, 0), (300, -100)]),
            F.segment(90, [(1_000, 1_000), (1_100, 1_000)])
        ])
        let chain = WalkedOverlay.runs(walkedIDs: [10, 20, 30], grid: grid)
        #expect(chain.map(\.id) == [10])
        #expect(chain.first?.coordinates.count == 4)
        #expect(chain.first?.coordinates.first == F.coordinate(x: 0, y: 0))
        #expect(chain.first?.coordinates.last == F.coordinate(x: 300, y: 0))

        let junction = WalkedOverlay.runs(walkedIDs: [10, 20, 30, 40, 41], grid: grid)
        // 40 and 41 continue each other straight through (300, 0); 20 meets
        // them at a right angle, so its run ends there.
        #expect(Set(junction.map(\.id)) == [10, 40])
        #expect(junction.first { $0.id == 40 }?.coordinates.count == 3)

        let withUnrelated = WalkedOverlay.runs(walkedIDs: [10, 20, 30, 90], grid: grid)
        #expect(Set(withUnrelated.map(\.id)) == [10, 90])
        #expect(withUnrelated.first { $0.id == 10 } == chain.first)
    }

    /// protects: an avenue walked across its cross streets draws as one run
    /// (#108 R3 device check: chaining only at two-block endpoints left the
    /// 5,000-block seed at 4,285 runs, one per block at every Manhattan
    /// intersection), and the cross streets stay runs of their own.
    /// fails_when: a junction ends the avenue's run, or a cross street joins
    /// it at a right angle.
    /// no_claim: the 30° tolerance suits every street geometry.
    @Test func runsContinueStraightThroughJunctions() {
        var segments: [StreetGrid.Segment] = []
        for block in 0 ..< 5 {
            let x = Double(block) * 100
            segments.append(F.segment(UInt32(100 + block), [(x, 0), (x + 100, 0)]))
            segments.append(F.segment(UInt32(200 + block), [(x + 100, -80), (x + 100, 0)]))
            segments.append(F.segment(UInt32(300 + block), [(x + 100, 0), (x + 100, 80)]))
        }
        let grid = StreetGrid(segments: segments)
        let avenue = WalkedOverlay.runs(walkedIDs: Set((100 ..< 105).map(UInt32.init)), grid: grid)
        #expect(avenue.map(\.id) == [100])
        let everything = WalkedOverlay.runs(walkedIDs: Set(segments.map(\.physicalID)), grid: grid)
        // The avenue, plus each cross street (south and north blocks join
        // straight through the avenue): 1 + 5 runs, not 15.
        #expect(everything.count == 6)
        #expect(everything.first { $0.id == 100 }?.coordinates.count == 6)
    }

    /// protects: the drawn polyline drops collinear interior vertices and
    /// keeps corners and both ends.
    /// fails_when: a corner is cut, an end moves, or a straight run keeps
    /// every block's vertices.
    /// no_claim: the 0.5 m tolerance is invisible at every zoom.
    @Test func drawnGeometryDropsCollinearVertices() {
        let straight = (0 ... 6).map { F.coordinate(x: Double($0) * 100, y: 0) }
        #expect(WalkedOverlay.simplified(straight) == [straight[0], straight[6]])
        let corner = [F.coordinate(x: 0, y: 0), F.coordinate(x: 50, y: 0), F.coordinate(x: 100, y: 0), F.coordinate(x: 100, y: 80)]
        #expect(WalkedOverlay.simplified(corner) == [corner[0], corner[2], corner[3]])
        let run = WalkedRun(id: 1, coordinates: straight)
        #expect(run.polyline.pointCount == 2)
        #expect(run.coordinates == straight)
    }

    /// protects: culling keeps every run whose bounding box meets the region
    /// expanded by 25% on each side and drops every other (AC10).
    /// fails_when: a run just inside the margin is dropped or one outside it
    /// is drawn.
    /// no_claim: the region MapKit reports for a pitched camera.
    @Test func cullsToTheRegionExpandedByAQuarter() {
        // A 1 km x 1 km region centred on the origin; the margin reaches
        // 750 m from the centre.
        let region = WalkedRegion(
            centerLatitude: F.originLatitude,
            centerLongitude: F.originLongitude,
            latitudeDelta: 1_000 / StreetGrid.metersPerDegreeLatitude,
            longitudeDelta: 1_000 / (cos(F.originLatitude * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator)
        )
        func run(_ id: UInt32, x: Double, y: Double) -> WalkedRun {
            WalkedRun(id: id, coordinates: [F.coordinate(x: x, y: y), F.coordinate(x: x + 20, y: y)])
        }
        let runs = [
            run(1, x: 0, y: 0), run(2, x: 700, y: 0), run(3, x: 760, y: 0),
            run(4, x: 0, y: -740), run(5, x: 0, y: -760), run(6, x: -760, y: 0)
        ]
        #expect(WalkedOverlay.visible(runs, in: region) == .runs([runs[0], runs[1], runs[3], runs[5]]))
    }

    /// protects: past 1,000 visible runs nothing is drawn, never a partial
    /// subset (design D3 over eng R3's nearest subset); exactly 1,000 draws.
    /// The cap was lowered from 2,000 after the R3 device check. Both the
    /// full scan and the spatial index agree.
    /// fails_when: the cap draws a subset, hides at 1,000, or drifts.
    /// no_claim: the frame rate at 1,000 runs (on-device check).
    @Test func overTheCapHidesTheWholeLayer() {
        #expect(WalkedOverlay.maxVisibleRuns == 1_000)
        let region = WalkedRegion(centerLatitude: F.originLatitude, centerLongitude: F.originLongitude, latitudeDelta: 0.1, longitudeDelta: 0.1)
        let runs = (0 ..< 1_001).map {
            WalkedRun(id: UInt32($0), coordinates: [F.coordinate(x: Double($0), y: 0), F.coordinate(x: Double($0), y: 10)])
        }
        guard case .runs(let drawn) = WalkedOverlay.visible(Array(runs.prefix(1_000)), in: region) else {
            Issue.record("1,000 runs should draw")
            return
        }
        #expect(drawn.count == 1_000)
        #expect(WalkedRunIndex(runs: Array(runs.prefix(1_000))).visible(in: region) == .runs(drawn))
        #expect(WalkedOverlay.visible(runs, in: region) == .overCap)
        #expect(WalkedRunIndex(runs: runs).visible(in: region) == .overCap)
        let farAway = runs.map { WalkedRun(id: $0.id, coordinates: $0.coordinates.map { Coordinate(latitude: $0.latitude + 1, longitude: $0.longitude) }) }
        #expect(WalkedOverlay.visible(farAway + Array(runs.prefix(5)), in: region) == .runs(Array(runs.prefix(5))))
        #expect(WalkedRunIndex(runs: farAway + Array(runs.prefix(5))).visible(in: region) == .runs(Array(runs.prefix(5))))
    }

    /// Runs on a 50 m lattice around `(x, y)` metres: `count` short runs,
    /// ids from `firstID`.
    private static func lattice(count: Int, firstID: UInt32, x: Double, y: Double) -> [WalkedRun] {
        let side = Int(Double(count).squareRoot().rounded(.up))
        return (0 ..< count).map { index in
            let px = x + Double(index % side) * 50
            let py = y + Double(index / side) * 50
            return WalkedRun(id: firstID + UInt32(index), coordinates: [F.coordinate(x: px, y: py), F.coordinate(x: px + 40, y: py)])
        }
    }

    /// A phone-shaped region `height` metres tall centred `(x, y)` metres
    /// from the fixture origin.
    private static func region(x: Double, y: Double, height: Double) -> WalkedRegion {
        let center = F.coordinate(x: x, y: y)
        return WalkedRegion(
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            latitudeDelta: height / StreetGrid.metersPerDegreeLatitude,
            longitudeDelta: height * 402 / 874 / (cos(F.originLatitude * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator)
        )
    }

    /// protects: the spatial index culls exactly as the full scan does, at
    /// every zoom from a block to the whole fixture, including views that
    /// straddle cells and views off the data.
    /// fails_when: a run on a cell edge is missed, counted twice, reordered,
    /// or the cap is applied differently.
    /// no_claim: cost (the next test).
    @Test func spatialIndexMatchesTheFullScan() {
        let runs = Self.lattice(count: 3_000, firstID: 1, x: -1_000, y: -1_000)
            + [WalkedRun(id: 90_000, coordinates: [F.coordinate(x: -2_000, y: 0), F.coordinate(x: 2_000, y: 0)])]
        let index = WalkedRunIndex(runs: runs)
        for height in [150.0, 400, 1_000, 2_500, 8_000] {
            for x in stride(from: -1_500.0, through: 2_500, by: 377) {
                for y in stride(from: -1_500.0, through: 2_500, by: 411) {
                    let region = Self.region(x: x, y: y, height: height)
                    #expect(index.visible(in: region) == WalkedOverlay.visible(runs, in: region), "\(height) m at \(x), \(y)")
                }
            }
        }
    }

    /// protects: a settle's culling cost follows what is in view, not the
    /// whole history (#108 R3 device check: the 5,000-block seed hitched
    /// zoomed in while 39 real blocks did not). The same block-zoom view
    /// examines the same index entries with 100 runs walked or with 4,900
    /// more elsewhere; the full scan grows 50x.
    /// fails_when: culling scans every run, or the index puts far runs in
    /// the view's cells.
    /// no_claim: MapKit's own per-overlay cost (on-device check).
    @Test func settleCullingCostIsFlatInTheTotal() {
        let nearby = Self.lattice(count: 100, firstID: 1, x: -250, y: -250)
        let elsewhere = Self.lattice(count: 4_900, firstID: 10_000, x: 6_000, y: 6_000)
        let small = WalkedRunIndex(runs: nearby)
        let large = WalkedRunIndex(runs: nearby + elsewhere)
        let view = Self.region(x: 0, y: 0, height: 400)
        let smallQuery = small.query(view)
        let largeQuery = large.query(view)
        #expect(smallQuery.visible == largeQuery.visible)
        #expect(smallQuery.examined == largeQuery.examined)
        #expect(largeQuery.examined <= 200)

        let clock = ContinuousClock()
        let iterations = 200
        let smallTime = clock.measure { for _ in 0 ..< iterations { _ = small.visible(in: view) } }
        let largeTime = clock.measure { for _ in 0 ..< iterations { _ = large.visible(in: view) } }
        let scanTime = clock.measure { for _ in 0 ..< iterations { _ = WalkedOverlay.visible(nearby + elsewhere, in: view) } }
        print("block-zoom settle culling per call: 100 runs \(smallTime / iterations), 5,000 runs \(largeTime / iterations), full scan of 5,000 \(scanTime / iterations)")
    }

    /// protects: nothing the map draws changes while the camera moves, and a
    /// settle with unchanged data and an unchanged view changes nothing and
    /// keeps every run's `MKPolyline` object (no overlay removed and
    /// re-added); a settle over a different view swaps only the runs it must.
    /// fails_when: a mid-gesture data change rewrites the display, or a
    /// repeated settle replaces equal runs or reports a change.
    /// no_claim: that MapKit diffs by object identity (on-device check).
    @Test func displayChangesOnlyAtRestAndKeepsPolylineObjects() {
        let runs = Self.lattice(count: 40, firstID: 1, x: -150, y: -150)
        let index = WalkedRunIndex(runs: runs)
        let view = Self.region(x: 0, y: 0, height: 400)
        var display = WalkedOverlayDisplay()

        let changed1 = display.refresh(index: index, showsOverlay: true, region: view, visibleHeightMeters: 350, isCameraMoving: true)
        #expect(changed1 == false)
        #expect(display == WalkedOverlayDisplay())

        let changed2 = display.refresh(index: index, showsOverlay: true, region: view, visibleHeightMeters: 350, isCameraMoving: false)
        #expect(changed2)
        guard case .runs(let first) = display.visible else {
            Issue.record("expected runs")
            return
        }
        #expect(display.lineWidth == 8)

        let grown = WalkedRunIndex(runs: runs + Self.lattice(count: 10, firstID: 500, x: 0, y: 300))
        let changed3 = display.refresh(index: grown, showsOverlay: true, region: view, visibleHeightMeters: 350, isCameraMoving: true)
        #expect(changed3 == false)
        guard case .runs(let during) = display.visible else { return }
        #expect(zip(first, during).allSatisfy { $0.polyline === $1.polyline })

        let changed4 = display.refresh(index: index, showsOverlay: true, region: view, visibleHeightMeters: 350, isCameraMoving: false)
        #expect(changed4 == false)
        guard case .runs(let again) = display.visible else { return }
        #expect(again.count == first.count)
        #expect(zip(first, again).allSatisfy { $0.polyline === $1.polyline })
    }

    /// protects: stroke width by visible height (design D2): 8pt to 400 m,
    /// 5pt to 2 km, 3pt to 8 km, 2pt above, and leaving a band takes 10%
    /// more height than entering it.
    /// fails_when: a band edge is off, or a settle near an edge flips width.
    /// no_claim: how the width looks on device.
    @Test func widthBandsWithHysteresis() {
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 300, current: nil) == 8)
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 400, current: nil) == 8)
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 401, current: nil) == 5)
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 2_000, current: nil) == 5)
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 8_000, current: nil) == 3)
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 8_001, current: nil) == 2)
        // Zooming out from 8pt: holds to 440 m.
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 430, current: 8) == 8)
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 441, current: 8) == 5)
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 2_150, current: 5) == 5)
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 2_250, current: 5) == 3)
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 8_700, current: 3) == 3)
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 8_900, current: 3) == 2)
        // Zooming in takes the thicker band at once.
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 390, current: 5) == 8)
        #expect(WalkedOverlay.lineWidth(visibleHeightMeters: 1_900, current: 3) == 5)
    }

    /// protects: the stroke is the `walked` asset: indigo #5856D6 light,
    /// #7D7AFF dark, with Increase Contrast slots, never the cat's orange
    /// (design D1, AC10).
    /// fails_when: the asset is missing, its values drift, or it matches
    /// `catPin`.
    /// no_claim: that MapScreenView strokes with it (QA reads the map).
    @MainActor @Test func walkedColorIsIndigoNotOrange() throws {
        let walked = try #require(UIColor(named: "walked", in: Bundle(for: StreetGrid.self), compatibleWith: nil))
        let catPin = try #require(UIColor(named: "catPin", in: Bundle(for: StreetGrid.self), compatibleWith: nil))
        func hex(_ color: UIColor, _ traits: UITraitCollection) -> String {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        }
        func traits(_ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) -> UITraitCollection {
            UITraitCollection { mutable in
                mutable.userInterfaceStyle = style
                mutable.accessibilityContrast = contrast
            }
        }
        let light = traits(.light, .normal)
        let dark = traits(.dark, .normal)
        let lightContrast = traits(.light, .high)
        let darkContrast = traits(.dark, .high)
        #expect(hex(walked, light) == "5856D6")
        #expect(hex(walked, dark) == "7D7AFF")
        #expect(hex(walked, lightContrast) == "3634A3")
        #expect(hex(walked, darkContrast) == "A5A3FF")
        #expect(hex(walked, light) != hex(catPin, light))
        #expect(hex(walked, dark) != hex(catPin, dark))
    }
}
