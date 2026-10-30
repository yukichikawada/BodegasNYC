//
//  AddBodegaViewModelTests.swift
//  BodegasNYCTests
//
//  Follows BodegaServiceTests's pattern (makeTestPostgrestClient() +
//  MockURLProtocol) for the BodegaService side, and SessionStoreTests's
//  pattern (makeTestAuthClient/makeTestSession) for the SessionStore side.
//

import Auth
import Foundation
import PostgREST
import Testing

@testable import BodegasNYC

extension NetworkingTests {

@Suite
@MainActor
struct AddBodegaViewModelTests {
    private static let sampleCoordinate = Coordinate(latitude: 40.7291, longitude: -73.9965)

    private static let bodegaJSON = """
    {
      "id": "8f14e45f-ceea-467e-adc9-15476f4eaa15",
      "created_by": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
      "name": "El Sol Deli & Grocery",
      "latitude": 40.7291,
      "longitude": -73.9965,
      "address": null,
      "has_cat": false,
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

    private func makeViewModel(
        session: Session?,
        clock: any Clock<Duration> = ContinuousClock()
    ) throws -> AddBodegaViewModel {
        AddBodegaViewModel(
            coordinate: Self.sampleCoordinate,
            bodegaService: BodegaService(postgrest: makeTestPostgrestClient()),
            sessionStore: SessionStore(auth: try makeTestAuthClient(session: session)),
            clock: clock
        )
    }

    /// The duplicate check's RPC response when nothing is within 50 m (#20).
    private static let nothingNearby = Data("[]".utf8)

    @Test func submitIsRejectedWithoutATrimmedName() async throws {
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "   "

        viewModel.submit()

        #expect(viewModel.submissionState == .failed("Please enter a name."))
    }

    /// protects: the insert body carries `created_by` from the session, the
    /// EWKT location and, since #141, `has_atm` from the form.
    /// fails_when: any of the three is missing or wrong in the POST body.
    /// no_claim: the other data point keys (covered by the PATCH key set).
    @Test func submitSendsCreatedByFromTheSessionAndEWKTLocation() async throws {
        MockURLProtocol.reset()
        let userID = UUID()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Self.nothingNearby)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeViewModel(session: makeTestSession(userID: userID))
        viewModel.name = "El Sol Deli & Grocery"
        viewModel.hasAtm = true

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        guard case .submitted = viewModel.submissionState else {
            Issue.record("expected .submitted, got \(viewModel.submissionState)")
            return
        }
        let request = try #require(capturedRequest.get())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["created_by"] as? String == userID.uuidString)
        #expect(json["location"] as? String == "SRID=4326;POINT(-73.9965 40.7291)")
        #expect(json["has_atm"] as? Bool == true)
    }

    @Test func submitOmitsAddressWhenBlank() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Self.nothingNearby)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "El Sol"
        viewModel.address = "   "

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        let request = try #require(capturedRequest.get())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["address"] == nil)
    }

    @Test func submitOmitsHoursWhenAllDaysBlank() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Self.nothingNearby)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "El Sol"

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        let request = try #require(capturedRequest.get())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["hours"] == nil)
    }

    // protects=no insert without a session, and the check still runs first
    // (#20 D1); fails_when=a POST to /rest/v1/bodegas appears, or the one
    // request is not the RPC; no_claim=none beyond protects.
    @Test func submitRequiresSignInWhenNoSessionAndSendsOnlyTheNearbyCheck() async throws {
        MockURLProtocol.reset()
        let log = RequestLog()
        MockURLProtocol.stub(body: Self.nothingNearby, onRequest: log.record)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8), onRequest: log.record)
        let viewModel = try makeViewModel(session: nil)
        viewModel.name = "El Sol"

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(viewModel.submissionState == .signInRequired)
        #expect(log.paths == [Self.rpcPath])
    }

    @Test func dismissSignInPromptResetsToIdleSoASecondSubmitReasksForSignIn() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Self.nothingNearby)
        MockURLProtocol.stub(body: Self.nothingNearby)
        let viewModel = try makeViewModel(session: nil)
        viewModel.name = "El Sol"

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()
        #expect(viewModel.submissionState == .signInRequired)

        // Regression: swiping away the sign-in sheet without signing in,
        // then tapping Submit again, must re-present it — a bug caught in
        // manual Simulator testing where `AddBodegaView`'s
        // `.onChange(of: submissionState)` never fired a second time
        // because `.signInRequired` was already the current value.
        viewModel.dismissSignInPrompt()
        #expect(viewModel.submissionState == .idle)

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()
        #expect(viewModel.submissionState == .signInRequired)
    }

    @Test func dismissSignInPromptIsANoOpWhenNotCurrentlySignInRequired() async throws {
        let viewModel = try makeViewModel(session: makeTestSession())
        #expect(viewModel.submissionState == .idle)

        viewModel.dismissSignInPrompt()

        #expect(viewModel.submissionState == .idle)
    }

    @Test func aFailedInsertDrivesSubmissionStateToFailed() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Self.nothingNearby)
        MockURLProtocol.stub(statusCode: 500, body: Data("{\"message\":\"boom\"}".utf8))
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "El Sol"

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        guard case .failed = viewModel.submissionState else {
            Issue.record("expected .failed, got \(viewModel.submissionState)")
            return
        }
    }

    // MARK: - Edit mode (existingBodega)

    private static let existingID = UUID(uuidString: "8F14E45F-CEEA-467E-ADC9-15476F4EAA15")!

    private static func makeExistingBodega() throws -> Bodega {
        var bodega = try makeTestBodega(
            id: existingID,
            name: "El Sol Deli",
            latitude: 40.7291,
            longitude: -73.9965,
            address: "123 Bleecker St",
            hasCat: true,
            sellsLotto: true,
            hasAtm: true
        )
        bodega.hours = BodegaHours(
            mon: .init(open: "7:00", close: "23:00"),
            sun: .init(open: "", close: "", isClosed: true)
        )
        return bodega
    }

    private func makeEditViewModel(session: Session?) throws -> AddBodegaViewModel {
        let existing = try Self.makeExistingBodega()
        return AddBodegaViewModel(
            coordinate: existing.coordinate,
            existingBodega: existing,
            bodegaService: BodegaService(postgrest: makeTestPostgrestClient()),
            sessionStore: SessionStore(auth: try makeTestAuthClient(session: session))
        )
    }

    /// protects: Edit Bodega opens with every field of the existing bodega,
    /// including `hasAtm` (#141).
    /// fails_when: any field, ATM included, is not copied from the bodega.
    /// no_claim: that the prefilled values are sent (see the PATCH test).
    @Test func editModePrefillsEveryFieldFromTheExistingBodega() throws {
        let viewModel = try makeEditViewModel(session: makeTestSession())

        #expect(viewModel.isEditing)
        #expect(viewModel.name == "El Sol Deli")
        #expect(viewModel.address == "123 Bleecker St")
        #expect(viewModel.hasCat)
        #expect(!viewModel.servesHotFood)
        #expect(!viewModel.sellsCigarettes)
        #expect(!viewModel.sellsBeer)
        #expect(viewModel.sellsLotto)
        #expect(viewModel.hasAtm)
        let mon = try #require(viewModel.dayEntries.first { $0.id == "mon" })
        #expect(mon.open == "7:00" && mon.close == "23:00" && !mon.isClosed)
        let sun = try #require(viewModel.dayEntries.first { $0.id == "sun" })
        #expect(sun.isClosed)
        let tue = try #require(viewModel.dayEntries.first { $0.id == "tue" })
        #expect(tue.open.isEmpty && tue.close.isEmpty && !tue.isClosed)
    }

    /// protects: the form's per-amenity accessor (`isOn(_:)`/`setOn(_:_:)`,
    /// #141 eng D8) reads and writes exactly the stored Bool for each
    /// amenity, the fields `makeRequest` sends.
    /// fails_when: an amenity maps to another amenity's field, a write
    /// touches a second field, or a read does not reflect the write.
    /// no_claim: the SwiftUI `Binding` in `AddBodegaView` (a thin wrapper).
    @Test func amenityBindingsReadAndWriteOnlyTheirOwnField() throws {
        let viewModel = try makeViewModel(session: makeTestSession())
        let stored: (AddBodegaViewModel) -> [Bool] = {
            [$0.hasCat, $0.servesHotFood, $0.sellsCigarettes, $0.sellsBeer, $0.sellsLotto, $0.hasAtm]
        }
        let allOff = [false, false, false, false, false, false]
        let order: [BodegaFilter.Amenity] = [
            .hasCat, .servesHotFood, .sellsCigarettes, .sellsBeer, .sellsLotto, .hasAtm
        ]
        #expect(BodegaFilter.Amenity.allCases == order)
        for (index, amenity) in order.enumerated() {
            viewModel.setOn(amenity, true)
            var expected = allOff
            expected[index] = true
            #expect(stored(viewModel) == expected, "\(amenity)")
            #expect(viewModel.isOn(amenity), "\(amenity)")
            for other in order where other != amenity {
                #expect(!viewModel.isOn(other), "\(amenity) leaked into \(other)")
            }
            viewModel.setOn(amenity, false)
            #expect(!viewModel.isOn(amenity), "\(amenity)")
            #expect(stored(viewModel) == allOff, "\(amenity)")
        }
    }

    @Test func addModeIsNotEditing() throws {
        let viewModel = try makeViewModel(session: makeTestSession())
        #expect(!viewModel.isEditing)
    }

    // Also (#20): protects=Edit Bodega never runs the duplicate check;
    // fails_when=an RPC request appears or more than one request is sent;
    // no_claim=none beyond protects.
    @Test func editSubmitPatchesTheBodegaByIDWithOnlyEditableKeys() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        let log = RequestLog()
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8)) { request in
            capturedRequest.set(request)
            log.record(request)
        }
        MockURLProtocol.stub(body: Self.nothingNearby, onRequest: log.record)
        let viewModel = try makeEditViewModel(session: makeTestSession())
        viewModel.name = "  El Sol Deli & Grocery  "
        viewModel.sellsBeer = true

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        guard case .submitted = viewModel.submissionState else {
            Issue.record("expected .submitted, got \(viewModel.submissionState)")
            return
        }
        #expect(log.paths == [Self.bodegasPath])
        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/rest/v1/bodegas")
        let query = try #require(request.url?.query)
        #expect(query.contains("id=eq.\(Self.existingID.uuidString)"))
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == [
            "name", "address", "has_cat", "serves_hot_food", "sells_cigarettes",
            "sells_beer", "sells_lotto", "has_atm", "hours"
        ])
        #expect(json["location"] == nil)
        #expect(json["created_by"] == nil)
        #expect(json["is_hidden"] == nil)
        #expect(json["name"] as? String == "El Sol Deli & Grocery")
        #expect(json["address"] as? String == "123 Bleecker St")
        #expect(json["sells_beer"] as? Bool == true)
        #expect(json["has_cat"] as? Bool == true)
        #expect(json["has_atm"] as? Bool == true)
        let hours = try #require(json["hours"] as? [String: Any])
        #expect(Set(hours.keys) == ["mon", "sun"])
    }

    @Test func editSubmitSendsExplicitNullsWhenAddressAndHoursAreCleared() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeEditViewModel(session: makeTestSession())
        viewModel.address = "   "
        for index in viewModel.dayEntries.indices {
            viewModel.dayEntries[index].open = ""
            viewModel.dayEntries[index].close = ""
            viewModel.dayEntries[index].isClosed = false
        }

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        let request = try #require(capturedRequest.get())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["address"] is NSNull)
        #expect(json["hours"] is NSNull)
    }

    @Test func editSubmitRequiresSignInWhenNoSessionAndSendsNoRequest() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeEditViewModel(session: nil)

        viewModel.submit()

        #expect(viewModel.submissionState == .signInRequired)
        #expect(capturedRequest.get() == nil)
    }
}

}

// MARK: - Duplicate check (#20)

extension NetworkingTests.AddBodegaViewModelTests {
    static let rpcPath = "/rest/v1/rpc/nearby_bodegas"
    static let bodegasPath = "/rest/v1/bodegas"
    static let nearID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let fartherID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let hiddenID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    /// An RPC response body: one row per `(id, name, isHidden)`, in the
    /// order given, which stands for the RPC's nearest-first order.
    static func nearbyJSON(_ rows: [(UUID, String, Bool)]) throws -> Data {
        let objects: [[String: Any]] = rows.map { id, name, isHidden in
            [
                "id": id.uuidString,
                "created_by": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
                "name": name,
                "latitude": 40.7292,
                "longitude": -73.9966,
                "address": NSNull(),
                "has_cat": false,
                "serves_hot_food": false,
                "sells_cigarettes": false,
                "sells_beer": false,
                "sells_lotto": false,
                "has_atm": false,
                "hours": NSNull(),
                "is_hidden": isHidden,
                "created_at": "2026-07-21T18:30:00.000000+00:00",
                "updated_at": "2026-07-21T18:30:00.000000+00:00"
            ]
        }
        return try JSONSerialization.data(withJSONObject: objects)
    }

    static func oneMatch() throws -> Data { try nearbyJSON([(nearID, "Near Deli", false)]) }

    func duplicateIDs(_ state: AddBodegaViewModel.SubmissionState) -> [UUID]? {
        if case .possibleDuplicates(let matches) = state { matches.map(\.id) } else { nil }
    }

    func isSubmitted(_ state: AddBodegaViewModel.SubmissionState) -> Bool {
        if case .submitted = state { true } else { false }
    }

    // protects=matches reach the prompt nearest first, from one RPC call at
    // 50 m around the pin; fails_when=the state is anything else, an insert
    // is sent, the order changes or the radius or point differs;
    // no_claim=the RPC's geography maths (MockURLProtocol stands in for it).
    @Test func submitChecksNearbyFirstAndSurfacesMatches() async throws {
        MockURLProtocol.reset()
        let log = RequestLog()
        let matches = try Self.nearbyJSON([(Self.nearID, "Near Deli", false), (Self.fartherID, "Farther Deli", false)])
        MockURLProtocol.stub(body: matches, onRequest: log.record)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8), onRequest: log.record)
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "El Sol"

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(duplicateIDs(viewModel.submissionState) == [Self.nearID, Self.fartherID])
        #expect(log.paths == [Self.rpcPath])
        let request = try #require(log.requests.first)
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["radius_meters"] as? Double == 50)
        #expect(json["lat"] as? Double == Self.sampleCoordinate.latitude)
        #expect(json["long"] as? Double == Self.sampleCoordinate.longitude)
    }

    // protects=the happy path still inserts after an empty check;
    // fails_when=no insert follows the check, or the order differs;
    // no_claim=server validation (MockURLProtocol stands in for it).
    @Test func submitInsertsWhenNothingIsNearby() async throws {
        MockURLProtocol.reset()
        let log = RequestLog()
        MockURLProtocol.stub(body: Self.nothingNearby, onRequest: log.record)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8), onRequest: log.record)
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "El Sol"

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(isSubmitted(viewModel.submissionState))
        #expect(log.paths == [Self.rpcPath, Self.bodegasPath])
        #expect(log.requests.last?.httpMethod == "POST")
    }

    // protects="No, It's New" inserts without checking again;
    // fails_when=a second RPC request appears; no_claim=none beyond protects.
    @Test func confirmNewInsertsWithoutASecondCheck() async throws {
        MockURLProtocol.reset()
        let log = RequestLog()
        MockURLProtocol.stub(body: try Self.oneMatch(), onRequest: log.record)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8), onRequest: log.record)
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "El Sol"
        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()
        #expect(duplicateIDs(viewModel.submissionState) == [Self.nearID])

        viewModel.confirmNew()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(isSubmitted(viewModel.submissionState))
        #expect(log.paths == [Self.rpcPath, Self.bodegasPath])
    }

    // protects=a retry after a failed insert does not re-prompt;
    // fails_when=an RPC request follows the failure; no_claim=none beyond
    // protects.
    @Test func confirmNewStaysSkippedAfterAFailedInsert() async throws {
        MockURLProtocol.reset()
        let log = RequestLog()
        MockURLProtocol.stub(body: try Self.oneMatch(), onRequest: log.record)
        MockURLProtocol.stub(statusCode: 500, body: Data("{\"message\":\"boom\"}".utf8), onRequest: log.record)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8), onRequest: log.record)
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "El Sol"
        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()
        viewModel.confirmNew()
        await viewModel.waitForPendingSubmitForTesting()
        guard case .failed = viewModel.submissionState else {
            Issue.record("expected .failed, got \(viewModel.submissionState)")
            return
        }

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(isSubmitted(viewModel.submissionState))
        #expect(log.paths == [Self.rpcPath, Self.bodegasPath, Self.bodegasPath])
    }

    // protects=swipe-down does not count as "it's new"; fails_when=the
    // second submit inserts, or the state after dismissing is not .idle;
    // no_claim=none beyond protects.
    @Test func dismissDuplicatePromptReturnsToIdleAndChecksAgain() async throws {
        MockURLProtocol.reset()
        let log = RequestLog()
        MockURLProtocol.stub(body: try Self.oneMatch(), onRequest: log.record)
        MockURLProtocol.stub(body: try Self.oneMatch(), onRequest: log.record)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8), onRequest: log.record)
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "El Sol"
        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        viewModel.dismissDuplicatePrompt()
        #expect(viewModel.submissionState == .idle)
        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(duplicateIDs(viewModel.submissionState) == [Self.nearID])
        #expect(log.paths == [Self.rpcPath, Self.rpcPath])
    }

    // protects=stray calls cannot start a submit or leave the current
    // state; fails_when=a request is sent or the state changes;
    // no_claim=none beyond protects.
    @Test func dismissDuplicatePromptAndConfirmNewAreNoOpsOutsideThePrompt() async throws {
        MockURLProtocol.reset()
        let log = RequestLog()
        MockURLProtocol.stub(body: Self.nothingNearby, onRequest: log.record)
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "El Sol"

        viewModel.dismissDuplicatePrompt()
        viewModel.confirmNew()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(viewModel.submissionState == .idle)
        #expect(log.paths.isEmpty)
    }

    // protects=the check is advisory: a failed RPC proceeds to the insert
    // with no error shown; fails_when=the state is .failed or no insert is
    // sent; no_claim=none beyond protects.
    @Test func aFailedNearbyCheckProceedsToTheInsert() async throws {
        MockURLProtocol.reset()
        let log = RequestLog()
        MockURLProtocol.stub(statusCode: 500, body: Data("{\"message\":\"boom\"}".utf8), onRequest: log.record)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8), onRequest: log.record)
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "El Sol"

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(isSubmitted(viewModel.submissionState))
        #expect(log.paths == [Self.rpcPath, Self.bodegasPath])
    }

    // protects=the check runs before the sign-in gate (D1), so a signed-out
    // user with a match sees the prompt; fails_when=.signInRequired comes
    // first; no_claim=none beyond protects.
    @Test func duplicateCheckRunsBeforeSignIn() async throws {
        MockURLProtocol.reset()
        let log = RequestLog()
        MockURLProtocol.stub(body: try Self.oneMatch(), onRequest: log.record)
        let viewModel = try makeViewModel(session: nil)
        viewModel.name = "El Sol"

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(duplicateIDs(viewModel.submissionState) == [Self.nearID])
        #expect(log.paths == [Self.rpcPath])
    }

    // protects=a stalled check gives up after duplicateCheckTimeout and the
    // insert goes ahead (eng R2); fails_when=the submit waits on the RPC,
    // or ends anywhere but .submitted; no_claim=real network timing
    // (ManualClock stands in for the clock, a gated stub for the stall).
    @Test func aStalledNearbyCheckTimesOutAndProceedsToTheInsert() async throws {
        MockURLProtocol.reset()
        let clock = ManualClock()
        let gate = StubGate()
        defer { gate.open() }
        let log = RequestLog()
        MockURLProtocol.stub(body: try Self.oneMatch(), gate: gate, onRequest: log.record)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8), onRequest: log.record)
        let viewModel = try makeViewModel(session: makeTestSession(), clock: clock)
        viewModel.name = "El Sol"

        viewModel.submit()
        try await waitUntil { log.paths.count == 1 && clock.sleeperCount == 1 }
        #expect(viewModel.submissionState == .submitting)
        clock.advance(by: AddBodegaViewModel.duplicateCheckTimeout)
        await viewModel.waitForPendingSubmitForTesting()

        #expect(isSubmitted(viewModel.submissionState))
        #expect(log.paths == [Self.rpcPath, Self.bodegasPath])
    }

    // protects=Cancel while the check runs never inserts that draft (eng
    // R4); fails_when=an insert request is sent or the state reaches
    // .submitted; no_claim=that AddBodegaView calls cancelSubmit on
    // disappear (checked live), and a gated stub stands in for the slow RPC.
    @Test func cancelSubmitDuringTheCheckSendsNoInsert() async throws {
        MockURLProtocol.reset()
        let gate = StubGate()
        let log = RequestLog()
        MockURLProtocol.stub(body: Self.nothingNearby, gate: gate, onRequest: log.record)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8), onRequest: log.record)
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "El Sol"

        viewModel.submit()
        try await waitUntil { log.paths.count == 1 }
        viewModel.cancelSubmit()
        gate.open()
        // Nothing left to await: give a wrongly surviving task time to
        // insert before asserting that it did not.
        try await Task.sleep(for: .milliseconds(300))

        #expect(log.paths == [Self.rpcPath])
        #expect(viewModel.submissionState == .submitting)
    }

    // protects=a hidden bodega the user created is never offered, and if it
    // is the only row the insert proceeds (eng R5); fails_when=a hidden row
    // reaches the prompt or blocks the insert; no_claim=the RLS policy that
    // returns the creator's hidden rows (the stub stands in for it).
    @Test func hiddenMatchesAreNotOfferedAsDuplicates() async throws {
        MockURLProtocol.reset()
        let log = RequestLog()
        let mixed = try Self.nearbyJSON([(Self.hiddenID, "Hidden Deli", true), (Self.nearID, "Near Deli", false)])
        MockURLProtocol.stub(body: mixed, onRequest: log.record)
        MockURLProtocol.stub(body: try Self.nearbyJSON([(Self.hiddenID, "Hidden Deli", true)]), onRequest: log.record)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8), onRequest: log.record)
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "El Sol"

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()
        #expect(duplicateIDs(viewModel.submissionState) == [Self.nearID])

        viewModel.dismissDuplicatePrompt()
        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(isSubmitted(viewModel.submissionState))
        #expect(log.paths == [Self.rpcPath, Self.rpcPath, Self.bodegasPath])
    }

    /// Polls `condition` on the main actor for up to five seconds.
    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

/// Every request a test's stubs saw, in order.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { log } }
    var paths: [String] { requests.compactMap { $0.url?.path } }

    @Sendable func record(_ request: URLRequest) {
        lock.withLock { log.append(request) }
    }
}

/// `buildHours(from:)` ↔ `dayEntries(from:)` round trip — pure, no
/// networking, so a standalone suite outside `NetworkingTests`.
@Suite
@MainActor
struct AddBodegaHoursRoundTripTests {
    @Test func hoursRoundTripThroughDayEntriesIncludingClosedAndNilDays() {
        let hours = BodegaHours(
            mon: .init(open: "7:00", close: "23:00"),
            tue: .init(open: "7:00", close: "23:00"),
            wed: nil,
            thu: .init(open: "", close: "", isClosed: true),
            fri: .init(open: "6:00 AM", close: "2:00 AM"),
            sat: nil,
            sun: .init(open: "", close: "", isClosed: true)
        )

        let entries = AddBodegaViewModel.dayEntries(from: hours)

        #expect(entries.map(\.id) == ["mon", "tue", "wed", "thu", "fri", "sat", "sun"])
        #expect(AddBodegaViewModel.buildHours(from: entries) == hours)
    }

    @Test func nilHoursBecomeBlankEntriesAndBackToNil() {
        let entries = AddBodegaViewModel.dayEntries(from: nil)

        #expect(entries.allSatisfy { $0.open.isEmpty && $0.close.isEmpty && !$0.isClosed })
        #expect(AddBodegaViewModel.buildHours(from: entries) == nil)
    }

    @Test func aClosedDayWithStoredTimesPrefillsAsBlankAndRebuildsAsCleanClosed() throws {
        let hours = BodegaHours(sun: .init(open: "9:00", close: "17:00", isClosed: true))

        let entries = AddBodegaViewModel.dayEntries(from: hours)

        let sun = try #require(entries.first { $0.id == "sun" })
        #expect(sun.isClosed && sun.open.isEmpty && sun.close.isEmpty)
        let rebuilt = AddBodegaViewModel.buildHours(from: entries)
        #expect(rebuilt == BodegaHours(sun: .init(open: "", close: "", isClosed: true)))
    }

    @Test func openOnlyOrCloseOnlyDaysSurviveTheRoundTrip() {
        let hours = BodegaHours(mon: .init(open: "8:00", close: ""), sat: .init(open: "", close: "22:00"))

        #expect(AddBodegaViewModel.buildHours(from: AddBodegaViewModel.dayEntries(from: hours)) == hours)
    }
}
