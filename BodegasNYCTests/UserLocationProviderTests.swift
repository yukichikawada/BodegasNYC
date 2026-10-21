//
//  UserLocationProviderTests.swift
//  BodegasNYCTests
//
//  `UserLocationProvider.refresh()` (#68, eng D6/D10/D11) with injected
//  authorization, fix and clock, so no `CLLocationManager` is involved.
//
//  no_claim (whole suite): that `LocationPermissionClient.requestCurrentFix()`
//  delivers a real fix, or that `BrowseView` calls `refresh()` on the right
//  events (QA checks both on the branch simulator).
//

import CoreLocation
import Foundation
import Testing

@testable import BodegasNYC

@MainActor
struct UserLocationProviderTests {
    /// Mutable inputs the provider's closures read.
    @MainActor
    final class Harness {
        var isAuthorized = true
        var now = Date(timeIntervalSince1970: 1_000_000)
        var nextFix: CLLocation?
        var requestCount = 0
        /// Runs during the await, before the fix is returned.
        var duringRequest: (() -> Void)?

        lazy var provider = UserLocationProvider(
            isAuthorized: { [unowned self] in isAuthorized },
            requestFix: { [unowned self] in
                requestCount += 1
                duringRequest?()
                return nextFix
            },
            now: { [unowned self] in now }
        )

        func location(
            latitude: Double = 40.7291,
            accuracy: Double = 20,
            at timestamp: Date? = nil
        ) -> CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -73.9965),
                altitude: 0,
                horizontalAccuracy: accuracy,
                verticalAccuracy: -1,
                timestamp: timestamp ?? now
            )
        }
    }

    /// protects: never asking for a fix, and clearing any kept one, while
    /// location is not authorized (eng D8: no prompt path).
    /// fails_when: `requestFix` is called unauthorized, or a fix survives.
    @Test func unauthorizedNeverRequestsAFixAndClears() async {
        let harness = Harness()
        harness.nextFix = harness.location()
        await harness.provider.refresh()
        #expect(harness.provider.coordinate != nil)

        harness.isAuthorized = false
        await harness.provider.refresh()
        #expect(harness.requestCount == 1)
        #expect(harness.provider.latestFix == nil)
        #expect(harness.provider.coordinate == nil)
    }

    /// protects: one failed fetch does not blank a recent fix (eng D11).
    /// fails_when: a nil fix 9 minutes after the kept one clears it.
    @Test func nilFixKeepsAFixNineMinutesOld() async {
        let harness = Harness()
        harness.nextFix = harness.location()
        await harness.provider.refresh()
        harness.nextFix = nil
        harness.now += 9 * 60
        await harness.provider.refresh()
        #expect(harness.provider.coordinate?.latitude == 40.7291)
    }

    /// protects: a kept fix expires (eng D11).
    /// fails_when: a nil fix 11 minutes after the kept one keeps it.
    @Test func nilFixClearsAFixElevenMinutesOld() async {
        let harness = Harness()
        harness.nextFix = harness.location()
        await harness.provider.refresh()
        harness.nextFix = nil
        harness.now += 11 * 60
        await harness.provider.refresh()
        #expect(harness.provider.latestFix == nil)
    }

    /// protects: a revocation during the await is not undone by the fix
    /// already in flight.
    /// fails_when: the in-flight fix is stored after authorization was lost.
    @Test func revokedDuringTheAwaitClears() async {
        let harness = Harness()
        harness.nextFix = harness.location()
        await harness.provider.refresh()
        harness.nextFix = harness.location(latitude: 40.75)
        harness.duringRequest = { harness.isAuthorized = false }
        await harness.provider.refresh()
        #expect(harness.provider.latestFix == nil)
    }

    /// protects: overlapping refreshes settle on the one that completes last.
    /// fails_when: an earlier-completing result overwrites a later one, or
    /// overlapping calls deadlock or drop both.
    @Test func overlappingRefreshesLastWriterWins() async {
        var continuations: [CheckedContinuation<CLLocation?, Never>] = []
        let provider = UserLocationProvider(
            isAuthorized: { true },
            requestFix: { await withCheckedContinuation { continuations.append($0) } }
        )
        let first = Task { await provider.refresh() }
        let second = Task { await provider.refresh() }
        while continuations.count < 2 { await Task.yield() }

        let fix = { (latitude: Double) in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -73.9965),
                altitude: 0, horizontalAccuracy: 20, verticalAccuracy: -1, timestamp: .now
            )
        }
        // The second request finishes first; the first finishes last and wins.
        continuations[1].resume(returning: fix(40.80))
        await second.value
        #expect(provider.coordinate?.latitude == 40.80)
        continuations[0].resume(returning: fix(40.70))
        await first.value
        #expect(provider.coordinate?.latitude == 40.70)
    }

    /// protects: a fix accurate to 50 m is published (eng D10).
    /// fails_when: a precise fix is withheld.
    @Test func accuracyFiftyIsPublished() async {
        let harness = Harness()
        harness.nextFix = harness.location(accuracy: 50)
        await harness.provider.refresh()
        #expect(harness.provider.coordinate != nil)
        #expect(harness.provider.usableFix?.horizontalAccuracy == 50)
    }

    /// protects: a coarse fix (Precise Location off) shows no distance.
    /// fails_when: a 101 m fix is published.
    @Test func accuracyOverOneHundredIsNotPublished() async {
        let harness = Harness()
        harness.nextFix = harness.location(accuracy: 101)
        await harness.provider.refresh()
        // Not stored at all since review item 2: a coarse fix is treated
        // like a failed one.
        #expect(harness.provider.latestFix == nil)
        #expect(harness.provider.coordinate == nil)
        #expect(harness.provider.usableFix == nil)
    }

    /// protects: CoreLocation's stale cached fix is not taken as current.
    /// fails_when: a fix timestamped 40 minutes ago is stored, or a 1-minute-
    /// old one is rejected.
    @Test func staleReturnedFixIsNotStored() async {
        let harness = Harness()
        harness.nextFix = harness.location(at: harness.now - 40 * 60)
        await harness.provider.refresh()
        #expect(harness.provider.latestFix == nil)

        harness.nextFix = harness.location(at: harness.now - 60)
        await harness.provider.refresh()
        #expect(harness.provider.coordinate?.latitude == 40.7291)
    }

    /// protects: a coarse fix does not overwrite a kept precise one while it
    /// is fresh, and does not keep it alive past `maxFixAge`.
    /// fails_when: a 150 m fix replaces or blanks a recent precise fix, or an
    /// 11-minute-old precise fix survives a coarse refresh.
    @Test func coarseFixKeepsAFreshPreciseFixOnly() async {
        let harness = Harness()
        harness.nextFix = harness.location(accuracy: 20)
        await harness.provider.refresh()
        harness.nextFix = harness.location(latitude: 40.75, accuracy: 150)
        await harness.provider.refresh()
        #expect(harness.provider.coordinate?.latitude == 40.7291)

        harness.now += 11 * 60
        harness.nextFix = harness.location(latitude: 40.75, accuracy: 150)
        await harness.provider.refresh()
        #expect(harness.provider.latestFix == nil)
    }

    /// protects: triggers that land while a refresh is in flight do not start
    /// another (review item 9).
    /// fails_when: two back-to-back `requestRefresh()` calls fetch twice, or
    /// a request after the first completes is dropped.
    @Test func requestRefreshCoalescesWhileInFlight() async {
        var continuations: [CheckedContinuation<CLLocation?, Never>] = []
        let provider = UserLocationProvider(
            isAuthorized: { true },
            requestFix: { await withCheckedContinuation { continuations.append($0) } }
        )
        provider.requestRefresh()
        provider.requestRefresh()
        while continuations.isEmpty { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        #expect(continuations.count == 1)

        continuations[0].resume(returning: CLLocation(latitude: 40.7291, longitude: -73.9965))
        while provider.coordinate == nil { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        provider.requestRefresh()
        while continuations.count < 2 { await Task.yield() }
        #expect(continuations.count == 2)
        continuations[1].resume(returning: nil)
    }

    /// protects: an invalid fix (negative accuracy) shows no distance.
    /// fails_when: a fix with accuracy -1 is published.
    @Test func negativeAccuracyIsNotPublished() async {
        let harness = Harness()
        harness.nextFix = harness.location(accuracy: -1)
        await harness.provider.refresh()
        #expect(harness.provider.coordinate == nil)
    }

    /// protects: a refresh that starts unauthorized never awaits a fix, even
    /// with nothing kept (eng D8's provider assertion).
    /// fails_when: `requestFix` runs before authorization is checked.
    @Test func unauthorizedFromTheStartNeverCallsRequestFix() async {
        let harness = Harness()
        harness.isAuthorized = false
        harness.nextFix = harness.location()
        await harness.provider.refresh()
        #expect(harness.requestCount == 0)
        #expect(harness.provider.latestFix == nil)
    }
}
