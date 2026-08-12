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

    // TEMPORARY: submit() no longer gates on session presence while
    // unauthenticated writes are allowed (see
    // 20260812013849_allow_anonymous_bodega_inserts.sql). This replaces
    // `submitRequiresSignInWhenNoSessionAndSendsNoRequest`; the
    // `.signInRequired` path it and a since-removed
    // `dismissSignInPromptResetsToIdleSoASecondSubmitReasksForSignIn` test
    // covered is unreachable until that migration is reverted and this
    // gate is restored — see git history for both when that happens.
    @Test func submitSendsNilCreatedByWhenNoSession() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeViewModel(session: nil)
        viewModel.name = "El Sol"

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        guard case .submitted = viewModel.submissionState else {
            Issue.record("expected .submitted, got \(viewModel.submissionState)")
            return
        }
        let request = try #require(capturedRequest.get())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["created_by"] == nil)
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
}

}
