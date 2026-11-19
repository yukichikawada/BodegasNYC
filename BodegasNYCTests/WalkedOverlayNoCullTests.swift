//
//  WalkedOverlayNoCullTests.swift
//  BodegasNYCTests
//
//  #119: a walked history at or under the settled band's run cap draws
//  whole, whatever the region, so a pan settle changes nothing; a larger one
//  is culled to the view exactly as before.
//

import Foundation
import Testing

@testable import BodegasNYC

struct WalkedOverlayNoCullTests {
    private typealias F = StreetFixtures

    /// Settles at the 3pt line band (cap 1,000).
    private static let lineHeight = 5_000.0
    /// Settles at the 8pt breadcrumb band (cap 500).
    private static let breadcrumbHeight = 350.0

    /// `count` 20 m runs along a street, one every 30 m eastward from
    /// `x` metres, ids from `firstID`: 600 of them span 18 km, far wider
    /// than a block-zoom view.
    private static func street(count: Int, firstID: UInt32 = 1, x: Double = 0) -> [WalkedRun] {
        (0 ..< count).map { index in
            let start = x + Double(index) * 30
            return WalkedRun(id: firstID + UInt32(index), coordinates: [F.coordinate(x: start, y: 0), F.coordinate(x: start + 20, y: 0)])
        }
    }

    /// A phone-shaped region `height` metres tall centred `(x, y)` metres
    /// from the fixture origin.
    private static func region(x: Double, y: Double = 0, height: Double = 400) -> WalkedRegion {
        let center = F.coordinate(x: x, y: y)
        return WalkedRegion(
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            latitudeDelta: height / StreetGrid.metersPerDegreeLatitude,
            longitudeDelta: height * 402 / 874 / (cos(F.originLatitude * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator)
        )
    }

    @discardableResult
    private static func settle(_ display: inout WalkedOverlayDisplay, _ index: WalkedRunIndex, _ region: WalkedRegion, height: Double) -> Bool {
        display.refresh(index: index, showsOverlay: true, region: region, visibleHeightMeters: height, isCameraMoving: false)
    }

    /// The base address of the drawn list's storage, to show it is the
    /// index's own array and not a copy rebuilt at the settle.
    private static func storage(_ runs: [WalkedRun]) -> UnsafeRawPointer? {
        runs.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
    }

    /// protects=#119: under the cap two different regions settle to the same
    /// display, so a pan settle reports no change and writes nothing; the
    /// display holds every run in summary order, including one a degree
    /// away; and the drawn list shares the index's storage (no per-settle
    /// rebuild, so the settle's equality check returns on identity);
    /// fails_when=an under-cap history is culled to the region, a pan settle
    /// reports a change, or the settle copies the run list;
    /// no_claim=that MapKit skips work on an unchanged content list (the
    /// 2026-11-19 device A/B).
    @Test func underTheCapEveryRegionDrawsTheWholeHistory() {
        // A degree north of the street: about 111 km away.
        let far = WalkedRun(id: 90_000, coordinates: [
            Coordinate(latitude: F.originLatitude + 1, longitude: F.originLongitude),
            Coordinate(latitude: F.originLatitude + 1, longitude: F.originLongitude + 0.001)
        ])
        let runs = Self.street(count: 400) + [far]
        let index = WalkedRunIndex(runs: runs)
        for height in [Self.lineHeight, Self.breadcrumbHeight] {
            var display = WalkedOverlayDisplay()
            #expect(Self.settle(&display, index, Self.region(x: 0), height: height))
            #expect(display.visible == .runs(runs))
            let first = display
            // A pan to the far end of the street: nothing changes.
            #expect(Self.settle(&display, index, Self.region(x: 11_000), height: height) == false)
            #expect(display == first)
            guard case .runs(let drawn) = display.visible else {
                Issue.record("expected runs at \(height) m")
                continue
            }
            #expect(drawn.count == 401)
            #expect(drawn.contains { $0.id == 90_000 })
            #expect(Self.storage(drawn) == Self.storage(index.runs))
            // Culling would have kept only a handful.
            if case .runs(let culled) = index.visible(in: Self.region(x: 0), cap: 1_000) {
                #expect(culled.count < 50)
            }
        }
    }

    /// protects=#119: exactly at the band's cap the whole history draws; one
    /// run over, the display is exactly what the culling returned before
    /// #119 (spatial index and full scan alike), at both the line cap
    /// (1,000) and the breadcrumb cap (500);
    /// fails_when=the boundary is off by one, or over-cap culling drifts;
    /// no_claim=the frame rate at the cap (device check).
    @Test func atTheCapDrawsAllAndOneOverCullsAsBefore() {
        for (cap, height) in [(1_000, Self.lineHeight), (500, Self.breadcrumbHeight)] {
            let view = Self.region(x: 600)
            let atCap = WalkedRunIndex(runs: Self.street(count: cap))
            var display = WalkedOverlayDisplay()
            Self.settle(&display, atCap, view, height: height)
            #expect(display.visible == .runs(atCap.runs), "\(cap) runs at \(height) m")

            let overRuns = Self.street(count: cap + 1)
            let over = WalkedRunIndex(runs: overRuns)
            Self.settle(&display, over, view, height: height)
            #expect(display.visible == over.visible(in: view, cap: cap))
            #expect(display.visible == WalkedOverlay.visible(overRuns, in: view, cap: cap))
            guard case .runs(let culled) = display.visible else {
                Issue.record("a block-zoom view of \(cap + 1) runs should cull, not hide")
                continue
            }
            #expect(!culled.isEmpty && culled.count < 50)
        }
    }

    /// protects=#119 band rule: a 600-run history draws whole at a line
    /// width and is culled at a breadcrumb width; crossing back and forth
    /// swaps the whole list at that settle (no stale runs from the other
    /// band), and the same band settles to the same display again;
    /// fails_when=the cap ignores the settled width, or a band change keeps
    /// the other band's list;
    /// no_claim=how MapKit applies the swap (device A/B: no hitch above a
    /// frame at a band change).
    @Test func sixHundredRunsDrawWholeAsALineAndCullAsBreadcrumbs() {
        let runs = Self.street(count: 600)
        let index = WalkedRunIndex(runs: runs)
        let view = Self.region(x: 3_000)
        var display = WalkedOverlayDisplay()

        #expect(Self.settle(&display, index, view, height: Self.lineHeight))
        #expect(display.lineWidth == 3)
        #expect(display.visible == .runs(runs))
        let asLine = display

        #expect(Self.settle(&display, index, view, height: Self.breadcrumbHeight))
        #expect(display.lineWidth == 8)
        #expect(display.visible == index.visible(in: view, cap: 500))
        guard case .runs(let culled) = display.visible else {
            Issue.record("a block-zoom view should cull, not hide")
            return
        }
        #expect(!culled.isEmpty && culled.count < 50)

        #expect(Self.settle(&display, index, view, height: Self.lineHeight))
        #expect(display == asLine)

        // The whole street in a breadcrumb view is over 500: the card, as before.
        let wide = Self.region(x: 9_000, height: 30_000)
        Self.settle(&display, index, wide, height: Self.breadcrumbHeight)
        #expect(display.visible == .overCap)
    }

    /// protects=#119 with the over-cap card's rules: under the cap the card
    /// never trips, even in a view holding every run at the breadcrumb band;
    /// over it, the card and the width bands' 10% hysteresis behave as
    /// before: 700 runs in view stay hidden at 2,100 m while 5pt
    /// breadcrumbs hold, and draw as a line once the band lets go at 2,250 m;
    /// fails_when=an under-cap history shows the card, or #119 changes when
    /// an over-cap history hides;
    /// no_claim=the card's layout (MapBottomCardTests).
    @Test func overCapCardAndHysteresisUnchanged() {
        // Holds the whole 700-run street (21 km) with its margin.
        let wide = Self.region(x: 10_000, height: 40_000)
        let under = WalkedRunIndex(runs: Self.street(count: 500))
        var display = WalkedOverlayDisplay()
        for height in [350.0, 430, 1_000, 2_100, 2_250, 5_000, 9_000, 20_000] {
            Self.settle(&display, under, wide, height: height)
            #expect(display.visible == .runs(under.runs), "500 runs at \(height) m")
        }

        let over = WalkedRunIndex(runs: Self.street(count: 700))
        display = WalkedOverlayDisplay()
        Self.settle(&display, over, wide, height: 1_500)
        #expect(display.lineWidth == 5)
        #expect(display.visible == .overCap)
        Self.settle(&display, over, wide, height: 2_100)
        #expect(display.lineWidth == 5)
        #expect(display.visible == .overCap)
        Self.settle(&display, over, wide, height: 2_250)
        #expect(display.lineWidth == 3)
        #expect(display.visible == .runs(over.runs))
        // Zooming back in takes the breadcrumb band, and its cap, at once.
        Self.settle(&display, over, wide, height: 1_900)
        #expect(display.lineWidth == 5)
        #expect(display.visible == .overCap)
    }

    /// protects=#119 with a walk in progress: a history that grows past the
    /// cap while the map is open keeps its display through the gesture, then
    /// switches from the whole history to culling at the next settle, and to
    /// the card when the view holds more than the cap; when it shrinks back
    /// (Clear History, a smaller reload) the next settle draws it whole again;
    /// fails_when=growth rewrites mid-gesture, a stale whole-history list
    /// survives the settle, or the display sticks in either mode;
    /// no_claim=the summary rebuild's own timing (StreetsWalkedViewModelTests).
    @Test func historyGrowingPastTheCapSwitchesToCullingAtTheNextSettle() {
        let view = Self.region(x: 600)
        let small = WalkedRunIndex(runs: Self.street(count: 990))
        var display = WalkedOverlayDisplay()
        Self.settle(&display, small, view, height: Self.lineHeight)
        #expect(display.visible == .runs(small.runs))
        let before = display

        let grown = WalkedRunIndex(runs: Self.street(count: 1_010))
        let moving = display.refresh(index: grown, showsOverlay: true, region: view, visibleHeightMeters: Self.lineHeight, isCameraMoving: true)
        #expect(moving == false)
        #expect(display == before)

        #expect(Self.settle(&display, grown, view, height: Self.lineHeight))
        #expect(display.visible == grown.visible(in: view, cap: 1_000))
        guard case .runs(let culled) = display.visible else {
            Issue.record("a block-zoom view should cull, not hide")
            return
        }
        #expect(culled.count < 50)

        let whole = Self.region(x: 15_000, height: 60_000)
        Self.settle(&display, grown, whole, height: Self.lineHeight)
        #expect(display.visible == .overCap)

        #expect(Self.settle(&display, small, view, height: Self.lineHeight))
        #expect(display.visible == .runs(small.runs))
    }

    /// protects: a nil region or a hidden overlay draws nothing, under the
    /// cap too (#119 changes only the culling);
    /// fails_when=the whole history draws before the camera has a region or
    /// with Show on Map off;
    /// no_claim=when the map first reports a region.
    @Test func noRegionOrHiddenOverlayDrawsNothing() {
        let index = WalkedRunIndex(runs: Self.street(count: 10))
        var display = WalkedOverlayDisplay()
        display.refresh(index: index, showsOverlay: true, region: nil, visibleHeightMeters: Self.lineHeight, isCameraMoving: false)
        #expect(display.visible == .runs([]))
        display.refresh(index: index, showsOverlay: false, region: Self.region(x: 0), visibleHeightMeters: Self.lineHeight, isCameraMoving: false)
        #expect(display.visible == .runs([]))
    }
}
