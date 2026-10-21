//
//  BodegaPinViewTests.swift
//  BodegasNYCTests
//
//  The pin's name label truncation (design DD3: one line, tail-truncated
//  at 18 characters).
//
//  protects: names up to 18 characters show whole; longer ones are cut to
//  17 plus an ellipsis, so the label never runs wider than that.
//  fails_when: a short name is cut or a long one isn't.
//  no_claim: rendering, the drop animation, or VoiceOver (QA on the branch
//  simulator).
//

import Testing

@testable import BodegasNYC

struct BodegaPinViewTests {
    @Test func shortNamesShowWhole() {
        #expect(BodegaPinView.labelText(for: "Deli") == "Deli")
        #expect(BodegaPinView.labelText(for: "Eighteen Character") == "Eighteen Character")
    }

    @Test func longNamesAreTailTruncatedAtEighteen() {
        let label = BodegaPinView.labelText(for: "Sunny's Deli & Grocery on Fifth")
        #expect(label == "Sunny's Deli & Gr\u{2026}")
        #expect(label.count == 18)
    }
}
