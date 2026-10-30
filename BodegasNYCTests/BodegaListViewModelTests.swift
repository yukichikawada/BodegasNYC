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
          "has_atm": false,
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

    /// Eng review R6 (#25): the add flow inserts immediately, so the row
    /// may already be here from a fetch that landed first. One row,
    /// updated in place, not a prepended duplicate. (The other order, an
    /// insert followed by a fetch holding the row, is
    /// `bodegaWasAddedDuringTheInitialFetchAppearsOnceWhenTheFetchAlsoReturnsIt`.)
    @Test func aFetchContainingTheRowThenTheInsertKeepsOneRow() async throws {
        MockURLProtocol.reset()
        let addedID = UUID()
        let body = "[\(Self.bodegaJSON(id: addedID, name: "Server Copy")),\(Self.bodegaJSON(name: "El Sol"))]"
        MockURLProtocol.stub(body: Data(body.utf8))
        let viewModel = makeViewModel()
        viewModel.loadInitialIfNeeded()
        await viewModel.waitForPendingFetchForTesting()

        viewModel.bodegaWasAdded(try makeTestBodega(id: addedID, name: "Nueva Bodega"))
        viewModel.bodegaWasAdded(try makeTestBodega(id: addedID, name: "Nueva Bodega"))

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

    // MARK: List order (#81)

    /// The fix every ordering test measures from (Washington Square).
    private static let here = Coordinate(latitude: 40.7291, longitude: -73.9965)
    private static let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private static func fix(latitude: Double = 40.7291, ageSeconds: TimeInterval = 0) -> UserFix {
        UserFix(
            coordinate: Coordinate(latitude: latitude, longitude: -73.9965),
            horizontalAccuracy: 10,
            timestamp: referenceDate.addingTimeInterval(-ageSeconds)
        )
    }

    /// A bodega `metersNorth` of `here` (about 111 km per degree), created
    /// `createdMinutesAgo` before the reference date.
    private static func bodega(
        _ name: String,
        metersNorth: Double,
        createdMinutesAgo: Double,
        id: UUID = UUID(),
        hasCat: Bool = false
    ) throws -> Bodega {
        var bodega = try makeTestBodega(
            id: id,
            name: name,
            latitude: here.latitude + metersNorth / 111_000,
            longitude: here.longitude,
            hasCat: hasCat
        )
        bodega.createdAt = referenceDate.addingTimeInterval(-createdMinutesAgo * 60)
        return bodega
    }

    /// Loads `bodegas` in this fetch order with no network: each local add
    /// prepends, so they are added back to front.
    private func makeLoadedViewModel(_ bodegas: [Bodega]) -> BodegaListViewModel {
        let viewModel = makeViewModel()
        for bodega in bodegas.reversed() { viewModel.bodegaWasAdded(bodega) }
        return viewModel
    }

    /// protects: nearest first sorts by straight-line metres, equal metres
    /// newest first, then equal metres and `createdAt` by id (spec D2).
    /// fails_when: the sort ignores distance, breaks a metre tie oldest
    /// first, or leaves a full tie to `sorted`'s unstable order.
    /// no_claim: the rows' rendering; fixtures are `makeTestBodega` rows at
    /// known offsets, no mocks.
    @Test func orderedSortsByMetresThenNewestThenID() throws {
        let lowID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highID = try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001"))
        let far = try Self.bodega("Far", metersNorth: 900, createdMinutesAgo: 1)
        let nearOld = try Self.bodega("Near old", metersNorth: 100, createdMinutesAgo: 60)
        let nearNew = try Self.bodega("Near new", metersNorth: 100, createdMinutesAgo: 30)
        let tieHigh = try Self.bodega("Tie high", metersNorth: 300, createdMinutesAgo: 10, id: highID)
        let tieLow = try Self.bodega("Tie low", metersNorth: 300, createdMinutesAgo: 10, id: lowID)
        let fetched = [far, tieHigh, nearOld, tieLow, nearNew]

        let ordered = BodegaListViewModel.ordered(fetched, by: .nearest, from: Self.fix())

        #expect(ordered.map(\.name) == ["Near new", "Near old", "Tie low", "Tie high", "Far"])
    }

    /// protects: without a fix, and under newest first, the list keeps the
    /// fetch order (local additions in front), with no client-side sort
    /// (eng F1).
    /// fails_when: a nil fix sorts, or newest first re-sorts by `createdAt`.
    /// no_claim: none beyond protects.
    @Test func nearestWithoutAFixAndNewestKeepTheFetchOrder() throws {
        // Deliberately not in createdAt order: insertion order is the contract.
        let fetched = [
            try Self.bodega("A", metersNorth: 900, createdMinutesAgo: 50),
            try Self.bodega("B", metersNorth: 100, createdMinutesAgo: 5),
            try Self.bodega("C", metersNorth: 500, createdMinutesAgo: 20)
        ]
        #expect(BodegaListViewModel.ordered(fetched, by: .nearest, from: nil).map(\.name) == ["A", "B", "C"])
        #expect(BodegaListViewModel.ordered(fetched, by: .newest, from: Self.fix()).map(\.name) == ["A", "B", "C"])
    }

    /// protects: the list orders first and filters second, so a filter keeps
    /// the matching rows' nearest order and never re-sorts (spec AC 8).
    /// fails_when: filtering drops the nearest order.
    /// no_claim: none beyond protects.
    @Test func filteredBodegasOrdersBeforeFiltering() throws {
        let viewModel = makeLoadedViewModel([
            try Self.bodega("Far cat", metersNorth: 900, createdMinutesAgo: 1, hasCat: true),
            try Self.bodega("Mid", metersNorth: 400, createdMinutesAgo: 2),
            try Self.bodega("Near cat", metersNorth: 100, createdMinutesAgo: 3, hasCat: true)
        ])
        viewModel.pinOrderingFix(Self.fix(), now: Self.referenceDate)
        #expect(viewModel.filteredBodegas.map(\.name) == ["Near cat", "Mid", "Far cat"])

        viewModel.filter = BodegaFilter(requiredAmenities: [.hasCat])
        #expect(viewModel.filteredBodegas.map(\.name) == ["Near cat", "Far cat"])
    }

    /// protects: a bodega added under nearest first lands at its distance
    /// position, not at the top (spec AC 9).
    /// fails_when: `bodegaWasAdded`'s prepend leaks through under `.nearest`.
    /// no_claim: the pin drop and the add flow (live QA).
    @Test func bodegaWasAddedUnderNearestLandsByDistance() throws {
        let viewModel = makeLoadedViewModel([
            try Self.bodega("Near", metersNorth: 100, createdMinutesAgo: 10),
            try Self.bodega("Far", metersNorth: 900, createdMinutesAgo: 20)
        ])
        viewModel.pinOrderingFix(Self.fix(), now: Self.referenceDate)

        viewModel.bodegaWasAdded(try Self.bodega("New mid", metersNorth: 500, createdMinutesAgo: 0))

        #expect(viewModel.bodegas.first?.name == "New mid")
        #expect(viewModel.filteredBodegas.map(\.name) == ["Near", "New mid", "Far"])
    }

    /// protects: only a fix at most `maxFixAge` old is pinned (eng R1), so an
    /// hour-old kept fix never anchors a visit; exactly 10 minutes still
    /// pins; nil pins nil.
    /// fails_when: the age check is removed, inverted or off by minutes.
    /// no_claim: the provider's timing; `now` is injected.
    @Test func pinOrderingFixKeepsANineMinuteFixAndDropsAnElevenMinuteFix() {
        let viewModel = makeViewModel()
        let nineMinutes = Self.fix(ageSeconds: 9 * 60)
        viewModel.pinOrderingFix(nineMinutes, now: Self.referenceDate)
        #expect(viewModel.orderingFix == nineMinutes)

        // The boundary is inclusive, like the provider's own expiry check.
        let tenMinutes = Self.fix(ageSeconds: UserLocationProvider.maxFixAge)
        viewModel.pinOrderingFix(tenMinutes, now: Self.referenceDate)
        #expect(viewModel.orderingFix == tenMinutes)

        viewModel.pinOrderingFix(Self.fix(ageSeconds: 11 * 60), now: Self.referenceDate)
        #expect(viewModel.orderingFix == nil)

        viewModel.pinOrderingFix(Self.fix(), now: Self.referenceDate)
        viewModel.pinOrderingFix(nil, now: Self.referenceDate)
        #expect(viewModel.orderingFix == nil)
    }

    /// protects: the first fix after an unpinned start is adopted, later
    /// fixes are ignored while pinned, a lost fix un-pins, and a pin after
    /// that takes the current fix (spec D2).
    /// fails_when: `noteFix` replaces a pinned fix (rows move under the
    /// reader), ignores the first fix, or keeps a lost one.
    /// no_claim: which SwiftUI events call it (live QA AC 4 to 7).
    @Test func noteFixAdoptsWhenUnpinnedIgnoresWhenPinnedAndUnpinsOnNil() {
        let viewModel = makeViewModel()
        let first = Self.fix()
        let moved = Self.fix(latitude: 40.74)

        viewModel.noteFix(first)
        #expect(viewModel.orderingFix == first)

        viewModel.noteFix(moved)
        #expect(viewModel.orderingFix == first)

        viewModel.noteFix(nil)
        #expect(viewModel.orderingFix == nil)

        viewModel.noteFix(first)
        viewModel.pinOrderingFix(moved, now: Self.referenceDate)
        #expect(viewModel.orderingFix == moved)
    }

    /// protects: a fix adopted mid-scroll waits for the scroll to rest
    /// (design D4), a newer one replaces it, a pin or a loss drops it, and
    /// only an applied adoption is recorded for VoiceOver, with the first
    /// row it displaced (design D3).
    /// fails_when: the order changes while scrolling, a stale pending fix is
    /// applied after a pin or a loss, or a pin is announced as automatic.
    /// no_claim: that `BodegaListView` reports the real scroll phase (live QA).
    @Test func anAdoptionWaitsForTheScrollToRest() throws {
        let viewModel = makeLoadedViewModel([
            try Self.bodega("Far", metersNorth: 900, createdMinutesAgo: 1),
            try Self.bodega("Near", metersNorth: 100, createdMinutesAgo: 2)
        ])
        let farID = viewModel.bodegas[0].id

        viewModel.scrollPhaseDidChange(isIdle: false)
        viewModel.noteFix(Self.fix(latitude: 40.75))
        viewModel.noteFix(Self.fix())
        #expect(viewModel.orderingFix == nil)
        #expect(viewModel.lastAutomaticReorder == nil)

        viewModel.scrollPhaseDidChange(isIdle: true)
        #expect(viewModel.orderingFix == Self.fix())
        #expect(viewModel.filteredBodegas.map(\.name) == ["Near", "Far"])
        #expect(viewModel.lastAutomaticReorder == .init(serial: 1, previousFirstID: farID))

        // A loss drops a pending adoption.
        viewModel.noteFix(nil)
        viewModel.scrollPhaseDidChange(isIdle: false)
        viewModel.noteFix(Self.fix())
        viewModel.noteFix(nil)
        viewModel.scrollPhaseDidChange(isIdle: true)
        #expect(viewModel.orderingFix == nil)

        // So does a pin, which is never recorded as automatic.
        viewModel.scrollPhaseDidChange(isIdle: false)
        viewModel.noteFix(Self.fix())
        viewModel.pinOrderingFix(nil, now: Self.referenceDate)
        viewModel.scrollPhaseDidChange(isIdle: true)
        #expect(viewModel.orderingFix == nil)
        #expect(viewModel.lastAutomaticReorder?.serial == 1)
    }

    /// protects: the cross-fade key changes exactly when the order can (a
    /// pin, an adoption, a loss, an order change) and not on a value-only
    /// fix, a filter change, or any fix under newest first (design D4).
    /// fails_when: a later fix or a filter change would cross-fade the list,
    /// or an adoption would not.
    /// no_claim: the animation itself (live QA).
    @Test func reorderKeyChangesOnlyWhenTheOrderCan() {
        let viewModel = makeViewModel()
        var key = viewModel.reorderKey

        viewModel.noteFix(Self.fix())
        #expect(viewModel.reorderKey != key, "adopt")
        key = viewModel.reorderKey

        viewModel.noteFix(Self.fix(latitude: 40.74))
        #expect(viewModel.reorderKey == key, "value-only fix")

        viewModel.filter = BodegaFilter(requiredAmenities: [.hasCat])
        #expect(viewModel.reorderKey == key, "filter change")

        viewModel.pinOrderingFix(Self.fix(latitude: 40.74), now: Self.referenceDate)
        #expect(viewModel.reorderKey != key, "pin")
        key = viewModel.reorderKey

        viewModel.noteFix(nil)
        #expect(viewModel.reorderKey != key, "loss")
        key = viewModel.reorderKey

        viewModel.order = .newest
        #expect(viewModel.reorderKey != key, "order change")
        key = viewModel.reorderKey

        let announced = viewModel.lastAutomaticReorder
        viewModel.noteFix(Self.fix())
        #expect(viewModel.reorderKey == key, "fix under newest first")
        #expect(viewModel.lastAutomaticReorder == announced, "no announcement under newest first")
    }

    /// protects: the nearest sort is cached (review item 5): reads, a
    /// value-only fix and a filter change reuse it; a pin, an order change or
    /// new rows recompute it.
    /// fails_when: `filteredBodegas` sorts on every read, or a cached order
    /// goes stale after the rows or the pin change.
    /// no_claim: render cost; counts sorts through a DEBUG-only counter.
    @Test func theNearestSortIsCachedUntilItsInputsChange() throws {
        let viewModel = makeLoadedViewModel([
            try Self.bodega("Far", metersNorth: 900, createdMinutesAgo: 1),
            try Self.bodega("Near", metersNorth: 100, createdMinutesAgo: 2)
        ])
        viewModel.pinOrderingFix(Self.fix(), now: Self.referenceDate)
        let sorts = viewModel.distanceSortCountForTesting

        _ = viewModel.filteredBodegas
        _ = viewModel.filteredBodegas
        viewModel.noteFix(Self.fix(latitude: 40.74))
        viewModel.filter = BodegaFilter(searchText: "ar")
        #expect(viewModel.filteredBodegas.map(\.name) == ["Near", "Far"])
        #expect(viewModel.distanceSortCountForTesting == sorts)

        viewModel.bodegaWasAdded(try Self.bodega("Mid", metersNorth: 500, createdMinutesAgo: 0))
        #expect(viewModel.distanceSortCountForTesting == sorts + 1)
        #expect(viewModel.filteredBodegas.map(\.name) == ["Near", "Far"])
        viewModel.filter = .none
        #expect(viewModel.filteredBodegas.map(\.name) == ["Near", "Mid", "Far"])
    }
}

}
