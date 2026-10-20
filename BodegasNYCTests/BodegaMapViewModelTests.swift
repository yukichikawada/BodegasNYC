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
        id: UUID = UUID(),
        name: String,
        latitude: Double = 40.7291,
        longitude: Double = -73.9965,
        hasCat: Bool = false
    ) -> String {
        """
        {
          "id": "\(id.uuidString)",
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

    private static func pins(in items: [MapDisplayItem]) -> [Bodega] {
        items.compactMap { item in
            if case .pin(let bodega) = item { return bodega }
            return nil
        }
    }

    @Test func bodegaWasUpdatedReplacesByIDWithoutRefetching() async throws {
        MockURLProtocol.reset()
        let requestCount = Captured(0)
        let body = "[\(Self.bodegaJSON(name: "Cat Deli", hasCat: true)),"
            + "\(Self.bodegaJSON(name: "Plain Deli", latitude: 40.80, longitude: -73.90))]"
        MockURLProtocol.stub(body: Data(body.utf8)) { _ in
            requestCount.set(requestCount.get() + 1)
        }
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        await viewModel.waitForPendingFetchForTesting()
        var edited = try #require(Self.pins(in: viewModel.displayItems).first { $0.name == "Plain Deli" })
        edited.name = "Renamed Deli"

        viewModel.bodegaWasUpdated(edited)
        await viewModel.waitForPendingFetchForTesting()

        let pins = Self.pins(in: viewModel.displayItems)
        #expect(pins.count == 2)
        #expect(Set(pins.map(\.name)) == ["Cat Deli", "Renamed Deli"])
        #expect(pins.first { $0.id == edited.id }?.name == "Renamed Deli")
        #expect(requestCount.get() == 1)
    }

    @Test func bodegaWasUpdatedReappliesTheActiveFilter() async throws {
        MockURLProtocol.reset()
        let body = "[\(Self.bodegaJSON(name: "Cat Deli", hasCat: true)),"
            + "\(Self.bodegaJSON(name: "Plain Deli", latitude: 40.80, longitude: -73.90))]"
        MockURLProtocol.stub(body: Data(body.utf8))
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        await viewModel.waitForPendingFetchForTesting()
        var edited = try #require(Self.pins(in: viewModel.displayItems).first { $0.name == "Plain Deli" })
        viewModel.filter = BodegaFilter(requiredAmenities: [.hasCat])
        #expect(Self.pins(in: viewModel.displayItems).map(\.name) == ["Cat Deli"])

        edited.hasCat = true
        viewModel.bodegaWasUpdated(edited)

        #expect(Set(Self.pins(in: viewModel.displayItems).map(\.name)) == ["Cat Deli", "Plain Deli"])
    }

    /// Regression for a QA finding: the generation bump drops an in-flight
    /// fetch, and that fetch used to leave `loadState` stuck at `.loading`.
    /// The test is `@MainActor`, so the refetch's Task can't start before
    /// the synchronous `bodegaWasUpdated` call right after it.
    @Test func bodegaWasUpdatedDuringAnInFlightRefetchSettlesLoadStateAndKeepsTheEdit() async throws {
        MockURLProtocol.reset()
        let body = "[\(Self.bodegaJSON(name: "Cat Deli", hasCat: true)),"
            + "\(Self.bodegaJSON(name: "Plain Deli", latitude: 40.80, longitude: -73.90))]"
        MockURLProtocol.stub(body: Data(body.utf8))
        // The superseded `.nearby` response. If it were applied, it would
        // wipe both pins.
        MockURLProtocol.stub(body: Data("[]".utf8))
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        await viewModel.waitForPendingFetchForTesting()
        var edited = try #require(Self.pins(in: viewModel.displayItems).first { $0.name == "Plain Deli" })
        edited.name = "Renamed Deli"

        viewModel.browseModeDidChange(.nearby, currentRegion: Self.sampleRegion)
        #expect(viewModel.loadState == .loading)
        viewModel.bodegaWasUpdated(edited)
        #expect(viewModel.loadState == .loaded)
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.loadState == .loaded)
        #expect(Set(Self.pins(in: viewModel.displayItems).map(\.name)) == ["Cat Deli", "Renamed Deli"])
    }

    @Test func bodegaWasAddedDuringAnInFlightRefetchSettlesLoadState() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8))
        MockURLProtocol.stub(body: Data("[]".utf8))
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        await viewModel.waitForPendingFetchForTesting()

        viewModel.browseModeDidChange(.nearby, currentRegion: Self.sampleRegion)
        viewModel.bodegaWasAdded(try makeTestBodega(name: "Nueva Bodega", latitude: 40.80, longitude: -73.90))
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.displayItems.count == 2)
    }

    /// Regression for issue #35: adding a bodega while the initial `.all`
    /// fetch is in flight used to drop that fetch, leaving only the added
    /// pin. The fetch now lands and the added row is merged into its
    /// result. Coordinates differ so the two land in separate grid cells
    /// and render as two pins, not one cluster.
    @Test func bodegaWasAddedDuringTheInitialFetchIsMergedIntoItsResult() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8))
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        #expect(viewModel.loadState == .loading)
        viewModel.bodegaWasAdded(try makeTestBodega(name: "Nueva Bodega", latitude: 40.80, longitude: -73.90))
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.loadState == .loaded)
        let pins = Self.pins(in: viewModel.displayItems)
        #expect(pins.count == 2)
        #expect(Set(pins.map(\.name)) == ["El Sol", "Nueva Bodega"])
    }

    @Test func bodegaWasAddedDuringTheInitialFetchAppearsOnceWhenTheFetchAlsoReturnsIt() async throws {
        MockURLProtocol.reset()
        let addedID = UUID()
        let body = "[\(Self.bodegaJSON(name: "El Sol")),"
            + "\(Self.bodegaJSON(id: addedID, name: "Server Copy", latitude: 40.80, longitude: -73.90))]"
        MockURLProtocol.stub(body: Data(body.utf8))
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        viewModel.bodegaWasAdded(
            try makeTestBodega(id: addedID, name: "Nueva Bodega", latitude: 40.80, longitude: -73.90)
        )
        await viewModel.waitForPendingFetchForTesting()

        let pins = Self.pins(in: viewModel.displayItems)
        #expect(pins.count == 2)
        #expect(pins.filter { $0.id == addedID }.map(\.name) == ["Nueva Bodega"])
    }

    @Test func bodegaWasUpdatedDuringTheInitialFetchWinsOverTheFetchedCopy() async throws {
        MockURLProtocol.reset()
        let editedID = UUID()
        let body = "[\(Self.bodegaJSON(name: "Cat Deli", hasCat: true)),"
            + "\(Self.bodegaJSON(id: editedID, name: "Plain Deli", latitude: 40.80, longitude: -73.90))]"
        MockURLProtocol.stub(body: Data(body.utf8))
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        viewModel.bodegaWasUpdated(
            try makeTestBodega(id: editedID, name: "Renamed Deli", latitude: 40.80, longitude: -73.90)
        )
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.loadState == .loaded)
        let pins = Self.pins(in: viewModel.displayItems)
        #expect(pins.count == 2)
        #expect(pins.first { $0.id == editedID }?.name == "Renamed Deli")
    }

    @Test func bodegaAddedThenUpdatedDuringTheInitialFetchKeepsTheEditAtTheFront() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8))
        let viewModel = makeViewModel()
        let addedID = UUID()

        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        viewModel.bodegaWasAdded(
            try makeTestBodega(id: addedID, name: "Nueva Bodega", latitude: 40.80, longitude: -73.90)
        )
        viewModel.bodegaWasUpdated(
            try makeTestBodega(id: addedID, name: "Nueva Bodega (edited)", latitude: 40.80, longitude: -73.90)
        )
        await viewModel.waitForPendingFetchForTesting()

        let pins = Self.pins(in: viewModel.displayItems)
        #expect(pins.count == 2)
        #expect(pins.filter { $0.id == addedID }.map(\.name) == ["Nueva Bodega (edited)"])
        #expect(Set(pins.map(\.name)) == ["El Sol", "Nueva Bodega (edited)"])
    }

    /// The first fetch failing after an add: `loadState` settles on
    /// `.failed`, and the buffered add is cleared, so the next successful
    /// fetch shows only what it returned rather than re-applying the add.
    @Test func bodegaWasAddedDuringAFailingInitialFetchSettlesOnFailedAndClearsTheBuffer() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(statusCode: 500, body: Data("{\"message\":\"boom\"}".utf8))
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8))
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        viewModel.bodegaWasAdded(try makeTestBodega(name: "Nueva Bodega", latitude: 40.80, longitude: -73.90))
        #expect(viewModel.loadState == .loading)
        await viewModel.waitForPendingFetchForTesting()

        guard case .failed = viewModel.loadState else {
            Issue.record("expected .failed, got \(viewModel.loadState)")
            return
        }

        viewModel.browseModeDidChange(.nearby, currentRegion: Self.sampleRegion)
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.loadState == .loaded)
        #expect(Self.pins(in: viewModel.displayItems).map(\.name) == ["El Sol"])
    }

    @Test func bodegaWasUpdatedIgnoresABodegaThatIsNotLoaded() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8))
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded(region: Self.sampleRegion)
        await viewModel.waitForPendingFetchForTesting()

        viewModel.bodegaWasUpdated(try makeTestBodega(name: "Elsewhere", latitude: 40.80, longitude: -73.90))

        #expect(Self.pins(in: viewModel.displayItems).map(\.name) == ["El Sol"])
    }

    // Not covered here: a second in-flight fetch superseding an older one
    // (the `currentFetchGeneration` guard in `BodegaMapViewModel.refetch`).
    // Reliably forcing that race with `MockURLProtocol`'s instant-response
    // stubs would need dedicated held-open-response test infrastructure —
    // see the plan's verification notes. Exercised manually instead (rapid
    // panning in Simulator).
}

}
