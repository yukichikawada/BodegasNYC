//
//  FontDisplayTests.swift
//  BodegasNYCTests
//
//  The DESIGN.md D5 display register helper.
//
//  protects: the display register stays distinct from DD1's bold title and
//  scales with the text style it is given.
//  fails_when: the helper collapses to `.largeTitle.bold()` or ignores
//  its style argument.
//  no_claim: which views use it; QA screenshots cover rendering.
//

import SwiftUI
import Testing

@testable import BodegasNYC

struct FontDisplayTests {
    @Test func styleArgumentMatters() {
        #expect(Font.display(.headline) != Font.display(.largeTitle))
    }

    @Test func displayDiffersFromBoldStandardWidth() {
        #expect(Font.display(.largeTitle) != .largeTitle.bold())
    }
}
