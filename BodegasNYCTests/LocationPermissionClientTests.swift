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
import Testing

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
}
