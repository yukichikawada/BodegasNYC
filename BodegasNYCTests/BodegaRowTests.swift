//
//  BodegaRowTests.swift
//  BodegasNYCTests
//
//  `BodegaRow.accessibilityText(name:address:distance:)`, the row's one
//  VoiceOver label (#68, eng D7/D8).
//
//  no_claim (whole suite): that SwiftUI applies the label, the row's layout,
//  or VoiceOver's speech (QA checks those with Accessibility Inspector).
//

import Testing

@testable import BodegasNYC

struct BodegaRowTests {
    /// protects: name, address, then the distance sentence, in that order.
    /// fails_when: the distance reads before the address, or reads as the
    /// row's short value ("2 blocks") instead of the sentence.
    @Test func readsNameAddressThenDistanceSentence() {
        let text = BodegaRow.accessibilityText(name: "Deli", address: "1 Main St", distance: .blocks(2))
        #expect(text == "Deli, 1 Main St, 2 blocks from you.")
    }

    /// protects: without a distance the label is the pre-#68 reading (eng D8).
    /// fails_when: a trailing separator or placeholder text is spoken.
    @Test func withoutDistanceReadsNameAndAddress() {
        #expect(BodegaRow.accessibilityText(name: "Name", address: "address", distance: nil) == "Name, address")
    }

    /// protects: a bodega with no address still reads cleanly.
    /// fails_when: an empty or missing address leaves a double separator.
    @Test func withoutAddressSkipsIt() {
        #expect(BodegaRow.accessibilityText(name: "Deli", address: nil, distance: .aroundTheCorner)
            == "Deli, Around the corner.")
        #expect(BodegaRow.accessibilityText(name: "Deli", address: "", distance: nil) == "Deli")
    }

    /// protects: the label speaks "miles", singular at 1 (design D5/D7).
    /// fails_when: VoiceOver hears "mi" or "1 miles".
    @Test func milesReadAsWords() {
        #expect(BodegaRow.accessibilityText(name: "Deli", address: "1 Main St", distance: .miles(1.0))
            == "Deli, 1 Main St, 1 mile from you.")
        #expect(BodegaRow.accessibilityText(name: "Deli", address: nil, distance: .miles(2450))
            == "Deli, 2,450 miles from you.")
    }
}
