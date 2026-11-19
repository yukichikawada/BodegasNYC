//
//  SharedWalkTrailTests.swift
//  BodegasNYCTests
//
//  #177 DS1: a walk someone sent you is a solid line at every width band,
//  so where it ever meets your cyan breadcrumbs the two differ in shape,
//  not only colour.
//

import SwiftUI
import Testing
import UIKit

@testable import BodegasNYC

@Suite
@MainActor
struct SharedWalkTrailTests {
    /// protects=DS1's shape rule: `.shared` is a plain line at the band's
    /// own width at 8, 5, 3 and 2 pt, while `.walked` keeps breadcrumbs at
    /// 8 and 5 pt and a line at 3 and 2 pt; fails_when=a shared band draws
    /// breadcrumbs or a track, or yours stops doing so; no_claim=the
    /// rendered stroke (the four violet captures in build/qa-177).
    @Test func sharedIsASolidLineAtEveryBand() {
        for width in [8.0, 5, 3, 2] {
            #expect(WalkedTrail.trailStyle(.shared, width: width) == .line(width: width))
        }
        for width in [8.0, 5] {
            guard case .breadcrumbs = WalkedTrail.trailStyle(.walked, width: width) else {
                Issue.record("yours at \(width) pt is not breadcrumbs")
                continue
            }
        }
        #expect(WalkedTrail.trailStyle(.walked, width: 3) == .line(width: 3))
    }

    /// protects=DS1's colour: the `sharedWalk` asset resolves to #7E22CE
    /// light, #CF8AFF dark, #5A0FA3 and #DDB0FF under Increase Contrast,
    /// and is never the `walked` cyan; fails_when=a slot drifts or the
    /// asset is missing; no_claim=how the violet reads on a map (captures).
    @Test func sharedWalkColourSlots() {
        let color = UIColor(named: "sharedWalk", in: Bundle(for: StreetGrid.self), compatibleWith: nil)
        #expect(color != nil)
        func hex(_ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) -> String {
            let traits = UITraitCollection { traits in
                traits.userInterfaceStyle = style
                traits.accessibilityContrast = contrast
            }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color?.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        }
        #expect(hex(.light, .normal) == "#7E22CE")
        #expect(hex(.dark, .normal) == "#CF8AFF")
        #expect(hex(.light, .high) == "#5A0FA3")
        #expect(hex(.dark, .high) == "#DDB0FF")
    }
}
