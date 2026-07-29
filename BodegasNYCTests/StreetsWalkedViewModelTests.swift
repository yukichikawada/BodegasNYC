//
//  StreetsWalkedViewModelTests.swift
//  BodegasNYCTests
//
//  Constructs the real StreetsWalkedViewModel with an in-memory
//  ModelContainer — never calls enableTracking() successfully or touches
//  CLLocationManager.startUpdatingLocation(); the live delegate/background
//  tracking wiring itself isn't unit-testable (same boundary
//  LocationPermissionClientTests already draws), only the SwiftData
//  persistence/segmenting logic layered on top of it.
//

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
}
