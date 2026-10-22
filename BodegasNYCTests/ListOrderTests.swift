//
//  ListOrderTests.swift
//  BodegasNYCTests
//
//  The Filters sheet's List Order footer (#81: eng R4, design D2 and D6).
//
//  protects: the footer is exactly one line under Nearest First, chosen by
//  whether the list is nearest-ordered and whether the map can still prompt,
//  and absent under Newest First.
//  fails_when: the sheet claims "Sorted from where you opened the list."
//  while the list is not nearest-ordered, points a denied user at Locate Me,
//  or shows a footer under Newest First.
//  no_claim: that `BrowseView` passes the live values and the footer renders
//  under the section (live QA screenshots); no fixtures or mocks.
//

import Testing

@testable import BodegasNYC

struct ListOrderTests {
    @Test func footerFollowsTheListsRealOrder() {
        #expect(
            ListOrder.sheetFooter(for: .nearest, isNearestOrdered: true, canBePromptedForLocation: false)
                == .listOrderActiveFootnote
        )
        #expect(
            ListOrder.sheetFooter(for: .nearest, isNearestOrdered: false, canBePromptedForLocation: true)
                == .listOrderNeedsLocationBody
        )
        #expect(
            ListOrder.sheetFooter(for: .nearest, isNearestOrdered: false, canBePromptedForLocation: false)
                == .listOrderFallbackBody
        )
        for isNearestOrdered in [true, false] {
            for canPrompt in [true, false] {
                #expect(
                    ListOrder.sheetFooter(
                        for: .newest, isNearestOrdered: isNearestOrdered, canBePromptedForLocation: canPrompt
                    ) == nil
                )
            }
        }
    }
}
