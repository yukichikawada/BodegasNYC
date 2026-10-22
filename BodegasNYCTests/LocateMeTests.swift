//
//  LocateMeTests.swift
//  BodegasNYCTests
//
//  Locate Me lands at block zoom (#84 item 1): the pure decisions in
//  `MapScreenView+LocateMe.swift`. Which result may still move the camera
//  (eng R1), which fix lands block zoom (eng R3), when a kept fix lands at
//  once (design D1), how long the flight is (design D8), and when the first
//  add owns the camera (design D6). Eng R4's `isLandedCamera` and its five
//  tests went with the follow handover, which probe P1 dropped (MapKit
//  re-zoomed on it): the landing is one-shot.
//
//  no_claim (whole file): MapKit's camera, the flight and the pulse are
//  live QA on the branch simulator (probe P1); no MapKit, CoreLocation or
//  view is exercised here.
//

import Foundation
import Testing

@testable import BodegasNYC

@MainActor
struct LocateMeTests {
    private static let block = Coordinate(latitude: 40.7291, longitude: -73.9965)

    // MARK: LocateRequest.shouldApply (eng R1)

    /// protects: the result of the latest tap lands when nothing happened
    /// since the tap, from the toolbar and from Near Me alike.
    /// fails_when: a current, untouched request is dropped.
    /// no_claim: that `MapScreenView` counts settles or passes live values.
    @Test func currentUntouchedRequestApplies() {
        let toolbar = LocateRequest(settleCount: 3, wasPlacing: false)
        #expect(toolbar.shouldApply(current: toolbar, settleCountNow: 3, showsToolbar: true, isPlacing: false))
        let nearMe = LocateRequest(settleCount: 3, wasPlacing: true)
        #expect(nearMe.shouldApply(current: nearMe, settleCountNow: 3, showsToolbar: true, isPlacing: true))
    }

    /// protects: a late fix never takes the camera back: a newer tap, a
    /// settle since the tap (the user panned), the List tab, or a change of
    /// placement each drop it.
    /// fails_when: any one of the four conditions alone still applies it.
    /// no_claim: none beyond protects.
    @Test func lateOrSupersededRequestIsDropped() {
        let request = LocateRequest(settleCount: 3, wasPlacing: false)
        let newer = LocateRequest(settleCount: 3, wasPlacing: false)
        #expect(!request.shouldApply(current: newer, settleCountNow: 3, showsToolbar: true, isPlacing: false))
        #expect(!request.shouldApply(current: request, settleCountNow: 4, showsToolbar: true, isPlacing: false))
        #expect(!request.shouldApply(current: request, settleCountNow: 3, showsToolbar: false, isPlacing: false))
        #expect(!request.shouldApply(current: request, settleCountNow: 3, showsToolbar: true, isPlacing: true))
    }

    // MARK: landsBlockZoom (eng R3)

    /// protects: a precise fix (accuracy 0 to 100 m) lands at block zoom.
    /// fails_when: a 50 m fix takes the fallback. no_claim: none beyond protects.
    @Test func preciseFixLandsBlockZoom() {
        #expect(MapScreenView.landsBlockZoom(accuracy: 50))
    }

    /// protects: a coarse fix (Precise Location off) never names a block.
    /// fails_when: a 101 m fix lands at block zoom. no_claim: none beyond protects.
    @Test func coarseFixTakesTheFallback() {
        #expect(!MapScreenView.landsBlockZoom(accuracy: 101))
    }

    /// protects: an invalid fix (negative accuracy) never lands at block zoom.
    /// fails_when: -1 counts as precise. no_claim: none beyond protects.
    @Test func invalidFixTakesTheFallback() {
        #expect(!MapScreenView.landsBlockZoom(accuracy: -1))
    }

    // MARK: landsAtOnce (design D1)

    /// protects: a precise kept fix up to 60 s old lands without waiting.
    /// fails_when: a 30 s old, 20 m fix waits for a new one.
    /// no_claim: that `UserLocationProvider` holds such a fix (its own tests).
    @Test func freshPreciseKeptFixLandsAtOnce() {
        let now = Date()
        let fix = UserFix(coordinate: Self.block, horizontalAccuracy: 20, timestamp: now.addingTimeInterval(-30))
        #expect(MapScreenView.landsAtOnce(on: fix, now: now))
    }

    /// protects: an old or coarse kept fix waits for a new one.
    /// fails_when: a 61 s old fix or a 150 m fix lands at once.
    /// no_claim: none beyond protects.
    @Test func staleOrCoarseKeptFixWaits() {
        let now = Date()
        let stale = UserFix(coordinate: Self.block, horizontalAccuracy: 20, timestamp: now.addingTimeInterval(-61))
        let coarse = UserFix(coordinate: Self.block, horizontalAccuracy: 150, timestamp: now)
        #expect(!MapScreenView.landsAtOnce(on: stale, now: now))
        #expect(!MapScreenView.landsAtOnce(on: coarse, now: now))
    }

    // MARK: locateMeFlightSeconds (design D8)

    /// protects: a flight over three zoom levels or 2 km takes 0.9 s.
    /// fails_when: the cold-start flight (ratio about 63) or a 3 km move at
    /// the same zoom takes 0.6 s. no_claim: the felt speed (live QA).
    @Test func longFlightsTakeNineTenths() {
        #expect(MapScreenView.locateMeFlightSeconds(ratio: 63, centreMoveMeters: 500) == 0.9)
        #expect(MapScreenView.locateMeFlightSeconds(ratio: 1, centreMoveMeters: 3000) == 0.9)
    }

    /// protects: a short hop keeps the add flow's 0.6 s pan.
    /// fails_when: a ratio of 8 or a 2,000 m move (the limits themselves)
    /// takes 0.9 s. no_claim: none beyond protects.
    @Test func shortFlightsTakeSixTenths() {
        #expect(MapScreenView.locateMeFlightSeconds(ratio: 8, centreMoveMeters: 2000) == 0.6)
        #expect(MapScreenView.locateMeFlightSeconds(ratio: 1, centreMoveMeters: 0) == 0.6)
    }

    // MARK: ignoresLocateMe (design D6)

    /// protects: the first add's choreography owns the camera: Locate Me is
    /// ignored while a new pin is pending or dropping or the first-add card
    /// is up, and works otherwise. fails_when: any of the three lets the tap
    /// through, or a quiet map ignores it. no_claim: that the view reads the
    /// live coordinator (live QA).
    @Test func firstAddWindowIgnoresLocateMe() {
        let id = UUID()
        #expect(MapScreenView.ignoresLocateMe(dropState: .pending(id), hasFirstAddCard: false))
        #expect(MapScreenView.ignoresLocateMe(dropState: .dropping(id), hasFirstAddCard: false))
        #expect(MapScreenView.ignoresLocateMe(dropState: .none, hasFirstAddCard: true))
        #expect(!MapScreenView.ignoresLocateMe(dropState: .none, hasFirstAddCard: false))
    }
}
