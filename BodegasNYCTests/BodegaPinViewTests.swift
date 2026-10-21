//
//  BodegaPinViewTests.swift
//  BodegasNYCTests
//
//  The pin's name label (DESIGN.md Pin, DD3 as amended by #67): when it
//  shows, and how wide placement believes it is.
//
//  The two `labelText(for:)` tests (18-character cut) were replaced in #67:
//  design D3 removed the character cap for a 160pt width cap with tail
//  truncation, so the function they covered no longer exists.
//

import Testing
import UIKit

@testable import BodegasNYC

@MainActor
struct BodegaPinViewTests {
    /// protects: DD3's regression contract: selected (held) and dropping
    /// pins always show their label, at rest a pin shows one only when
    /// block-zoom placement kept it. fails_when: a held or dropping label
    /// depends on placement, or a resting pin shows a label placement did
    /// not choose. no_claim: rendering, the fade, or that `HeldPinView`
    /// passes the right flags (live QA).
    @Test func labelTruthTable() {
        let rows: [(selected: Bool, phase: AddCompletionCoordinator.PinPhase, block: Bool, shows: Bool)] = [
            (false, .atRest, false, false),
            (false, .atRest, true, true),
            (true, .atRest, false, true),
            (true, .atRest, true, true),
            (false, .dropping, false, true),
            (false, .dropping, true, true),
            (false, .pending, false, true)
        ]
        for row in rows {
            let shows = BodegaPinView.showsLabel(isSelected: row.selected, phase: row.phase, showsBlockLabel: row.block)
            #expect(shows == row.shows, "selected \(row.selected), \(row.phase), block \(row.block)")
        }
    }

    /// protects: placement never under-estimates a wide name: the production
    /// measurer for 18 W's is at least the fixed estimate the placement
    /// fixtures use (`PinLabelPlacementTests.testLabelSize`, 156pt), the text
    /// width stops at the 160pt cap plus 12pt padding, Dynamic Type stops at
    /// `.xxLarge`, and the cached size equals a fresh measurement.
    /// fails_when: the measurer ignores the font, the cap, the padding or
    /// the `.xxLarge` clamp, or the cache returns a stale size. no_claim:
    /// that SwiftUI draws the capsule at exactly this size (QA compares the
    /// screenshots), or non-Latin names.
    @Test func measuredLabelSizeBoundsTheEstimate() {
        let wide = String(repeating: "W", count: 18)
        let atDefault = BodegaPinView.measuredLabelSize(for: wide, contentSize: .large)
        let atCap = BodegaPinView.measuredLabelSize(for: wide, contentSize: .extraExtraLarge)
        let atAX5 = BodegaPinView.measuredLabelSize(for: wide, contentSize: .accessibilityExtraExtraExtraLarge)

        #expect(atDefault.width >= 156)
        #expect(atDefault.width <= BodegaPinView.maxLabelWidth + 12)
        #expect(atCap.width == BodegaPinView.maxLabelWidth + 12)
        #expect(atAX5 == atCap)
        #expect(atCap.height > atDefault.height)

        // A ~330pt name is capped like 18 W's: placement and the drawn
        // capsule both stop at 160 + 12.
        let veryLong = "QA67-Sunny & Annie's Gourmet Deli and Grocery on Fifth Avenue"
        #expect(BodegaPinView.measuredLabelSize(for: veryLong, contentSize: .large).width == BodegaPinView.maxLabelWidth + 12)

        let short = BodegaPinView.measuredLabelSize(for: "Deli", contentSize: .large)
        #expect(short.width < atDefault.width)

        let state = PinLabelState()
        #expect(state.labelSize(for: wide, contentSize: .large) == atDefault)
        #expect(state.labelSize(for: wide, contentSize: .large) == atDefault)
        #expect(state.labelSize(for: wide, contentSize: .extraExtraLarge) == atCap)
    }

    /// protects: a cluster badge's obstacle grows with its count and text
    /// size, never under the pin's 32pt, and stops growing at `.xxLarge`.
    /// fails_when: the badge is assumed to be 32pt at every count and size,
    /// or the cache disagrees with a fresh measurement. no_claim: the drawn
    /// badge's exact size (live QA).
    @Test func clusterObstacleGrowsWithTheBadge() {
        let small = ClusterBadge.measuredObstacleSide(count: 3, contentSize: .large)
        let twelveCap = ClusterBadge.measuredObstacleSide(count: 12, contentSize: .extraExtraLarge)
        let twelveAX5 = ClusterBadge.measuredObstacleSide(count: 12, contentSize: .accessibilityExtraExtraExtraLarge)
        let hundreds = ClusterBadge.measuredObstacleSide(count: 120, contentSize: .extraExtraLarge)

        #expect(small == BodegaMapViewModel.itemObstacleSide)
        #expect(twelveCap > BodegaMapViewModel.itemObstacleSide)
        #expect(twelveAX5 == twelveCap)
        #expect(hundreds > twelveCap)
        #expect(PinLabelState().clusterObstacleSide(count: 12, contentSize: .extraExtraLarge) == twelveCap)
    }
}
