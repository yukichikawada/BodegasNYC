//
//  LocationPermissionClientTests.swift
//  BodegasNYCTests
//
//  `CLLocationManager` can't be driven deterministically the way
//  `MockURLProtocol` drives `PostgrestClient` — no equivalent seam, and this
//  codebase's convention is no new protocol-abstraction layer over
//  system/third-party APIs. So only the pure re-prompt-skip branching logic
//  is covered here; the delegate/continuation plumbing itself is manually
//  verified in Simulator.
//

import CoreLocation
import Foundation
import Testing
import UIKit

@testable import BodegasNYC

@Suite
struct LocationPermissionClientTests {
    private static let allStatuses: [CLAuthorizationStatus] = [
        .notDetermined,
        .restricted,
        .denied,
        .authorizedAlways,
        .authorizedWhenInUse,
    ]

    @Test func whenInUseSkipsOnlyWhenAlreadyDetermined() {
        for status in Self.allStatuses {
            let shouldSkip = LocationPermissionClient.shouldSkipWhenInUseRequest(currentStatus: status)
            #expect(shouldSkip == (status != .notDetermined), "status: \(status)")
        }
    }

    @Test func alwaysSkipsOnlyWhenAlreadyAuthorizedAlways() {
        for status in Self.allStatuses {
            let shouldSkip = LocationPermissionClient.shouldSkipAlwaysRequest(currentStatus: status)
            #expect(shouldSkip == (status == .authorizedAlways), "status: \(status)")
        }
    }

    @Test func authorizedWhenInUseDoesNotSkipTheAlwaysUpgradeAsk() {
        #expect(LocationPermissionClient.shouldSkipAlwaysRequest(currentStatus: .authorizedWhenInUse) == false)
    }

    @Test func requestCurrentLocationOnlyProceedsWhenAuthorized() {
        for status in Self.allStatuses {
            let canRequest = LocationPermissionClient.canRequestCurrentLocation(authorizationStatus: status)
            #expect(canRequest == (status == .authorizedWhenInUse || status == .authorizedAlways), "status: \(status)")
        }
    }

    /// protects=an Always request whose prompt closes without changing the
    /// status (Keep Only While Using on the upgrade prompt fires no delegate
    /// change) returns as soon as the app is active again, with the current
    /// status, so Start Recording shows its card at once (#123 QA P2);
    /// fails_when=the request waits for the 30 s timeout, or never returns;
    /// no_claim=the system prompt itself (a no-op stands in) and the real
    /// activation (a private NotificationCenter posts it), and that the
    /// real Core Location status is current at that moment (QA, live).
    @MainActor
    @Test func anAlwaysRequestReturnsWhenTheAppIsActiveAgain() async throws {
        let center = NotificationCenter()
        var prompts = 0
        let client = LocationPermissionClient(notificationCenter: center, promptForAlways: { _ in prompts += 1 })
        try #require(client.authorizationStatus != .authorizedAlways)
        let before = client.authorizationStatus

        let started = ContinuousClock.now
        let request = Task { await client.requestAlwaysAuthorization() }
        while prompts == 0 { await Task.yield() }
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let status = await request.value

        #expect(prompts == 1)
        #expect(status == before)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// protects=`hasPendingAuthorizationRequest` is true exactly while an
    /// authorization request awaits its answer, so the Streets Walked intro
    /// never presents over a location prompt (#126 AC5);
    /// fails_when=it is false while the request waits, or stays true after
    /// the request resolves; no_claim=the real system prompt (a no-op stands
    /// in) and the 30 s timeout path (not waited for here).
    @MainActor
    @Test func aPendingRequestIsVisibleUntilItResolves() async throws {
        let center = NotificationCenter()
        var prompts = 0
        let client = LocationPermissionClient(notificationCenter: center, promptForAlways: { _ in prompts += 1 })
        try #require(client.authorizationStatus != .authorizedAlways)
        #expect(client.hasPendingAuthorizationRequest == false)

        // The real CLLocationManager reports its status once, shortly after
        // the delegate is set, and that callback resolves whatever request
        // is waiting. It fires once, so of up to three requests at least one
        // waits until the activation below (run 2026-10-29: the first
        // request was resolved by it before it could be observed).
        var sawPending = false
        for attempt in 1...3 where !sawPending {
            let request = Task { await client.requestAlwaysAuthorization() }
            while prompts < attempt { await Task.yield() }
            sawPending = client.hasPendingAuthorizationRequest
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            _ = await request.value
            #expect(client.hasPendingAuthorizationRequest == false, "attempt \(attempt)")
        }
        #expect(sawPending)
    }
}
