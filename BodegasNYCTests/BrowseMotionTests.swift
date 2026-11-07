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
import SwiftUI
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

        // The block-zoom camera (#156): screen-down of the pin, 420 m,
        // pitched 55°, north-up with no settle yet.
        let center = AddCompletionCoordinator.cameraCenter(for: edited.coordinate, heading: 0)
        let flown = try #require(log.flights.first?.0)
        #expect(log.flights.count == 1)
        #expect(Coordinate(flown.centerCoordinate) == center)
        #expect(flown.distance == BodegaMapViewModel.blockZoomCameraDistance)
        #expect(flown.pitch == BodegaMapViewModel.blockZoomPitch)
        #expect(flown.heading == 0)
        // No settle reported yet: the long flight.
        #expect(log.flights.map(\.1) == [MapScreenView.locateMeLongFlightSeconds])
        #expect(log.announcements.isEmpty)
        motion.cameraDidSettle(camera: flown)
        #expect(log.announcements == ["Renamed Deli. On the map."])
    }

    /// protects: DS7's no-op: a camera already settled on the target block
    /// zoom camera does not fly, and the landing is announced at once.
    /// fails_when: a pointless flight runs, or the announcement waits for a
    /// settle that will never come.
    /// no_claim: MapKit's own settle rounding (the tolerances, eng D6, are
    /// the rule rows below).
    @Test func showOnMapOnTheSettledCameraAnnouncesWithoutFlying() {
        let motion = PinMotionState()
        let log = FlightLog()
        motion.flyCamera = { log.flights.append(($0, $1)) }
        motion.announce = { log.announcements.append($0) }
        motion.cameraDidSettle(camera: Self.landing(on: pin))

        motion.send(.showOnMap(pin))

        #expect(log.flights.isEmpty)
        #expect(log.announcements == ["Held Deli. On the map."])
    }

    /// protects: the flight follows Locate Me's rule (design DS7), on
    /// cameras since #156: 0.6 s for a short hop, 0.9 s when zooming in more
    /// than three levels or moving over 2 km, none when already there
    /// (centre within 30 m, distance within 10%, pitch within 5°, eng D6).
    /// fails_when: a long flight is rushed, a short one dawdles, a settled
    /// camera at the target flies again, a camera 40 m off or levelled by
    /// hand counts as already there.
    /// no_claim: how the flight looks, or where the pin lands on screen
    /// (AC 6, simulator).
    @Test func spotlightFlightFollowsTheLocateMeRule() {
        let target = Self.landing(on: pin)
        let center = Coordinate(target.centerCoordinate)
        let rule = PinMotionState.spotlightFlightSeconds
        #expect(rule(nil, target) == 0.9)
        #expect(rule(target, target) == nil)
        // MapKit's settle rounding (replaces the region rows' portrait fit):
        // 5 m off, 3% farther, the pitch clamped 2.5° lower.
        #expect(rule(Self.camera(at: Self.north(of: center, meters: 5), distance: 432.6, pitch: 52.5), target) == nil)
        // A block away at a slightly wider zoom: short.
        let nearby = Coordinate(latitude: center.latitude + 0.002, longitude: center.longitude)
        #expect(rule(Self.camera(at: nearby, distance: 1050, pitch: 0), target) == 0.6)
        // Zooming in from a borough-wide view (ratio over 8): long.
        #expect(rule(Self.camera(at: nearby, distance: 5250, pitch: 0), target) == 0.9)
        // Same zoom, 3 km away: long.
        let far = Coordinate(latitude: center.latitude + 0.027, longitude: center.longitude)
        #expect(rule(Self.camera(at: far, distance: 420, pitch: 55), target) == 0.9)
    }

    /// protects: eng D6's metre tolerance and the pitch test: 25 m off the
    /// target is already there, 40 m flies; a hand-levelled camera on the
    /// target (pitch 0 against 55) flies again, and so does one 15% farther.
    /// fails_when: the old 0.001° (about 111 m) tolerance comes back, or the
    /// pitch or distance is ignored.
    /// no_claim: MapKit's real rounding (AC 5 on the simulator).
    @Test func spotlightNoOpIsThirtyMetresTenPercentAndFiveDegrees() {
        let target = Self.landing(on: pin)
        let center = Coordinate(target.centerCoordinate)
        let rule = PinMotionState.spotlightFlightSeconds
        #expect(rule(Self.camera(at: Self.north(of: center, meters: 25), distance: 420, pitch: 55), target) == nil)
        #expect(rule(Self.camera(at: Self.north(of: center, meters: 40), distance: 420, pitch: 55), target) == 0.6)
        #expect(rule(Self.camera(at: center, distance: 420, pitch: 0), target) == 0.6)
        #expect(rule(Self.camera(at: center, distance: 483, pitch: 55), target) == 0.6)
        // A level target (Reduce Motion, compact height, the user's level)
        // against a level settle: already there.
        let level = Self.camera(at: center, distance: 420, pitch: 0)
        #expect(rule(level, level) == nil)
    }

    /// protects: design DS6: a level the user made holds for the session;
    /// an app write that levels the map (the add flow, a level landing, the
    /// coarse-fix fallback) is not the user's; a settle arriving pitched
    /// clears it; Reduce Motion and compact height land level (DS5, DS8).
    /// fails_when: the user's level is forgotten at the next landing, the
    /// add flow's level counts as the user's, or a re-pitch keeps landings
    /// level.
    /// no_claim: that MapScreenView flags every app write (code reading) or
    /// the live toggle (AC 5, simulator).
    @Test func userLevelledHoldsUntilAPitchedSettle() {
        let motion = PinMotionState()
        let center = Coordinate(latitude: 40.7291, longitude: -73.9965)
        #expect(motion.landingPitch == 55)
        motion.cameraDidSettle(camera: Self.camera(at: center, distance: 420, pitch: 55))
        // The app levels it (the add flow): not the user's.
        motion.noteAppLevelWrite()
        motion.cameraDidSettle(camera: Self.camera(at: center, distance: 420, pitch: 0))
        #expect(!motion.userLevelled)
        #expect(motion.landingPitch == 55)
        // Pitched again, then levelled by hand.
        motion.cameraDidSettle(camera: Self.camera(at: center, distance: 420, pitch: 55))
        motion.cameraDidSettle(camera: Self.camera(at: center, distance: 420, pitch: 0))
        #expect(motion.userLevelled)
        #expect(motion.landingPitch == 0)
        // A level pan keeps it; a pitched settle clears it.
        motion.cameraDidSettle(camera: Self.camera(at: Self.north(of: center, meters: 300), distance: 420, pitch: 0))
        #expect(motion.userLevelled)
        motion.cameraDidSettle(camera: Self.camera(at: center, distance: 420, pitch: 40))
        #expect(!motion.userLevelled)
        #expect(motion.landingPitch == 55)
        motion.reduceMotion = true
        #expect(motion.landingPitch == 0)
        motion.reduceMotion = false
        motion.isCompactHeight = true
        #expect(motion.landingPitch == 0)
    }

    /// protects: eng D5: the camera centre sits about 74 m screen-down of
    /// the pin at any heading (bearing heading + 180°), and heading 0 is
    /// exactly the add flow's old sixth of the span south.
    /// fails_when: the offset stays geographic south at a rotated heading
    /// (the pin would land beside or below the centre), or the add flow's
    /// target moves.
    /// no_claim: the pin's exact screen fraction (AC 6 captures).
    @Test func cameraCenterIsScreenDownAtEveryHeading() {
        let pin = Coordinate(latitude: 40.7291, longitude: -73.9965)
        let north = AddCompletionCoordinator.cameraCenter(for: pin, heading: 0)
        #expect(north == Coordinate(latitude: pin.latitude - AddCompletionCoordinator.cameraSpan / 6, longitude: pin.longitude))
        let offset = pin.distance(to: north)
        #expect(abs(offset - 74) < 1)
        for heading in [90.0, 180, 270] {
            let center = AddCompletionCoordinator.cameraCenter(for: pin, heading: heading)
            #expect(abs(pin.distance(to: center) - offset) < 0.5)
        }
        // Heading 90 (east up): the centre is west of the pin; 180: north;
        // 270: east.
        let east = AddCompletionCoordinator.cameraCenter(for: pin, heading: 90)
        #expect(east.longitude < pin.longitude && abs(east.latitude - pin.latitude) < 1e-9)
        let south = AddCompletionCoordinator.cameraCenter(for: pin, heading: 180)
        #expect(south.latitude > pin.latitude && abs(south.longitude - pin.longitude) < 1e-9)
        let west = AddCompletionCoordinator.cameraCenter(for: pin, heading: 270)
        #expect(west.longitude > pin.longitude && abs(west.latitude - pin.latitude) < 1e-9)
    }

    /// The Show on Map landing for `bodega` with no settle (heading 0, 55°).
    private static func landing(on bodega: Bodega) -> MapCamera {
        BodegaMapViewModel.blockZoomCamera(
            center: AddCompletionCoordinator.cameraCenter(for: bodega.coordinate, heading: 0),
            heading: 0,
            pitch: BodegaMapViewModel.blockZoomPitch
        )
    }

    private static func camera(at center: Coordinate, distance: Double, pitch: Double) -> MapCamera {
        MapCamera(centerCoordinate: center.clLocationCoordinate, distance: distance, heading: 0, pitch: pitch)
    }

    private static func north(of center: Coordinate, meters: Double) -> Coordinate {
        Coordinate(latitude: center.latitude + meters / BodegaMapViewModel.metersPerDegreeLatitude, longitude: center.longitude)
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
    var flights: [(MapCamera, TimeInterval)] = []
    var announcements: [String] = []
}
