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
      "hours": null,
      "is_hidden": false,
      "created_at": "2026-07-21T18:30:00.123456+00:00",
      "updated_at": "2026-07-22T00:15:59.000042+00:00"
    }
    """

    private func makeViewModel(session: Session?) throws -> AddBodegaViewModel {
        AddBodegaViewModel(
            coordinate: Self.sampleCoordinate,
            bodegaService: BodegaService(postgrest: makeTestPostgrestClient()),
            sessionStore: SessionStore(auth: try makeTestAuthClient(session: session))
        )
    }

    @Test func submitIsRejectedWithoutATrimmedName() async throws {
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.name = "   "

        viewModel.submit()

        #expect(viewModel.submissionState == .failed("Please enter a name."))
    }

    @Test func submitSendsCreatedByFromTheSessionAndEWKTLocation() async throws {
        MockURLProtocol.reset()
        let userID = UUID()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeViewModel(session: makeTestSession(userID: userID))
        viewModel.name = "El Sol Deli & Grocery"

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
    }

    @Test func submitOmitsAddressWhenBlank() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
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

    @Test func submitRequiresSignInWhenNoSessionAndSendsNoRequest() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeViewModel(session: nil)
        viewModel.name = "El Sol"

        viewModel.submit()

        #expect(viewModel.submissionState == .signInRequired)
        #expect(capturedRequest.get() == nil)
    }

    @Test func dismissSignInPromptResetsToIdleSoASecondSubmitReasksForSignIn() async throws {
        let viewModel = try makeViewModel(session: nil)
        viewModel.name = "El Sol"

        viewModel.submit()
        #expect(viewModel.submissionState == .signInRequired)

        // Regression: swiping away the sign-in sheet without signing in,
        // then tapping Submit again, must re-present it — a bug caught in
        // manual Simulator testing where `AddBodegaView`'s
        // `.onChange(of: submissionState)` never fired a second time
        // because `.signInRequired` was already the current value.
        viewModel.dismissSignInPrompt()
        #expect(viewModel.submissionState == .idle)

        viewModel.submit()
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
            sellsLotto: true
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
        let mon = try #require(viewModel.dayEntries.first { $0.id == "mon" })
        #expect(mon.open == "7:00" && mon.close == "23:00" && !mon.isClosed)
        let sun = try #require(viewModel.dayEntries.first { $0.id == "sun" })
        #expect(sun.isClosed)
        let tue = try #require(viewModel.dayEntries.first { $0.id == "tue" })
        #expect(tue.open.isEmpty && tue.close.isEmpty && !tue.isClosed)
    }

    @Test func addModeIsNotEditing() throws {
        let viewModel = try makeViewModel(session: makeTestSession())
        #expect(!viewModel.isEditing)
    }

    @Test func editSubmitPatchesTheBodegaByIDWithOnlyEditableKeys() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeEditViewModel(session: makeTestSession())
        viewModel.name = "  El Sol Deli & Grocery  "
        viewModel.sellsBeer = true

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        guard case .submitted = viewModel.submissionState else {
            Issue.record("expected .submitted, got \(viewModel.submissionState)")
            return
        }
        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/rest/v1/bodegas")
        let query = try #require(request.url?.query)
        #expect(query.contains("id=eq.\(Self.existingID.uuidString)"))
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == [
            "name", "address", "has_cat", "serves_hot_food", "sells_cigarettes",
            "sells_beer", "sells_lotto", "hours"
        ])
        #expect(json["location"] == nil)
        #expect(json["created_by"] == nil)
        #expect(json["is_hidden"] == nil)
        #expect(json["name"] as? String == "El Sol Deli & Grocery")
        #expect(json["address"] as? String == "123 Bleecker St")
        #expect(json["sells_beer"] as? Bool == true)
        #expect(json["has_cat"] as? Bool == true)
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
