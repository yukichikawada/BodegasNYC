//
//  FontDisplayTests.swift
//  BodegasNYCTests
//
//  The DESIGN.md D5 display register helper.
//
//  protects: the display register stays SF Pro heavy, condensed width.
//  fails_when: the helper's weight or width drifts from D5.
//  no_claim: which views use it; QA screenshots cover rendering.
//

import SwiftUI
import Testing

@testable import BodegasNYC

struct FontDisplayTests {
    @Test(arguments: [Font.TextStyle.largeTitle, .title, .headline])
    func displayIsHeavyCondensed(style: Font.TextStyle) {
        #expect(Font.display(style) == .system(style, weight: .heavy).width(.condensed))
    }

    @Test func displayDiffersFromBoldStandardWidth() {
        #expect(Font.display(.largeTitle) != .largeTitle.bold())
    }
}
