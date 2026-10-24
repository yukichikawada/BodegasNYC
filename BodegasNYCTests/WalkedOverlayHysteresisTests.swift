//
//  WalkedOverlayHysteresisTests.swift
//  BodegasNYCTests
//
//  Culling hysteresis for the walked layer (#113 item 1): lines already on
//  the map stay while they meet the region + 75%, new lines enter only inside
//  the region + 25%, the over-cap decision is the inner set's alone, and at
//  most 1,000 lines are drawn.
//

import Foundation
import Testing

@testable import BodegasNYC

struct WalkedOverlayHysteresisTests {
    private typealias F = StreetFixtures

    /// Short runs on a `spacing` metre lattice from `(x, y)`, ids from `firstID`.
    private static func lattice(count: Int, firstID: UInt32, x: Double, y: Double, spacing: Double = 50) -> [WalkedRun] {
        let side = Int(Double(count).squareRoot().rounded(.up))
        return (0 ..< count).map { index in
            let px = x + Double(index % side) * spacing
            let py = y + Double(index / side) * spacing
            return WalkedRun(id: firstID + UInt32(index), coordinates: [F.coordinate(x: px, y: py), F.coordinate(x: px + 20, y: py)])
        }
    }

    private static func region(x: Double, y: Double, height: Double) -> WalkedRegion {
        WalkedPanReplay.region(center: F.coordinate(x: x, y: y), height: height)
    }

    private static func run(_ id: UInt32, x: Double, y: Double) -> WalkedRun {
        WalkedRun(id: id, coordinates: [F.coordinate(x: x, y: y), F.coordinate(x: x + 10, y: y)])
    }

    /// protects: a line already drawn stays while its box meets the region
    /// + 75%, a line not drawn enters only inside the region + 25%, and a
    /// line past + 75% is removed (#113 item 1).
    /// fails_when: a small pan removes a line still within the retain margin,
    /// a new line enters from the retain band, or a far line is kept.
    /// no_claim: what MapKit does with the overlays (device check).
    @Test func drawnLinesStayInsideTheRetainMargin() {
        // A 1 km tall region at the origin: inner bound 750 m north of the
        // centre, retain bound 1,250 m.
        let runs = [Self.run(1, x: 0, y: 0), Self.run(2, x: 0, y: 700), Self.run(3, x: 0, y: 1_000), Self.run(4, x: 0, y: 1_400)]
        let index = WalkedRunIndex(runs: runs)
        let view = Self.region(x: 0, y: 0, height: 1_000)
        #expect(index.visible(in: view) == .runs([runs[0], runs[1]]))
        // Nothing drawn before: the band between + 25% and + 75% stays empty.
        #expect(index.visible(in: view, keeping: .runs([])) == .runs([runs[0], runs[1]]))
        // Everything drawn before: 3 (at 1,000 m) stays, 4 (1,400 m) goes.
        #expect(index.visible(in: view, keeping: .runs(runs)) == .runs([runs[0], runs[1], runs[2]]))
        // After over-cap nothing is on the map, so nothing is retained.
        #expect(index.visible(in: view, keeping: .overCap) == .runs([runs[0], runs[1]]))
        // A retain margin at or under the inner one is origin/main's culling.
        #expect(index.visible(in: view, keeping: .runs(runs), retainMargin: WalkedOverlay.regionMargin) == index.visible(in: view))
    }

    /// protects: retention reads the current data: a cleared history or a
    /// deleted run is not kept, a run whose geometry changed is drawn with
    /// its new geometry and `MKPolyline`, Show on Map off empties the layer,
    /// and the width (design D2) still follows the visible height at every
    /// settle (#113: hysteresis is only about which offscreen lines stay).
    /// fails_when: a stale run object survives a data change, Clear leaves a
    /// line, or the width stops changing while lines are retained.
    /// no_claim: how MapKit draws the swap (no fade since #113, D10).
    @Test func dataAndWidthChangesStillApplyFully() {
        let near = Self.run(1, x: 0, y: 0)
        let band = Self.run(2, x: 0, y: 1_000)
        let index = WalkedRunIndex(runs: [near, band])
        var display = WalkedOverlayDisplay()
        display.refresh(index: index, showsOverlay: true, region: Self.region(x: 0, y: 500, height: 1_000), visibleHeightMeters: 1_000, isCameraMoving: false)
        #expect(display.visible == .runs([near, band]))
        #expect(display.lineWidth == 5)

        // Pan south: `band` (1,000 m north) is now in the retain band and
        // stays, and the width still follows the height (350 m: 8pt).
        display.refresh(index: index, showsOverlay: true, region: Self.region(x: 0, y: 0, height: 1_000), visibleHeightMeters: 350, isCameraMoving: false)
        #expect(display.visible == .runs([near, band]))
        #expect(display.lineWidth == 8)

        // The retained run's geometry changes: the new run object is drawn.
        let moved = WalkedRun(id: 2, coordinates: [F.coordinate(x: 0, y: 1_000), F.coordinate(x: 30, y: 1_010)])
        display.refresh(index: WalkedRunIndex(runs: [near, moved]), showsOverlay: true, region: Self.region(x: 0, y: 0, height: 1_000), visibleHeightMeters: 350, isCameraMoving: false)
        guard case .runs(let drawn) = display.visible else {
            Issue.record("expected runs")
            return
        }
        #expect(drawn.map(\.id) == [1, 2])
        #expect(drawn.last?.polyline === moved.polyline)

        // The retained run is deleted from the data: it goes.
        display.refresh(index: WalkedRunIndex(runs: [near]), showsOverlay: true, region: Self.region(x: 0, y: 0, height: 1_000), visibleHeightMeters: 350, isCameraMoving: false)
        #expect(display.visible == .runs([near]))

        // Show on Map off, then on again: nothing is retained across it.
        display.refresh(index: index, showsOverlay: false, region: Self.region(x: 0, y: 0, height: 1_000), visibleHeightMeters: 350, isCameraMoving: false)
        #expect(display.visible == .runs([]))
        display.refresh(index: index, showsOverlay: true, region: Self.region(x: 0, y: 0, height: 1_000), visibleHeightMeters: 350, isCameraMoving: false)
        #expect(display.visible == .runs([near]))

        // Clear History: an empty index draws nothing.
        display.refresh(index: .empty, showsOverlay: true, region: Self.region(x: 0, y: 0, height: 1_000), visibleHeightMeters: 350, isCameraMoving: false)
        #expect(display.visible == .runs([]))
    }

    /// protects: the over-cap decision (design D3) is the inner set's alone:
    /// retained lines never push a view over 1,000, every inner line is drawn
    /// (never a subset), and when inner plus retained would pass 1,000 the
    /// retained lines farthest from the centre give way first, so at most
    /// 1,000 lines are drawn.
    /// fails_when: retention flips the layer to hidden, drops an inner line,
    /// draws more than 1,000, or keeps a far retained line over a near one.
    /// no_claim: the frame rate at 1,000 lines (device check).
    @Test func retentionNeverChangesTheCapAndFillsOnlyTheRoomLeft() {
        // 1,600 runs on a 50 m lattice, 40 x 40, from (0, 0) to (1,950, 1,950).
        let runs = Self.lattice(count: 1_600, firstID: 1, x: 0, y: 0)
        let index = WalkedRunIndex(runs: runs)
        // A 1.2 km tall view centred on the lattice: inner box 1.8 km x
        // 830 m, about 600 runs; its retain band reaches the rest.
        let wide = Self.region(x: 975, y: 975, height: 1_200)
        guard case .runs(let inner) = index.visible(in: wide) else {
            Issue.record("the centred view should draw")
            return
        }
        #expect(inner.count < WalkedOverlay.maxVisibleRuns)
        // Previously everything was drawn (as if from a looser earlier
        // view): inner + retained candidates exceed 1,000.
        let next = index.visible(in: wide, keeping: .runs(runs))
        guard case .runs(let drawn) = next else {
            Issue.record("retention must not hide the layer")
            return
        }
        #expect(drawn.count == WalkedOverlay.maxVisibleRuns)
        let drawnIDs = Set(drawn.map(\.id))
        #expect(Set(inner.map(\.id)).isSubset(of: drawnIDs))
        let outer = WalkedOverlay.expandedBounds(wide, margin: WalkedOverlay.retainMargin)
        let candidates = runs.filter { WalkedOverlay.meets($0, outer) && !inner.contains($0) }
        #expect(inner.count + candidates.count > WalkedOverlay.maxVisibleRuns)
        let kept = candidates.filter { drawnIDs.contains($0.id) }.map { WalkedOverlay.distance(of: $0, from: wide) }
        let dropped = candidates.filter { !drawnIDs.contains($0.id) }.map { WalkedOverlay.distance(of: $0, from: wide) }
        #expect(!dropped.isEmpty)
        #expect((kept.max() ?? 0) <= (dropped.min() ?? .infinity))
        #expect(drawn.map(\.id) == drawn.map(\.id).sorted())

        // Over the cap on the inner set: hidden whatever was drawn before.
        let citywide = Self.region(x: 975, y: 975, height: 6_000)
        #expect(index.visible(in: citywide) == .overCap)
        #expect(index.visible(in: citywide, keeping: .runs(Array(runs.prefix(10)))) == .overCap)
    }

    /// protects: on a replayed pan session, hysteresis makes exactly the
    /// same draw-or-hide decision as origin/main at every settle, draws every
    /// line origin/main draws, never more than 1,000, and nothing past the
    /// retain margin; on the 5,000-block seed it asks MapKit to add and
    /// remove fewer lines in total and on pans. Prints old vs new churn
    /// (total, p95, max per settle; pans and zoom steps apart) and drawn
    /// counts for 0.5 and 0.75 retain margins, and attaches them to the
    /// result bundle. The dense synthetic set only checks the decisions:
    /// there churn at cap crossings is expected to rise (more lines drawn
    /// before the layer hides).
    /// fails_when: a settle hides or shows differently, drops an inner line,
    /// passes 1,000 or draws a far line, or seed churn (total or pans) does
    /// not fall.
    /// no_claim: milliseconds on device; MapKit's per-overlay cost is only
    /// assumed to scale with the lines changed (the #113 trace says so).
    @Test func replayedPansChurnLessWithIdenticalCapDecisions() {
        let seed = WalkedPanReplay.seedIndex
        #expect(seed.runs.count > 100, "bundled grid seed")
        // A denser synthetic set whose views cross the 1,000 cap, so the cap
        // and room-filling paths are replayed too.
        let dense = WalkedRunIndex(runs: Self.lattice(count: 4_000, firstID: 1, x: 0, y: 0))
        for (name, index) in [("seed", seed), ("dense", dense)] {
            var oldChurn: [Int] = []
            var newChurn: [Int] = []
            var halfChurn: [Int] = []
            var oldDrawn: [Int] = []
            var newDrawn: [Int] = []
            var halfDrawn: [Int] = []
            var zoomSteps: [Bool] = []
            var overCapSettles = 0
            for scriptSeed in UInt64(1) ... 5 {
                let regions = WalkedPanReplay.script(over: index, seed: scriptSeed)
                #expect(regions.count == 69)
                let old = WalkedPanReplay.replay(regions, index: index, retainMargin: WalkedOverlay.regionMargin)
                let new = WalkedPanReplay.replay(regions, index: index, retainMargin: WalkedOverlay.retainMargin)
                let half = WalkedPanReplay.replay(regions, index: index, retainMargin: 0.5)
                for step in regions.indices {
                    #expect(old[step].visible == index.visible(in: regions[step]))
                    #expect((new[step].visible == .overCap) == (old[step].visible == .overCap), "\(name) script \(scriptSeed) settle \(step)")
                    #expect(WalkedPanReplay.ids(old[step].visible).isSubset(of: WalkedPanReplay.ids(new[step].visible)))
                    #expect(new[step].drawnCount <= WalkedOverlay.maxVisibleRuns)
                    if case .runs(let drawn) = new[step].visible {
                        let outer = WalkedOverlay.expandedBounds(regions[step], margin: WalkedOverlay.retainMargin)
                        #expect(drawn.allSatisfy { WalkedOverlay.meets($0, outer) })
                    }
                    if old[step].visible == .overCap { overCapSettles += 1 }
                }
                // The first settle (an empty map filling) is not a pan.
                oldChurn += old.dropFirst().map(\.churn)
                newChurn += new.dropFirst().map(\.churn)
                halfChurn += half.dropFirst().map(\.churn)
                zoomSteps += regions.indices.dropFirst().map { regions[$0].latitudeDelta != regions[$0 - 1].latitudeDelta }
                oldDrawn += old.map(\.drawnCount)
                newDrawn += new.map(\.drawnCount)
                halfDrawn += half.map(\.drawnCount)
            }
            /// All settles, then pans and zoom steps apart.
            func line(_ label: String, _ churn: [Int], _ drawn: [Int]) -> String {
                let all = WalkedPanReplay.summary(churn)
                let pans = WalkedPanReplay.summary(zip(churn, zoomSteps).filter { !$0.1 }.map(\.0))
                let zooms = WalkedPanReplay.summary(zip(churn, zoomSteps).filter(\.1).map(\.0))
                return "[#113 churn] \(name) \(label): all total \(all.total) p95 \(all.p95) max \(all.max);"
                    + " pans total \(pans.total) p95 \(pans.p95) max \(pans.max);"
                    + " zooms total \(zooms.total) p95 \(zooms.p95) max \(zooms.max);"
                    + " drawn mean \(drawn.reduce(0, +) / drawn.count) max \(drawn.max() ?? 0)"
            }
            let report = [
                "[#113 churn] \(name): \(index.runs.count) runs, \(oldChurn.count) settles over 5 scripts"
                    + " (\(zoomSteps.filter { $0 }.count) zoom steps), \(overCapSettles) over cap",
                line("origin/main +25%", oldChurn, oldDrawn),
                line("retain +50%", halfChurn, halfDrawn),
                line("retain +75% (ship)", newChurn, newDrawn)
            ].joined(separator: "\n")
            print(report)
            // The console of a simulator run is not in the log; the
            // attachment is (`xcresulttool export attachments`).
            Attachment.record(report, named: "113-churn-\(name).txt")
            if name == "seed" {
                #expect(newChurn.reduce(0, +) < oldChurn.reduce(0, +))
                let pans = { (churn: [Int]) in zip(churn, zoomSteps).filter { !$0.1 }.map(\.0).reduce(0, +) }
                #expect(pans(newChurn) < pans(oldChurn))
            } else {
                #expect(overCapSettles > 0, "the dense replay must cross the cap")
            }
        }
    }
}
