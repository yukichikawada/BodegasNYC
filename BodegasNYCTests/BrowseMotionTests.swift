//
//  BrowseMotionTests.swift
//  BodegasNYCTests
//
//  The browse session's pure motion decisions (#23): how the List tab's page
//  moves over the live map, which occupant the map's bottom slot shows and
//  how it moves, and where the placement crosshair sits.
//
//  protects: the list slides (0.3s) by default and fades (0.25s) when either
//  Reduce Motion or Prefer Cross-Fade Transitions is on; placement outranks
//  every bottom card; the slot fades in place under Reduce Motion; the
//  crosshair is centred in the band above the placement card and never sits
//  on or below the card's top edge.
//  fails_when: either accessibility switch alone stops producing the fade or
//  its duration; a card shows while placing, or `.empty` replaces a card;
//  the slot keeps its slide under Reduce Motion; the crosshair centres on the
//  whole map (ignoring the card) or goes negative for a tall card.
//  no_claim: rendering. That BrowseView and MapScreenView read the live
//  accessibility settings, map these values to the right SwiftUI
//  transitions, and measure the real card height is checked by QA
//  recordings on the branch simulator; no fixtures or mocks are involved.
//

import CoreGraphics
import Testing

@testable import BodegasNYC

@MainActor
struct BrowseMotionTests {
    private typealias ListMotion = BrowseMotion.ListTransition
    private typealias Slot = BrowseMotion.BottomSlot

    // MARK: List transition

    struct ListCase: Sendable, CustomTestStringConvertible {
        let reduceMotion: Bool
        let crossFade: Bool

        var testDescription: String { "reduceMotion=\(reduceMotion) crossFade=\(crossFade)" }
    }

    @Test func listSlidesForThreeTenthsByDefault() {
        #expect(ListMotion.style(reduceMotion: false, crossFade: false) == .slide)
        #expect(ListMotion.duration(reduceMotion: false, crossFade: false) == 0.3)
    }

    @Test(arguments: [
        ListCase(reduceMotion: true, crossFade: false),
        ListCase(reduceMotion: false, crossFade: true),
        ListCase(reduceMotion: true, crossFade: true)
    ])
    func listFadesWhenEitherSwitchIsOn(_ testCase: ListCase) {
        #expect(ListMotion.style(reduceMotion: testCase.reduceMotion, crossFade: testCase.crossFade) == .fade)
    }

    @Test(arguments: [
        ListCase(reduceMotion: true, crossFade: false),
        ListCase(reduceMotion: false, crossFade: true)
    ])
    func listFadeTakesAQuarterSecond(_ testCase: ListCase) {
        #expect(ListMotion.duration(reduceMotion: testCase.reduceMotion, crossFade: testCase.crossFade) == 0.25)
    }

    // MARK: Bottom slot

    @Test(arguments: [
        MapBottomCard.Content.firstAdd(MapBottomCard.FirstAdd(hasCat: true)),
        .emptyState(.noBodegas),
        .emptyState(.noFilterMatches),
        .addTip,
        .emptyState(.noStreets)
    ])
    func placingBeatsEveryCard(_ card: MapBottomCard.Content) {
        #expect(Slot.select(isPlacing: true, card: card) == .placing)
    }

    @Test func cardShowsWhenNotPlacing() {
        #expect(Slot.select(isPlacing: false, card: .addTip) == .card(.addTip))
    }

    @Test func slotIsEmptyWithNeitherPlacementNorCard() {
        #expect(Slot.select(isPlacing: false, card: nil) == .empty)
        #expect(Slot.select(isPlacing: true, card: nil) == .placing)
    }

    @Test func slotFadesInPlaceOnlyUnderReduceMotion() {
        #expect(Slot.style(reduceMotion: false) == .moveAndFade)
        #expect(Slot.style(reduceMotion: true) == .fade)
        #expect(Slot.transitionSeconds == 0.25)
    }

    // MARK: Crosshair

    @Test func crosshairCentresInTheBandAboveTheCard() {
        // 800pt map, 120pt card, 24pt clearance: the card's top is at 656.
        let centre = BrowseMotion.crosshairY(mapHeight: 800, cardHeight: 120, clearance: 24)
        #expect(centre == 328)
        #expect(centre < 800 / 2)
    }

    struct CrosshairCase: Sendable, CustomTestStringConvertible {
        let mapHeight: CGFloat
        let cardHeight: CGFloat

        var testDescription: String { "map=\(mapHeight) card=\(cardHeight)" }
    }

    @Test(arguments: [
        CrosshairCase(mapHeight: 852, cardHeight: 0),
        CrosshairCase(mapHeight: 852, cardHeight: 300),
        CrosshairCase(mapHeight: 340, cardHeight: 250),
        CrosshairCase(mapHeight: 340, cardHeight: 400)
    ])
    func crosshairNeverSitsBelowTheCardsTop(_ testCase: CrosshairCase) {
        let clearance: CGFloat = 24
        let centre = BrowseMotion.crosshairY(
            mapHeight: testCase.mapHeight,
            cardHeight: testCase.cardHeight,
            clearance: clearance
        )
        let cardTop = testCase.mapHeight - testCase.cardHeight - clearance
        #expect(centre >= 0)
        #expect(centre <= max(0, cardTop))
    }
}
