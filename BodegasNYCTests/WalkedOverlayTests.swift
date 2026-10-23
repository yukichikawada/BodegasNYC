//
//  WalkedOverlayTests.swift
//  BodegasNYCTests
//
//  The walked-block overlay's pure rules (#108 spec Implementation 6, AC10;
//  eng R3; design D1-D3).
//

import Foundation
import Testing
import UIKit

@testable import BodegasNYC

struct WalkedOverlayTests {
    private typealias F = StreetFixtures

    /// protects: blocks sharing an endpoint chain into one run keyed by its
    /// first block's physicalid, junctions break runs, and a run's id does
    /// not change when an unrelated block is walked (eng R3).
    /// fails_when: runs are keyed by list position, a straight chain draws
    /// as separate lines, or a run passes through a junction.
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
        #expect(Set(junction.map(\.id)) == [10, 40, 41])

        let withUnrelated = WalkedOverlay.runs(walkedIDs: [10, 20, 30, 90], grid: grid)
        #expect(Set(withUnrelated.map(\.id)) == [10, 90])
        #expect(withUnrelated.first { $0.id == 10 } == chain.first)
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

    /// protects: past 2,000 visible runs nothing is drawn, never a partial
    /// subset (design D3 over eng R3's nearest 2,000); exactly 2,000 draws.
    /// fails_when: the cap draws a subset or hides at 2,000.
    /// no_claim: the frame rate at 2,000 runs (on-device check).
    @Test func overTheCapHidesTheWholeLayer() {
        let region = WalkedRegion(centerLatitude: F.originLatitude, centerLongitude: F.originLongitude, latitudeDelta: 0.1, longitudeDelta: 0.1)
        let runs = (0 ..< 2_001).map {
            WalkedRun(id: UInt32($0), coordinates: [F.coordinate(x: Double($0), y: 0), F.coordinate(x: Double($0), y: 10)])
        }
        guard case .runs(let drawn) = WalkedOverlay.visible(Array(runs.prefix(2_000)), in: region) else {
            Issue.record("2,000 runs should draw")
            return
        }
        #expect(drawn.count == 2_000)
        #expect(WalkedOverlay.visible(runs, in: region) == .overCap)
        let farAway = runs.map { WalkedRun(id: $0.id, coordinates: $0.coordinates.map { Coordinate(latitude: $0.latitude + 1, longitude: $0.longitude) }) }
        #expect(WalkedOverlay.visible(farAway + Array(runs.prefix(5)), in: region) == .runs(Array(runs.prefix(5))))
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
