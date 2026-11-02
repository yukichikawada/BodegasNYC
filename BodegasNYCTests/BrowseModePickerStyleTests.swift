//
//  BrowseModePickerStyleTests.swift
//  BodegasNYCTests
//
//  Which form the browse toolbar's Map/List switch takes (#44, #143).
//
//  protects: 375 pt (SE 3rd generation, 13 mini) and 390 pt (16e, 17e)
//  phones get the compact menu at default text size, so the List tab stays
//  reachable; 402 pt and wider keep the segmented control; `.xLarge` and up
//  get the menu at any width; an unmeasured width (0) keeps the segmented
//  control.
//  fails_when: the width gate is dropped or moved above 402 pt / below
//  390 pt, or the Dynamic Type gate stops applying on wide phones.
//  no_claim: rendering. That BrowseView measures its width and that the
//  toolbar shows the chosen form is checked on the SE and branch simulators.
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

    @Test(arguments: [CGFloat(402), 430, 440, 667])
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
}
