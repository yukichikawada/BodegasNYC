//
//  BodegaListViewModelTests.swift
//  BodegasNYCTests
//
//  Same pattern as BodegaMapViewModelTests: real BodegaService +
//  MockURLProtocol, nested under NetworkingTests since it touches the
//  shared stub queue.
//

import Foundation
import Testing

@testable import BodegasNYC

extension NetworkingTests {

@Suite
@MainActor
struct BodegaListViewModelTests {
    private static func bodegaJSON(name: String) -> String {
        """
        {
          "id": "\(UUID().uuidString)",
          "created_by": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
          "name": "\(name)",
          "latitude": 40.7291,
          "longitude": -73.9965,
          "address": null,
          "has_cat": false,
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

    private func makeViewModel() -> BodegaListViewModel {
        BodegaListViewModel(bodegaService: BodegaService(postgrest: makeTestPostgrestClient()))
    }

    @Test func loadInitialIfNeededFetchesAllBodegas() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded()
        #expect(viewModel.loadState == .loading)
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.loadState == .loaded)
        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/rest/v1/bodegas")
        #expect(viewModel.bodegas.count == 1)
    }

    @Test func loadInitialIfNeededIsANoOpOnceAlreadyLoading() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8))
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded()
        viewModel.loadInitialIfNeeded()
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.loadState == .loaded)
    }

    @Test func bodegaWasAddedPrependsAndIsVisibleImmediately() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8))
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded()
        await viewModel.waitForPendingFetchForTesting()
        #expect(viewModel.bodegas.map(\.name) == ["El Sol"])

        let added = try makeTestBodega(name: "Nueva Bodega", latitude: 40.80, longitude: -73.90)
        viewModel.bodegaWasAdded(added)

        #expect(viewModel.bodegas.map(\.name) == ["Nueva Bodega", "El Sol"])
    }

    @Test func aFailedRequestDrivesLoadStateToFailed() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(statusCode: 500, body: Data("{\"message\":\"boom\"}".utf8))
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded()
        await viewModel.waitForPendingFetchForTesting()

        guard case .failed = viewModel.loadState else {
            Issue.record("expected .failed, got \(viewModel.loadState)")
            return
        }
    }
}

}
