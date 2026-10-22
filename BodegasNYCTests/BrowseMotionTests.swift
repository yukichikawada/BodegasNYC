//
//  BrowseMotionTests.swift
//  BodegasNYCTests
//
//  The browse session's pure motion decisions (#23): how the List tab's page
//  moves over the live map, which occupant the map's bottom slot shows and
//  how it moves, where the placement crosshair sits, and the reducer behind
//  pin → hold → zoom push → pop → release.
//
//  protects: the list slides (0.3s) by default and fades (0.25s) when either
//  Reduce Motion or Prefer Cross-Fade Transitions is on; placement outranks
//  every bottom card; the slot fades in place under Reduce Motion; the
//  crosshair is centred in the band above the placement card and never sits
//  on or below the card's top edge; a pin tap holds before pushing, only the
//  timer belonging to the current held pin advances the phase, a cluster tap
//  or an interruption cancels a hold so no detail opens, the pop starts the
//  release, and a tap during the release starts a fresh hold (one held pin at
//  a time); the pin hold and release lengths match DESIGN.md.
//  fails_when: either accessibility switch alone stops producing the fade or
//  its duration; a card shows while placing, or `.empty` replaces a card;
//  the slot keeps its slide under Reduce Motion; the crosshair centres on the
//  whole map (ignoring the card) or goes negative for a tall card; a stale
//  timer pushes or releases the wrong pin, a cluster tap during the hold
//  still pushes, a tap during the release is dropped or leaves the old timer
//  running, or a pin constant drifts from DESIGN.md.
//  no_claim: rendering. That BrowseView and MapScreenView read the live
//  accessibility settings, map these values to the right SwiftUI
//  transitions, measure the real card height, run the pin timers, and show
//  the zoom, the held pin's look and VoiceOver focus is checked by QA
//  recordings on the branch simulator. Bodegas are `makeTestBodega`
//  fixtures; no mocks. The DESIGN.md check reads the repo copy through
//  `#filePath` (the simulator shares the host file system) and only matches
//  the markdown wording "`releaseSeconds = 0.4`", not any behaviour.
//

import CoreGraphics
import Foundation
import Testing

@testable import BodegasNYC

@MainActor
struct BrowseMotionTests {
    private typealias ListMotion = BrowseMotion.ListTransition
    private typealias Slot = BrowseMotion.BottomSlot
    private typealias PinMotion = BrowseMotion.PinToDetail

    private let pin: Bodega
    private let otherPin: Bodega

    init() throws {
        pin = try makeTestBodega(name: "Held Deli")
        otherPin = try makeTestBodega(name: "Other Deli")
    }

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

    // MARK: Pin to detail

    @Test func pinTapFromIdleHoldsAndSchedulesTheHold() {
        let (phase, effects) = PinMotion.reduce(.idle, .pinTapped(pin))
        #expect(phase == .holding(pin))
        #expect(effects == [.scheduleHold(pin.id)])
    }

    @Test func holdElapsedForTheHeldPinPushesIt() {
        let (phase, effects) = PinMotion.reduce(.holding(pin), .holdElapsed(pin.id))
        #expect(phase == .presented(pin))
        #expect(effects == [.push(pin)])
    }

    @Test func holdElapsedForAnotherPinIsStale() {
        let (phase, effects) = PinMotion.reduce(.holding(pin), .holdElapsed(otherPin.id))
        #expect(phase == .holding(pin))
        #expect(effects.isEmpty)
    }

    @Test func clusterTapDuringTheHoldCancelsIt() {
        let (phase, effects) = PinMotion.reduce(.holding(pin), .clusterTapped)
        #expect(phase == .idle)
        #expect(effects == [.cancelTimer])
    }

    @Test func anotherPinTappedDuringTheHoldRestartsTheHoldOnIt() {
        let (phase, effects) = PinMotion.reduce(.holding(pin), .pinTapped(otherPin))
        #expect(phase == .holding(otherPin))
        #expect(effects == [.cancelTimer, .scheduleHold(otherPin.id)])
    }

    @Test func detailDismissedStartsTheRelease() {
        let (phase, effects) = PinMotion.reduce(.presented(pin), .detailDismissed)
        #expect(phase == .releasing(pin))
        #expect(effects == [.scheduleRelease(pin.id)])
    }

    @Test func releaseElapsedForTheHeldPinReturnsToIdle() {
        let (phase, effects) = PinMotion.reduce(.releasing(pin), .releaseElapsed(pin.id))
        #expect(phase == .idle)
        #expect(effects.isEmpty)
    }

    @Test func samePinTappedDuringTheReleaseHoldsItAgain() {
        let (phase, effects) = PinMotion.reduce(.releasing(pin), .pinTapped(pin))
        #expect(phase == .holding(pin))
        #expect(effects == [.cancelTimer, .scheduleHold(pin.id)])
    }

    @Test func interruptedDuringTheReleaseCancelsIt() {
        let (phase, effects) = PinMotion.reduce(.releasing(pin), .interrupted)
        #expect(phase == .idle)
        #expect(effects == [.cancelTimer])
    }

    /// protects: the list order cross-fade runs DESIGN.md's content-swap
    /// duration (#81 design D4).
    /// fails_when: the constant drifts from 0.25s.
    /// no_claim: that BodegaListView applies it, or drops it under Reduce
    /// Motion (live QA).
    @Test func listReorderIsAQuarterSecond() {
        #expect(BrowseMotion.ListOrder.reorderSeconds == 0.25)
    }

    @Test func holdIsAQuarterSecond() {
        #expect(PinMotion.holdSeconds == 0.25)
    }

    @Test func releaseSecondsMatchesDesignMD() throws {
        let designURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DESIGN.md")
        let design = try String(contentsOf: designURL, encoding: .utf8)
        #expect(design.contains("`releaseSeconds = \(PinMotion.releaseSeconds)`"))
    }
}
