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
import MapKit
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

    // MARK: Show on Map (#150 eng R2/R3)
    // protects: Show on Map spotlights the detail's bodega as passed (the
    // post-edit value), flies at once from idle, releases first from a
    // pin-opened detail and flies only on that release's own timer, opens
    // the bodega on a pin tap, and clears on a cluster tap or an
    // interruption (List tab, placement, an add).
    // fails_when: the spotlight keeps a stale held value, flies during the
    // pop, ignores its release, or survives a cluster tap or interruption.
    // no_claim: the pop's look, the camera's path, VoiceOver focus (live QA).

    @Test func showOnMapFromIdleSpotlightsAndFliesAtOnce() {
        let (phase, effects) = PinMotion.reduce(.idle, .showOnMap(pin))
        #expect(phase == .spotlit(pin))
        #expect(effects == [.moveCamera(pin)])
    }

    @Test func showOnMapFromAPinOpenedDetailReleasesBeforeFlying() throws {
        let edited = try makeTestBodega(id: pin.id, name: "Renamed Deli")
        let (phase, effects) = PinMotion.reduce(.presented(pin), .showOnMap(edited))
        #expect(phase == .spotlit(edited))
        #expect(effects == [.scheduleRelease(pin.id)])
    }

    @Test func releaseElapsedForTheSpotlitPinFliesThere() {
        #expect(PinMotion.reduce(.spotlit(pin), .releaseElapsed(pin.id)) == (.spotlit(pin), [.moveCamera(pin)]))
        let (stale, staleEffects) = PinMotion.reduce(.spotlit(pin), .releaseElapsed(otherPin.id))
        #expect(stale == .spotlit(pin))
        #expect(staleEffects.isEmpty)
    }

    @Test func pinTappedWhileSpotlitHoldsThatPin() {
        #expect(PinMotion.reduce(.spotlit(pin), .pinTapped(pin)) == (.holding(pin), [.scheduleHold(pin.id)]))
        #expect(
            PinMotion.reduce(.spotlit(pin), .pinTapped(otherPin)) == (.holding(otherPin), [.scheduleHold(otherPin.id)])
        )
    }

    @Test func clusterTapOrInterruptionClearsTheSpotlight() {
        for event in [PinMotion.Event.clusterTapped, .interrupted] {
            let (phase, effects) = PinMotion.reduce(.spotlit(pin), event)
            #expect(phase == .idle)
            #expect(effects == [.cancelTimer])
        }
    }

    /// A spotlight still up under a detail opened from the add flow's
    /// duplicate prompt (no pin tap or List tab in between) moves on.
    @Test func showOnMapWhileSpotlitMovesTheSpotlight() {
        let (phase, effects) = PinMotion.reduce(.spotlit(pin), .showOnMap(otherPin))
        #expect(phase == .spotlit(otherPin))
        #expect(effects == [.moveCamera(otherPin)])
    }

    /// protects: `PinMotionState` runs `.moveCamera` through its bound
    /// flight with `cameraCenter(for:)` of the event's bodega, only after
    /// the release from a pin-opened detail, and announces the landing at
    /// the next settle (DS9).
    /// fails_when: the flight starts during the pop, targets the pin itself
    /// or the stale held value, or the announcement is missing or early.
    /// no_claim: the real camera animation or VoiceOver speech (live QA);
    /// real 0.25 s and 0.4 s timers, polled.
    @Test func showOnMapFromAPinOpenedDetailFliesAfterTheReleaseThenAnnounces() async throws {
        let motion = PinMotionState()
        let log = FlightLog()
        motion.flyCamera = { log.flights.append(($0, $1)) }
        motion.announce = { log.announcements.append($0) }
        motion.send(.pinTapped(pin), onPush: { _ in })
        await waitUntil { motion.phase == .presented(pin) }
        #expect(motion.phase == .presented(pin))
        let edited = try makeTestBodega(id: pin.id, name: "Renamed Deli")

        motion.send(.showOnMap(edited))
        #expect(motion.phase == .spotlit(edited))
        #expect(log.flights.isEmpty)
        await waitUntil { !log.flights.isEmpty }

        let center = AddCompletionCoordinator.cameraCenter(for: edited.coordinate)
        #expect(log.flights.map(\.0) == [center])
        // No settle reported yet: the long flight.
        #expect(log.flights.map(\.1) == [MapScreenView.locateMeLongFlightSeconds])
        #expect(log.announcements.isEmpty)
        motion.cameraDidSettle(region: Self.streetRegion(at: center))
        #expect(log.announcements == ["Renamed Deli. On the map."])
    }

    /// protects: DS7's no-op: a camera already settled on the target at
    /// street span does not fly, and the landing is announced at once.
    /// fails_when: a pointless flight runs, or the announcement waits for a
    /// settle that will never come.
    /// no_claim: MapKit's own settle rounding (the tolerance is the add
    /// flow's `settleTolerance`).
    @Test func showOnMapOnTheSettledCameraAnnouncesWithoutFlying() {
        let motion = PinMotionState()
        let log = FlightLog()
        motion.flyCamera = { log.flights.append(($0, $1)) }
        motion.announce = { log.announcements.append($0) }
        let center = AddCompletionCoordinator.cameraCenter(for: pin.coordinate)
        motion.cameraDidSettle(region: Self.streetRegion(at: center))

        motion.send(.showOnMap(pin))

        #expect(log.flights.isEmpty)
        #expect(log.announcements == ["Held Deli. On the map."])
    }

    /// protects: the flight follows Locate Me's rule (design DS7): 0.6 s
    /// for a short hop, 0.9 s when zooming in more than three levels or
    /// moving over 2 km, none when already there.
    /// fails_when: a long flight is rushed, a short one dawdles, or a
    /// settled camera at the target flies again.
    /// no_claim: how the flight looks.
    @Test func spotlightFlightFollowsTheLocateMeRule() {
        let center = AddCompletionCoordinator.cameraCenter(for: pin.coordinate)
        let rule = PinMotionState.spotlightFlightSeconds
        #expect(rule(nil, center) == 0.9)
        #expect(rule(Self.streetRegion(at: center), center) == nil)
        // Portrait fit: the latitude span is the larger one.
        #expect(rule(Self.region(at: center, latitudeSpan: 0.007, longitudeSpan: 0.004), center) == nil)
        // A block away at a slightly wider zoom: short.
        let nearby = Coordinate(latitude: center.latitude + 0.002, longitude: center.longitude)
        #expect(rule(Self.region(at: nearby, latitudeSpan: 0.01, longitudeSpan: 0.01), center) == 0.6)
        // Zooming in from a borough-wide view (ratio over 8): long.
        #expect(rule(Self.region(at: nearby, latitudeSpan: 0.05, longitudeSpan: 0.05), center) == 0.9)
        // Same zoom, 3 km away: long.
        let far = Coordinate(latitude: center.latitude + 0.027, longitude: center.longitude)
        #expect(rule(Self.streetRegion(at: far), center) == 0.9)
    }

    /// protects: a detail counts as pin-opened (zoom transition, Show on
    /// Map's `from_map`) only from the Map tab and never when the add flow's
    /// duplicate prompt opened it with a standard push (#20, #150 R4).
    /// fails_when: a duplicate-prompt detail on the Map tab reports
    /// `from_map = true`, or a list-opened detail counts as pin-opened.
    /// no_claim: that `BrowseView` passes the captured origin (live QA).
    @Test func opensFromPinExcludesTheListAndTheDuplicatePrompt() {
        let opens = BrowseView.opensFromPin
        #expect(opens(.map, nil, pin.id))
        #expect(opens(.map, otherPin.id, pin.id))
        #expect(!opens(.map, pin.id, pin.id))
        #expect(!opens(.list, nil, pin.id))
    }

    private static func streetRegion(at center: Coordinate) -> MKCoordinateRegion {
        region(at: center, latitudeSpan: 0.004, longitudeSpan: 0.004)
    }

    private static func region(at center: Coordinate, latitudeSpan: Double, longitudeSpan: Double)
        -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center.clLocationCoordinate,
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
        )
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

/// What `PinMotionState`'s bound flight and announcer were handed.
@MainActor
private final class FlightLog {
    var flights: [(Coordinate, TimeInterval)] = []
    var announcements: [String] = []
}
