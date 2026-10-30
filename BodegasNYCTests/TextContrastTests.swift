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
    private static func hex(_ color: UIColor, _ traits: UITraitCollection) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let bytes = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    private static func traits(_ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.accessibilityContrast = contrast
        }
    }

    /// protects: the D6 slot values, each 4.5:1 or better on its surface
    /// (Any 5.99 on white, Dark 4.86 on #2C2C2E, the High Contrast pair higher).
    /// fails_when: a slot is missing (it would fall back to Any) or drifts
    /// from the reviewed value.
    @Test func textMutedResolvesToTheReviewedSlots() {
        let color = UIColor(resource: .textMuted)
        #expect(Self.hex(color, Self.traits(.light, .normal)) == "636366")
        #expect(Self.hex(color, Self.traits(.dark, .normal)) == "98989F")
        #expect(Self.hex(color, Self.traits(.light, .high)) == "545458")
        #expect(Self.hex(color, Self.traits(.dark, .high)) == "AEAEB2")
    }

    /// protects: each of the six points reads its own amenity, in order
    /// (cat, hot food, cigarettes, beer, lotto, ATM), now that the points
    /// are derived from `BodegaFilter.Amenity` (#141 eng D5).
    /// fails_when: any two `isPresent` sources are swapped, a point is
    /// missing or extra, or the order changes. Three fixtures give every
    /// point a distinct present/absent signature across them (cat 100,
    /// hot food 010, cigarettes 001, beer 110, lotto 011, ATM 101); two
    /// fixtures cannot, since two bits only make four signatures. The
    /// expected arrays stay literal, never derived from `Amenity`.
    /// no_claim: the captions or symbols (see the other data point tests).
    @Test func dataPointsReadTheirOwnAmenity() throws {
        let fixtures: [(bodega: Bodega, expected: [Bool])] = [
            (
                try makeTestBodega(hasCat: true, sellsBeer: true, hasAtm: true),
                [true, false, false, true, false, true]
            ),
            (
                try makeTestBodega(servesHotFood: true, sellsBeer: true, sellsLotto: true),
                [false, true, false, true, true, false]
            ),
            (
                try makeTestBodega(sellsCigarettes: true, sellsLotto: true, hasAtm: true),
                [false, false, true, false, true, true]
            )
        ]
        for fixture in fixtures {
            #expect(DataPointsSection.points(for: fixture.bodega).map(\.isPresent) == fixture.expected)
        }
    }

    /// protects: D9's shape plus contrast. Present: `.primary`, no
    /// strikethrough. Absent: not `.primary`, `textMuted`, struck through.
    /// fails_when: an absent point is told apart by color alone, a present
    /// one is muted or struck, or the absent color drifts back to `.primary`.
    /// no_claim: the rendered strikethrough (a property check, not a render);
    /// absent count 4 because #141 made it six points.
    @Test func dataPointStyleFollowsPresence() throws {
        let points = DataPointsSection.points(for: try makeTestBodega(hasCat: true, sellsCigarettes: true))
        let present = points.filter(\.isPresent)
        let absent = points.filter { !$0.isPresent }
        #expect(present.count == 2)
        #expect(absent.count == 4)
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
    /// runtime, so the strikethrough is the absent cue for all six.
    /// fails_when: a symbol name is misspelled, or a future SF Symbols set
    /// adds a `.slash` variant (then switch that point to it, per D9).
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
