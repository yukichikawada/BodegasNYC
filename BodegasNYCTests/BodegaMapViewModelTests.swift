//
//  BodegaMapViewModelTests.swift
//  BodegasNYCTests
//
//  Follows BodegaServiceTests's pattern (makeTestPostgrestClient() +
//  MockURLProtocol) rather than mocking BodegaService itself, consistent
//  with this codebase's no-new-protocol-abstraction-layer testing
//  convention.
//

import Foundation
import MapKit
import PostgREST
import Testing

@testable import BodegasNYC

extension NetworkingTests {

@Suite
@MainActor
struct BodegaMapViewModelTests {
    private static let sampleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7291, longitude: -73.9965),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    private static func bodegaJSON(
        name: String,
        latitude: Double = 40.7291,
        longitude: Double = -73.9965,
        hasCat: Bool = false
    ) -> String {
        """
        {
          "id": "\(UUID().uuidString)",
          "created_by": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
          "name": "\(name)",
          "latitude": \(latitude),
          "longitude": \(longitude),
          "address": null,
          "has_cat": \(hasCat),
          "serves_hot_food": false,
          "sells_cigarettes": false,
          "sells_beer": false,
          "sells_lotto": false,
          "hours": null,
          "is_hidden": false,
          "created_at": "2026-07-21T18:30:00.123456+00:00",
          "updated_at": "2026-07-22T00:15:59.000042+00:00"
        }
        """
    }

    private func makeViewModel() -> BodegaMapViewModel {
        BodegaMapViewModel(bodegaService: BodegaService(postgrest: makeTestPostgrestClient()))
    }

    @Test func allModeFetchesEverythingNotTheNearbyRPC() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        // Flips synchronously, before the fetch Task itself has run — see
        // the comment in `BodegaMapViewModel.refetch`.
        #expect(viewModel.loadState == .loading)
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.loadState == .loaded)
        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/rest/v1/bodegas")
        #expect(viewModel.displayItems.count == 1)
    }

    @Test func loadInitialIfNeededIsANoOpOnceAlreadyLoading() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8))
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.loadState == .loaded)
    }

    @Test func nearbyModeCallsTheRPCWithARadiusDerivedFromRegionSpan() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = makeViewModel()

        viewModel.browseModeDidChange(.nearby, currentRegion: Self.sampleRegion)
        await viewModel.waitForPendingFetchForTesting()

        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/rpc/nearby_bodegas")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["lat"] as? Double == Self.sampleRegion.center.latitude)
        #expect(json["long"] as? Double == Self.sampleRegion.center.longitude)
        let radius = try #require(json["radius_meters"] as? Double)
        #expect((200...5000).contains(radius))
    }

    @Test func radiusClampsToTheFloorForATinySpan() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = makeViewModel()
        let tinyRegion = MKCoordinateRegion(
            center: Self.sampleRegion.center,
            span: MKCoordinateSpan(latitudeDelta: 0.0000001, longitudeDelta: 0.0000001)
        )

        viewModel.browseModeDidChange(.nearby, currentRegion: tinyRegion)
        await viewModel.waitForPendingFetchForTesting()

        let request = try #require(capturedRequest.get())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["radius_meters"] as? Double == 200)
    }

    @Test func radiusClampsToTheCeilingForAHugeSpan() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = makeViewModel()
        let hugeRegion = MKCoordinateRegion(
            center: Self.sampleRegion.center,
            span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
        )

        viewModel.browseModeDidChange(.nearby, currentRegion: hugeRegion)
        await viewModel.waitForPendingFetchForTesting()

        let request = try #require(capturedRequest.get())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["radius_meters"] as? Double == 5000)
    }

    @Test func aFailedRequestDrivesLoadStateToFailed() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(statusCode: 500, body: Data("{\"message\":\"boom\"}".utf8))
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        await viewModel.waitForPendingFetchForTesting()

        guard case .failed = viewModel.loadState else {
            Issue.record("expected .failed, got \(viewModel.loadState)")
            return
        }
    }

    @Test func bodegaWasAddedPrependsAndIsVisibleImmediately() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8))
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        await viewModel.waitForPendingFetchForTesting()
        #expect(viewModel.displayItems.count == 1)

        // Far enough from `sampleRegion`'s center to land in a different
        // grid cell than the already-loaded bodega — otherwise clustering
        // (see `BodegaClustering`) would merge them into a single `.cluster`
        // item instead of two separate pins.
        let added = try makeTestBodega(name: "Nueva Bodega", latitude: 40.80, longitude: -73.90)
        viewModel.bodegaWasAdded(added)

        #expect(viewModel.displayItems.count == 2)
    }

    @Test func settingAFilterReclustersWithoutRefetching() async throws {
        MockURLProtocol.reset()
        let requestCount = Captured(0)
        // Two bodegas in different grid cells (same separation as
        // `bodegaWasAddedPrependsAndIsVisibleImmediately`) so they render as
        // two separate pins rather than one cluster.
        let body = "[\(Self.bodegaJSON(name: "Cat Deli", hasCat: true)),"
            + "\(Self.bodegaJSON(name: "Plain Deli", latitude: 40.80, longitude: -73.90))]"
        MockURLProtocol.stub(body: Data(body.utf8)) { _ in
            requestCount.set(requestCount.get() + 1)
        }
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        await viewModel.waitForPendingFetchForTesting()
        #expect(viewModel.displayItems.count == 2)

        viewModel.filter = BodegaFilter(requiredAmenities: [.hasCat])
        await viewModel.waitForPendingFetchForTesting()

        let pinNames = viewModel.displayItems.compactMap { item -> String? in
            if case .pin(let bodega) = item { return bodega.name }
            return nil
        }
        #expect(pinNames == ["Cat Deli"])
        #expect(viewModel.loadState == .loaded)

        viewModel.filter = .none
        #expect(viewModel.displayItems.count == 2)
        #expect(requestCount.get() == 1)
    }

    // Not covered here: a second in-flight fetch superseding an older one
    // (the `currentFetchGeneration` guard in `BodegaMapViewModel.refetch`).
    // Reliably forcing that race with `MockURLProtocol`'s instant-response
    // stubs would need dedicated held-open-response test infrastructure —
    // see the plan's verification notes. Exercised manually instead (rapid
    // panning in Simulator).
}

}
