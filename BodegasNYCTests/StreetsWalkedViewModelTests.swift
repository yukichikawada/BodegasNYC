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
}
