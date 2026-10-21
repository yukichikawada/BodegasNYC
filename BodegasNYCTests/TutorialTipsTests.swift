//
//  TutorialTipsTests.swift
//  BodegasNYCTests
//
//  The Add tip's gating (#22, spec AC 13, design DD4) as the pure
//  `TutorialTips.shouldOfferAddTip`, which `AddBodegaTip.rules` mirror and
//  `BrowseView` combines with TipKit's own display verdict.
//
//  protects: the Add tip is offered only after a detail has been opened,
//  and is suppressed during onboarding, in placement mode, and after the
//  first add.
//  fails_when: any suppressed combination returns true, or the one allowed
//  combination returns false.
//  no_claim: TipKit's own rule evaluation, display timing, close handling,
//  or that BrowseView feeds the live values (QA checks those on the branch
//  simulator).
//

import CoreLocation
import Testing

@testable import BodegasNYC

struct TutorialTipsTests {
    private static func offer(
        hasAddedFirstBodega: Bool = false,
        isOnboardingVisible: Bool = false,
        isPlacingBodega: Bool = false,
        hasOpenedDetail: Bool = true
    ) -> Bool {
        TutorialTips.shouldOfferAddTip(
            hasAddedFirstBodega: hasAddedFirstBodega,
            isOnboardingVisible: isOnboardingVisible,
            isPlacingBodega: isPlacingBodega,
            hasOpenedDetail: hasOpenedDetail
        )
    }

    @Test func offeredWhenEveryConditionAllowsIt() {
        #expect(Self.offer())
    }

    @Test func suppressedAfterTheFirstAdd() {
        #expect(!Self.offer(hasAddedFirstBodega: true))
    }

    @Test func suppressedWhileOnboardingIsOnScreen() {
        #expect(!Self.offer(isOnboardingVisible: true))
    }

    @Test func suppressedWhilePlacing() {
        #expect(!Self.offer(isPlacingBodega: true))
    }

    @Test func suppressedUntilADetailHasBeenOpened() {
        #expect(!Self.offer(hasOpenedDetail: false))
    }

    /// The Distances tip (#68, design D4), the pure form of
    /// `DistancesTip.rules` (`canBePromptedForLocation`).
    /// protects: the tip is offered only while Locate Me can still prompt
    /// (`.notDetermined`), never to denied, restricted or authorized users.
    /// fails_when: any status other than `.notDetermined` offers it, or
    /// `.notDetermined` does not.
    /// no_claim: TipKit's close persistence, the `.actionPerformed`
    /// invalidation on the first fix, that `BrowseView` mirrors the live
    /// status, or that the list renders it only with rows (QA checks those).
    @Test func distancesTipOfferedOnlyWhileLocationCanBePrompted() {
        #expect(TutorialTips.shouldOfferDistancesTip(authorizationStatus: .notDetermined))
        #expect(!TutorialTips.shouldOfferDistancesTip(authorizationStatus: .denied))
        #expect(!TutorialTips.shouldOfferDistancesTip(authorizationStatus: .restricted))
        #expect(!TutorialTips.shouldOfferDistancesTip(authorizationStatus: .authorizedWhenInUse))
        #expect(!TutorialTips.shouldOfferDistancesTip(authorizationStatus: .authorizedAlways))
    }

    /// The full 16-row table: true in exactly one row.
    @Test func fullTruthTableAllowsExactlyOneRow() {
        var allowed: [[Bool]] = []
        for added in [false, true] {
            for onboarding in [false, true] {
                for placing in [false, true] {
                    for opened in [false, true] {
                        let result = Self.offer(
                            hasAddedFirstBodega: added,
                            isOnboardingVisible: onboarding,
                            isPlacingBodega: placing,
                            hasOpenedDetail: opened
                        )
                        if result { allowed.append([added, onboarding, placing, opened]) }
                    }
                }
            }
        }
        #expect(allowed == [[false, false, false, true]])
    }
}
