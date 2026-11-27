//
//  TextContrastTests.swift
//  BodegasNYCTests
//
//  The `textMuted` asset color's four slots and the detail data points'
//  present/absent style (#95 design D6, D9).
//
//  no_claim (whole suite): rendered contrast over real surfaces (measured
//  live from screenshots, recorded in the #95 PR), or that SwiftUI applies
//  the strikethrough.
//

import SwiftUI
import Testing
import UIKit

@testable import BodegasNYC

@MainActor
struct TextContrastTests {
    /// protects: the D6 slot values, each 4.5:1 or better on its surface
    /// (Any 5.99 on white, Dark 4.86 on #2C2C2E, the High Contrast pair higher).
    /// fails_when: a slot is missing (it would fall back to Any) or drifts
    /// from the reviewed value.
    @Test func textMutedResolvesToTheReviewedSlots() {
        let color = UIColor(resource: .textMuted)
        #expect(hexString(color, colorTraits(.light, .normal)) == "636366")
        #expect(hexString(color, colorTraits(.dark, .normal)) == "98989F")
        #expect(hexString(color, colorTraits(.light, .high)) == "545458")
        #expect(hexString(color, colorTraits(.dark, .high)) == "AEAEB2")
    }

    /// protects: each of the seven points reads its own amenity, in order
    /// (cat, hot food, cigarettes, beer, lotto, ATM, bathroom), now that the
    /// points are derived from `BodegaFilter.Amenity` (#141 eng D5; Bathroom
    /// since #194).
    /// fails_when: any two `isPresent` sources are swapped, a point is
    /// missing or extra, or the order changes. Three fixtures give every
    /// point a distinct present/absent signature across them (cat 100,
    /// hot food 010, cigarettes 001, beer 110, lotto 011, ATM 101,
    /// bathroom 111); two fixtures cannot, since two bits only make four
    /// signatures. Three bits make eight, so seven points use every one but
    /// 000; an eighth point would need a fourth fixture. The expected arrays
    /// stay literal, never derived from `Amenity`.
    /// no_claim: the captions or symbols (see the other data point tests).
    @Test func dataPointsReadTheirOwnAmenity() throws {
        let fixtures: [(bodega: Bodega, expected: [Bool])] = [
            (
                try makeTestBodega(hasCat: true, sellsBeer: true, hasAtm: true, hasBathroom: true),
                [true, false, false, true, false, true, true]
            ),
            (
                try makeTestBodega(servesHotFood: true, sellsBeer: true, sellsLotto: true, hasBathroom: true),
                [false, true, false, true, true, false, true]
            ),
            (
                try makeTestBodega(sellsCigarettes: true, sellsLotto: true, hasAtm: true, hasBathroom: true),
                [false, false, true, false, true, true, true]
            )
        ]
        for fixture in fixtures {
            #expect(DataPointsSection.points(for: fixture.bodega).map(\.isPresent) == fixture.expected)
        }
    }

    /// protects: the grid form's shape (#196 DS2): four cells over three, in
    /// amenity order row by row (Cat, Hot Food, Nicotine, Beer, then Lotto,
    /// ATM, Bathroom), with no placeholder for the empty fourth slot.
    /// fails_when: the rows split elsewhere, a point moves rows or columns,
    /// or the short row is padded to four.
    /// no_claim: which form `ViewThatFits` picks at a width (captures and
    /// `testDetailDataPointsUseTheGridWhenTheRowDoesNotFit`), spacing, looks.
    @Test func dataPointGridIsFourOverThreeInAmenityOrder() throws {
        let points = DataPointsSection.points(for: try makeTestBodega())
        let rows = DataPointsSection.gridRows(points)
        #expect(rows.map(\.count) == [4, 3])
        #expect(rows.map { $0.map(\.label.copy.text) } == [
            ["Cat", "Hot Food", "Nicotine", "Beer"],
            ["Lotto", "ATM", "Bathroom"]
        ])
    }

    /// protects: D9's shape plus contrast. Present: `.primary`, no
    /// strikethrough. Absent: not `.primary`, `textMuted`, struck through.
    /// fails_when: an absent point is told apart by color alone, a present
    /// one is muted or struck, or the absent color drifts back to `.primary`.
    /// no_claim: the rendered strikethrough (a property check, not a render);
    /// absent count 5 because #194 made it seven points (#141 made it six).
    @Test func dataPointStyleFollowsPresence() throws {
        let points = DataPointsSection.points(for: try makeTestBodega(hasCat: true, sellsCigarettes: true))
        let present = points.filter(\.isPresent)
        let absent = points.filter { !$0.isPresent }
        #expect(present.count == 2)
        #expect(absent.count == 5)
        for point in present {
            #expect(point.foreground == Color.primary)
            #expect(point.strikesCaption == false)
        }
        for point in absent {
            #expect(point.foreground != Color.primary)
            #expect(point.foreground == Color.textMuted)
            #expect(point.strikesCaption == true)
        }
    }

    /// protects: D9's "slash variant where one exists, else strikethrough"
    /// choice. Every symbol renders and none has a `.slash` variant on this
    /// runtime, so the strikethrough is the absent cue for all seven,
    /// Bathroom's `toilet` included (#194: `toilet.slash` is not used even
    /// if one appears, so the seven read alike).
    /// fails_when: a symbol name is misspelled, `toilet` is missing from the
    /// test runtime's SF Symbols, or a future SF Symbols set adds a `.slash`
    /// variant (then switch that point to it, per D9; for `toilet` the #194
    /// spec says keep the strikethrough, so revisit that decision instead).
    /// no_claim: any runtime but the test script's pinned simulator (iOS
    /// 26.5), so not the owner's phone; how the symbols look at any size.
    @Test func dataPointSymbolsExistWithoutSlashVariants() throws {
        let points = DataPointsSection.points(for: try makeTestBodega())
        for point in points {
            #expect(UIImage(systemName: point.systemImage) != nil, "\(point.systemImage) does not render")
            #expect(
                UIImage(systemName: point.systemImage + ".slash") == nil,
                "\(point.systemImage).slash now exists: switch this point to it (#95 D9) and update DESIGN.md Data points"
            )
        }
    }
}
