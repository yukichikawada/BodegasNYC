//
//  MapBottomCardTests.swift
//  BodegasNYCTests
//
//  The map's bottom slot precedence (eng review R5, design DD7):
//  placement bar > first-add card > bodega empty state > add tip >
//  streets banner, plus the two pure inputs MapScreenView feeds it.
//
//  protects: at most one card, the right one, and none while placing; the
//  nearby/all banners only on a zero-row load, never when a filter hides
//  pins; the streets banner hidden once closed.
//  fails_when: any row of the precedence table resolves differently.
//  no_claim: rendering, transitions, or that MapScreenView passes the
//  right live values (QA checks that on the simulator).
//

import SwiftUI
import Testing

@testable import BodegasNYC

@MainActor
struct MapBottomCardTests {
    private typealias Card = MapBottomCard

    private static let firstAdd = MapBottomCard.FirstAdd(hasCat: true)

    @Test func placingHidesEveryCard() {
        let content = Card.select(
            isPlacing: true,
            firstAdd: Self.firstAdd,
            emptyState: .noBodegas,
            addTip: true,
            streets: true
        )
        #expect(content == nil)
    }

    @Test func nothingApplicableShowsNoCard() {
        let content = Card.select(isPlacing: false, firstAdd: nil, emptyState: nil, addTip: false, streets: false)
        #expect(content == nil)
    }

    @Test func firstAddOutranksEverythingButPlacement() {
        let content = Card.select(
            isPlacing: false,
            firstAdd: Self.firstAdd,
            emptyState: .noneNearby,
            addTip: true,
            streets: true
        )
        #expect(content == .firstAdd(Self.firstAdd))
    }

    @Test(arguments: [MapBottomCard.EmptyState.noneNearby, .noBodegas, .noFilterMatches])
    func bodegaEmptyStateOutranksTheTipAndStreets(_ state: MapBottomCard.EmptyState) {
        let content = Card.select(isPlacing: false, firstAdd: nil, emptyState: state, addTip: true, streets: true)
        #expect(content == .emptyState(state))
    }

    @Test func addTipOutranksStreets() {
        let content = Card.select(isPlacing: false, firstAdd: nil, emptyState: nil, addTip: true, streets: true)
        #expect(content == .addTip)
    }

    @Test func streetsBannerShowsWhenNothingElseDoes() {
        let content = Card.select(isPlacing: false, firstAdd: nil, emptyState: nil, addTip: false, streets: true)
        #expect(content == .emptyState(.noStreets))
    }

    // MARK: bodegaEmptyState

    @Test func zeroRowLoadInNearbyIsNoneNearby() {
        let state = Card.bodegaEmptyState(browseMode: .nearby, isLoadedEmpty: true, isFilteredEmpty: false)
        #expect(state == .noneNearby)
    }

    /// protects: an empty nearby load at block zoom names the block and the
    /// pinch (#84 design D3); above block zoom it stays `noneNearby`, and
    /// all-mode keeps `noBodegas` at any zoom.
    /// fails_when: block zoom shows "Nothing near you yet.", or the block
    /// card shows above block zoom or in all-mode.
    /// no_claim: that `MapScreenView` passes the live block-zoom verdict, or
    /// the slot transition (live QA).
    @Test func zeroRowLoadInNearbyAtBlockZoomIsNoneOnBlock() {
        #expect(Card.bodegaEmptyState(browseMode: .nearby, isLoadedEmpty: true, isFilteredEmpty: false, isBlockZoom: true)
            == .noneOnBlock)
        #expect(Card.bodegaEmptyState(browseMode: .nearby, isLoadedEmpty: true, isFilteredEmpty: false, isBlockZoom: false)
            == .noneNearby)
        #expect(Card.bodegaEmptyState(browseMode: .all, isLoadedEmpty: true, isFilteredEmpty: false, isBlockZoom: true)
            == .noBodegas)
        #expect(Card.select(isPlacing: false, firstAdd: nil, emptyState: .noneOnBlock, addTip: true, streets: true)
            == .emptyState(.noneOnBlock))
    }

    @Test func zeroRowLoadInAllIsNoBodegas() {
        let state = Card.bodegaEmptyState(browseMode: .all, isLoadedEmpty: true, isFilteredEmpty: false)
        #expect(state == .noBodegas)
    }

    @Test(arguments: [BrowseMode.all, .nearby])
    func filterHidingEveryPinIsNoFilterMatchesNeverANothingHereBanner(_ mode: BrowseMode) {
        let state = Card.bodegaEmptyState(browseMode: mode, isLoadedEmpty: false, isFilteredEmpty: true)
        #expect(state == .noFilterMatches)
    }

    @Test(arguments: [BrowseMode.all, .nearby])
    func loadedWithVisiblePinsHasNoBodegaBanner(_ mode: BrowseMode) {
        let state = Card.bodegaEmptyState(browseMode: mode, isLoadedEmpty: false, isFilteredEmpty: false)
        #expect(state == nil)
    }

    // MARK: usesStackedLayout (QA bug 1: AX sizes overflowed the grid)

    @Test(arguments: [DynamicTypeSize.xSmall, .large, .xxxLarge])
    func standardSizesUseTheGrid(_ size: DynamicTypeSize) {
        #expect(!Card.usesStackedLayout(for: size))
    }

    @Test(arguments: [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5])
    func accessibilitySizesStack(_ size: DynamicTypeSize) {
        #expect(Card.usesStackedLayout(for: size))
    }

    // MARK: showsStreetsBanner

    @Test func streetsBannerNeedsTrackingOnNoPolylinesAndNotDismissed() {
        #expect(Card.showsStreetsBanner(isTrackingEnabled: true, hasPolylines: false, isDismissed: false))
        #expect(!Card.showsStreetsBanner(isTrackingEnabled: false, hasPolylines: false, isDismissed: false))
        #expect(!Card.showsStreetsBanner(isTrackingEnabled: true, hasPolylines: true, isDismissed: false))
        #expect(!Card.showsStreetsBanner(isTrackingEnabled: true, hasPolylines: false, isDismissed: true))
    }

    @Test func streetsBannerYieldsToABodegaBanner() {
        let streets = Card.showsStreetsBanner(isTrackingEnabled: true, hasPolylines: false, isDismissed: false)
        let content = Card.select(
            isPlacing: false,
            firstAdd: nil,
            emptyState: Card.bodegaEmptyState(browseMode: .all, isLoadedEmpty: true, isFilteredEmpty: false),
            addTip: false,
            streets: streets
        )
        #expect(content == .emptyState(.noBodegas))
    }
}
