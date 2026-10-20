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
    private static func bodegaJSON(id: UUID = UUID(), name: String, hasCat: Bool = false) -> String {
        """
        {
          "id": "\(id.uuidString)",
          "created_by": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
          "name": "\(name)",
          "latitude": 40.7291,
          "longitude": -73.9965,
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

    /// protects: the load-failed state's Retry actually reloads.
    /// fails_when: retry leaves `.failed` in place or never fetches again.
    /// no_claim: the button wiring in `BodegaListView`.
    @Test func retryAfterAFailedLoadRefetchesAndLoadsTheRows() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(statusCode: 500, body: Data("{\"message\":\"boom\"}".utf8))
        let body = "[\(Self.bodegaJSON(name: "El Sol")),\(Self.bodegaJSON(name: "La Luna"))]"
        MockURLProtocol.stub(body: Data(body.utf8))
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded()
        await viewModel.waitForPendingFetchForTesting()
        guard case .failed = viewModel.loadState else {
            Issue.record("expected .failed, got \(viewModel.loadState)")
            return
        }

        viewModel.retry()
        #expect(viewModel.loadState == .loading)
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.bodegas.map(\.name) == ["El Sol", "La Luna"])
    }

    @Test func retryIsANoOpOnceLoaded() async throws {
        MockURLProtocol.reset()
        let requestCount = Captured(0)
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8)) { _ in
            requestCount.set(requestCount.get() + 1)
        }
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded()
        await viewModel.waitForPendingFetchForTesting()

        viewModel.retry()
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.loadState == .loaded)
        #expect(requestCount.get() == 1)
    }

    @Test func settingAFilterNarrowsFilteredBodegasWithoutRefetching() async throws {
        MockURLProtocol.reset()
        let requestCount = Captured(0)
        let body = "[\(Self.bodegaJSON(name: "Cat Deli", hasCat: true)),\(Self.bodegaJSON(name: "Plain Deli"))]"
        MockURLProtocol.stub(body: Data(body.utf8)) { _ in
            requestCount.set(requestCount.get() + 1)
        }
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded()
        await viewModel.waitForPendingFetchForTesting()
        #expect(viewModel.filteredBodegas.count == 2)

        viewModel.filter = BodegaFilter(requiredAmenities: [.hasCat])
        #expect(viewModel.filteredBodegas.map(\.name) == ["Cat Deli"])
        // The unfiltered set is untouched, so the view can still tell "no
        // matches" apart from "nothing loaded".
        #expect(viewModel.bodegas.count == 2)

        viewModel.filter = BodegaFilter(searchText: "plain")
        #expect(viewModel.filteredBodegas.map(\.name) == ["Plain Deli"])

        viewModel.filter = BodegaFilter(requiredAmenities: [.hasCat], searchText: "plain")
        #expect(viewModel.filteredBodegas.isEmpty)

        await viewModel.waitForPendingFetchForTesting()
        #expect(viewModel.loadState == .loaded)
        #expect(requestCount.get() == 1)
    }

    @Test func bodegaWasUpdatedReplacesByIDInPlaceAndRespectsTheFilter() async throws {
        MockURLProtocol.reset()
        let requestCount = Captured(0)
        let body = "[\(Self.bodegaJSON(name: "Cat Deli", hasCat: true)),\(Self.bodegaJSON(name: "Plain Deli"))]"
        MockURLProtocol.stub(body: Data(body.utf8)) { _ in
            requestCount.set(requestCount.get() + 1)
        }
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded()
        await viewModel.waitForPendingFetchForTesting()
        viewModel.filter = BodegaFilter(requiredAmenities: [.hasCat])
        #expect(viewModel.filteredBodegas.map(\.name) == ["Cat Deli"])
        var edited = try #require(viewModel.bodegas.last)
        edited.name = "Plain Deli (now with cat)"
        edited.hasCat = true

        viewModel.bodegaWasUpdated(edited)
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.bodegas.map(\.name) == ["Cat Deli", "Plain Deli (now with cat)"])
        #expect(viewModel.filteredBodegas.count == 2)
        #expect(requestCount.get() == 1)
    }

    /// Regression for issue #35 (and, before it, a QA finding that the same
    /// scenario stranded `loadState` at `.loading`): adding a bodega while
    /// the initial fetch is in flight used to drop that fetch, leaving the
    /// list holding only the added bodega. The fetch now lands and the
    /// added row is merged in front of its result. The test is
    /// `@MainActor`, so the fetch's Task can't start before the synchronous
    /// `bodegaWasAdded` call right after `loadInitialIfNeeded`.
    @Test func bodegaWasAddedDuringTheInitialFetchIsMergedIntoItsResult() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8))
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded()
        #expect(viewModel.loadState == .loading)
        viewModel.bodegaWasAdded(try makeTestBodega(name: "Nueva Bodega"))
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.bodegas.map(\.name) == ["Nueva Bodega", "El Sol"])
    }

    /// The fetch can race the insert and already contain the added row:
    /// it must appear once, at the front, with the locally held data.
    @Test func bodegaWasAddedDuringTheInitialFetchAppearsOnceWhenTheFetchAlsoReturnsIt() async throws {
        MockURLProtocol.reset()
        let addedID = UUID()
        let body = "[\(Self.bodegaJSON(name: "El Sol")),\(Self.bodegaJSON(id: addedID, name: "Server Copy"))]"
        MockURLProtocol.stub(body: Data(body.utf8))
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded()
        viewModel.bodegaWasAdded(try makeTestBodega(id: addedID, name: "Nueva Bodega"))
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.bodegas.map(\.name) == ["Nueva Bodega", "El Sol"])
        #expect(viewModel.bodegas.filter { $0.id == addedID }.count == 1)
    }

    @Test func bodegaWasUpdatedDuringTheInitialFetchWinsOverTheFetchedCopy() async throws {
        MockURLProtocol.reset()
        let editedID = UUID()
        let body = "[\(Self.bodegaJSON(name: "El Sol")),\(Self.bodegaJSON(id: editedID, name: "Plain Deli"))]"
        MockURLProtocol.stub(body: Data(body.utf8))
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded()
        viewModel.bodegaWasUpdated(try makeTestBodega(id: editedID, name: "Renamed Deli", hasCat: true))
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.bodegas.map(\.name) == ["El Sol", "Renamed Deli"])
        #expect(viewModel.bodegas.last?.hasCat == true)
    }

    /// An add followed by an edit of that same bodega, both during the
    /// initial fetch, keeps one row at the front with the edited data.
    @Test func bodegaAddedThenUpdatedDuringTheInitialFetchKeepsTheEditAtTheFront() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8))
        let viewModel = makeViewModel()
        let addedID = UUID()

        viewModel.loadInitialIfNeeded()
        viewModel.bodegaWasAdded(try makeTestBodega(id: addedID, name: "Nueva Bodega"))
        viewModel.bodegaWasUpdated(try makeTestBodega(id: addedID, name: "Nueva Bodega (edited)"))
        await viewModel.waitForPendingFetchForTesting()

        #expect(viewModel.bodegas.map(\.name) == ["Nueva Bodega (edited)", "El Sol"])
    }

    /// The first fetch failing after an add: `loadState` must settle on
    /// `.failed` (not stay `.loading`), and the optimistic row stays held.
    /// The list has no way to refetch once past `.idle`, so the buffer being
    /// cleared on failure is exercised by the `BodegaMapViewModelTests`
    /// counterpart, which can trigger a second fetch.
    @Test func bodegaWasAddedDuringAFailingInitialFetchSettlesOnFailed() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(statusCode: 500, body: Data("{\"message\":\"boom\"}".utf8))
        let viewModel = makeViewModel()

        viewModel.loadInitialIfNeeded()
        viewModel.bodegaWasAdded(try makeTestBodega(name: "Nueva Bodega"))
        #expect(viewModel.loadState == .loading)
        await viewModel.waitForPendingFetchForTesting()

        guard case .failed = viewModel.loadState else {
            Issue.record("expected .failed, got \(viewModel.loadState)")
            return
        }
        #expect(viewModel.bodegas.map(\.name) == ["Nueva Bodega"])
        // Still a no-op: `.failed` is past `.idle`, so nothing restarts a
        // fetch that could leave the state at `.loading`.
        viewModel.loadInitialIfNeeded()
        await viewModel.waitForPendingFetchForTesting()
        guard case .failed = viewModel.loadState else {
            Issue.record("expected .failed, got \(viewModel.loadState)")
            return
        }
    }

    @Test func bodegaWasUpdatedIgnoresABodegaThatIsNotLoaded() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON(name: "El Sol"))]".utf8))
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded()
        await viewModel.waitForPendingFetchForTesting()

        viewModel.bodegaWasUpdated(try makeTestBodega(name: "Elsewhere"))

        #expect(viewModel.bodegas.map(\.name) == ["El Sol"])
    }
}

}
