//
//  OnboardingLayoutTests.swift
//  BodegasNYCTests
//
//  The onboarding pages' top-inset rule: DD1's 25% of the height in the
//  regular case, a small fixed inset at accessibility Dynamic Type sizes
//  or in compact height (landscape).
//
//  protects: the symbol and title stay on screen at rest when the pinned
//  buttons are tall (accessibility sizes) or the screen is short.
//  fails_when: the regular case stops being 25%, or either crowded case
//  falls back to the proportional inset.
//  no_claim: rendering; QA screenshots cover how it looks.
//

import CoreGraphics
import Testing

@testable import BodegasNYC

@MainActor
struct OnboardingLayoutTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let isAccessibilitySize: Bool
        let isCompactHeight: Bool
        let expected: CGFloat

        var testDescription: String {
            "accessibilitySize=\(isAccessibilitySize) compactHeight=\(isCompactHeight)"
        }
    }

    private static let height: CGFloat = 800

    @Test(arguments: [
        Case(isAccessibilitySize: false, isCompactHeight: false, expected: 200),
        Case(isAccessibilitySize: true, isCompactHeight: false, expected: OnboardingView.compactTopInset),
        Case(isAccessibilitySize: false, isCompactHeight: true, expected: OnboardingView.compactTopInset),
        Case(isAccessibilitySize: true, isCompactHeight: true, expected: OnboardingView.compactTopInset)
    ])
    func topInset(_ testCase: Case) {
        let inset = OnboardingView.topInset(
            height: Self.height,
            isAccessibilitySize: testCase.isAccessibilitySize,
            isCompactHeight: testCase.isCompactHeight
        )
        #expect(inset == testCase.expected)
    }

    @Test func compactInsetIsSixteenPoints() {
        #expect(OnboardingView.compactTopInset == 16)
    }
}
