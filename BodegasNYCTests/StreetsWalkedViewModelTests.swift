//
//  StreetsWalkedViewModelTests.swift
//  BodegasNYCTests
//
//  Constructs the real StreetsWalkedViewModel with an in-memory
//  ModelContainer — never calls enableTracking() successfully or touches
//  CLLocationManager.startUpdatingLocation(); real background delivery
//  itself isn't unit-testable (same boundary LocationPermissionClientTests
//  draws for permission prompts). Delegate *methods* are still plain Swift
//  functions we can call directly, though — dismissTrackingErrorClearsLastTrackingError
//  below calls locationManager(_:didFailWithError:) synthetically to seed
//  state, without needing a real CLLocationManager to drive anything.
//

import CoreLocation
import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

@Suite
@MainActor
struct StreetsWalkedViewModelTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeViewModel() throws -> (StreetsWalkedViewModel, ModelContext) {
        let container = try makeInMemoryModelContainer()
        let viewModel = StreetsWalkedViewModel(
            locationPermissionClient: LocationPermissionClient(),
            modelContainer: container
        )
        return (viewModel, container.mainContext)
    }

    @Test func loadPolylinesIfNeededSegmentsSeededHistory() throws {
        let (viewModel, context) = try makeViewModel()
        context.insert(WalkedPoint(latitude: 40.7000, longitude: -73.9900, recordedAt: Self.baseDate))
        context.insert(WalkedPoint(latitude: 40.7002, longitude: -73.9898, recordedAt: Self.baseDate.addingTimeInterval(30)))
        try context.save()

        viewModel.loadPolylinesIfNeeded()

        #expect(viewModel.polylines.count == 1)
        #expect(viewModel.polylines.first?.count == 2)
    }

    @Test func loadPolylinesIfNeededProducesNothingForAnEmptyStore() throws {
        let (viewModel, _) = try makeViewModel()

        viewModel.loadPolylinesIfNeeded()

        #expect(viewModel.polylines.isEmpty)
    }

    @Test func clearHistoryDeletesAllPointsAndEmptiesPolylines() async throws {
        let (viewModel, context) = try makeViewModel()
        context.insert(WalkedPoint(latitude: 40.7000, longitude: -73.9900, recordedAt: Self.baseDate))
        context.insert(WalkedPoint(latitude: 40.7002, longitude: -73.9898, recordedAt: Self.baseDate.addingTimeInterval(30)))
        try context.save()
        viewModel.loadPolylinesIfNeeded()
        #expect(viewModel.polylines.isEmpty == false)

        try await viewModel.clearHistory()

        #expect(viewModel.polylines.isEmpty)
        let remaining = try context.fetch(FetchDescriptor<WalkedPoint>())
        #expect(remaining.isEmpty)
    }

    @Test func enableTrackingThrowsWithoutAlwaysAuthorization() async throws {
        let (viewModel, _) = try makeViewModel()

        do {
            try await viewModel.enableTracking()
            Issue.record("expected enableTracking() to throw without Always authorization")
        } catch is StreetsWalkedViewModel.StreetsWalkedError {
            // expected
        }
        #expect(viewModel.isTrackingEnabled == false)
    }

    @Test func dismissTrackingErrorClearsLastTrackingError() async throws {
        let (viewModel, _) = try makeViewModel()
        // Invokes the delegate method directly to seed an error deterministically
        // rather than driving a real CLLocationManager (see LocationPermissionClientTests).
        viewModel.locationManager(CLLocationManager(), didFailWithError: StreetsWalkedViewModel.StreetsWalkedError.authorizationNotGranted)
        await Task.yield()
        #expect(viewModel.lastTrackingError != nil)

        viewModel.dismissTrackingError()

        #expect(viewModel.lastTrackingError == nil)
    }

    private static func location(
        latitude: Double,
        longitude: Double,
        accuracy: CLLocationAccuracy = 10,
        timestamp: Date = Date()
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 10,
            timestamp: timestamp
        )
    }

    // R8. protects: the overlay (and the "No streets yet." card) refresh
    // while walking. fails_when: saved fixes don't reach `polylines` until
    // something else reloads them, or an untrustworthy fix is drawn.
    // no_claim: real CLLocationManager delivery.

    @Test func recordingTwoValidLocationsRefreshesPolylines() throws {
        let (viewModel, context) = try makeViewModel()
        let now = Date()

        viewModel.recordLocations([
            Self.location(latitude: 40.7000, longitude: -73.9900, timestamp: now.addingTimeInterval(-10)),
            Self.location(latitude: 40.7002, longitude: -73.9898, timestamp: now),
        ])

        #expect(viewModel.polylines.count == 1)
        #expect(viewModel.polylines.first?.count == 2)
        #expect(try context.fetch(FetchDescriptor<WalkedPoint>()).count == 2)
    }

    @Test func anInaccurateLocationIsNotRecordedAndPolylinesStayEmpty() throws {
        let (viewModel, context) = try makeViewModel()
        let now = Date()

        viewModel.recordLocations([
            Self.location(latitude: 40.7000, longitude: -73.9900, accuracy: 200, timestamp: now.addingTimeInterval(-10)),
            Self.location(latitude: 40.7002, longitude: -73.9898, accuracy: -1, timestamp: now),
        ])

        #expect(viewModel.polylines.isEmpty)
        #expect(try context.fetch(FetchDescriptor<WalkedPoint>()).isEmpty)
    }

    @Test func emptyBannerDismissalStartsFalseAndIsNotPersisted() throws {
        let suiteName = "StreetsWalkedViewModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makeInMemoryModelContainer()
        let first = StreetsWalkedViewModel(
            locationPermissionClient: LocationPermissionClient(),
            modelContainer: container,
            userDefaults: defaults
        )
        #expect(first.isEmptyBannerDismissed == false)

        first.isEmptyBannerDismissed = true

        // A fresh instance over the same defaults stands in for a relaunch.
        let relaunched = StreetsWalkedViewModel(
            locationPermissionClient: LocationPermissionClient(),
            modelContainer: container,
            userDefaults: defaults
        )
        #expect(relaunched.isEmptyBannerDismissed == false)
    }

    @Test func shouldRequestFullAccuracyOnlyWhenCurrentlyReduced() {
        #expect(StreetsWalkedViewModel.shouldRequestFullAccuracy(currentAccuracyAuthorization: .reducedAccuracy) == true)
        #expect(StreetsWalkedViewModel.shouldRequestFullAccuracy(currentAccuracyAuthorization: .fullAccuracy) == false)
    }
}
