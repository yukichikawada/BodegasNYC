//
//  BrowseModePickerStyleTests.swift
//  BodegasNYCTests
//
//  Which form the browse toolbar's Map/List switch takes, and where
//  (#44, #143, #160).
//
//  protects: 375 pt (SE 3rd generation, 13 mini) and 390 pt (16e, 17e)
//  phones get the compact menu at default text size, so the List tab stays
//  reachable; 402 to 539 pt keep the segmented control; `.xLarge` and up
//  get the menu below 540 pt; an unmeasured width (0) keeps the segmented
//  control; from 540 pt (landscape phones, the Duo's unfolded panel) the
//  switch is the trailing toggle at every text size.
//  fails_when: the width gate is dropped or moved above 402 pt / below
//  390 pt, the Dynamic Type gate stops applying on portrait phones, the
//  trailing threshold moves off 540 pt (a 466 pt folded Duo or 440 pt
//  portrait Pro Max going trailing, or a 540 to 599 pt width staying in the
//  centre), or large text on a wide width falls back to the centre menu.
//  no_claim: rendering. That BrowseView measures its width, that the
//  toolbar shows the chosen form in the chosen slot and in what order is
//  checked by the landscape UI test and on the SE and branch simulators.
//

import CoreGraphics
import SwiftUI
import Testing

@testable import BodegasNYC

struct BrowseModePickerStyleTests {
    @Test(arguments: [CGFloat(320), 375, 390])
    func narrowPhonesGetTheMenu(width: CGFloat) {
        #expect(BrowseModePickerStyle.resolve(dynamicTypeSize: .large, width: width) == .menu)
    }

    @Test(arguments: [CGFloat(402), 430, 440])
    func widePhonesKeepTheSegmentedControl(width: CGFloat) {
        #expect(BrowseModePickerStyle.resolve(dynamicTypeSize: .large, width: width) == .segmented)
        #expect(BrowseModePickerStyle.resolve(dynamicTypeSize: .xSmall, width: width) == .segmented)
    }

    @Test(arguments: [DynamicTypeSize.xLarge, .xxLarge, .accessibility5])
    func largeTextGetsTheMenuAtAnyWidth(size: DynamicTypeSize) {
        #expect(BrowseModePickerStyle.resolve(dynamicTypeSize: size, width: 402) == .menu)
        #expect(BrowseModePickerStyle.resolve(dynamicTypeSize: size, width: 0) == .menu)
    }

    @Test func unmeasuredWidthKeepsTheSegmentedControl() {
        #expect(BrowseModePickerStyle.resolve(dynamicTypeSize: .large, width: 0) == .segmented)
    }

    // MARK: Wide layouts (#160)

    @Test(arguments: [CGFloat(540), 599, 605, 667, 756, 874])
    func wideWidthsMoveTheSwitchToTheTrailingGroup(width: CGFloat) {
        let style = BrowseModePickerStyle.resolve(dynamicTypeSize: .large, width: width)
        #expect(style == .trailingToggle)
        #expect(style.isInTrailingGroup)
    }

    @Test(arguments: [DynamicTypeSize.xLarge, .accessibility5])
    func largeTextOnWideWidthsStillGetsTheTrailingToggle(size: DynamicTypeSize) {
        #expect(BrowseModePickerStyle.resolve(dynamicTypeSize: size, width: 874) == .trailingToggle)
    }

    @Test(arguments: [CGFloat(402), 440, 466, 539])
    func portraitAndFoldedWidthsKeepTheCentreSlot(width: CGFloat) {
        let style = BrowseModePickerStyle.resolve(dynamicTypeSize: .large, width: width)
        #expect(style == .segmented)
        #expect(!style.isInTrailingGroup)
    }

    @Test func centreFormsAreNotInTheTrailingGroup() {
        #expect(!BrowseModePickerStyle.segmented.isInTrailingGroup)
        #expect(!BrowseModePickerStyle.menu.isInTrailingGroup)
    }
}
