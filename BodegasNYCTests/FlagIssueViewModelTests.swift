//
//  FlagIssueViewModelTests.swift
//  BodegasNYCTests
//
//  Follows AddReviewViewModelTests's pattern (makeTestPostgrestClient() +
//  MockURLProtocol, makeTestAuthClient/makeTestSession for the SessionStore
//  side).
//

import Auth
import Foundation
import PostgREST
import Testing

@testable import BodegasNYC

extension NetworkingTests {

@Suite
@MainActor
struct FlagIssueViewModelTests {
    private static let bodegaID = UUID(uuidString: "8f14e45f-ceea-467e-adc9-15476f4eaa15")!
    private static let reviewID = UUID(uuidString: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed")!
    private static let photoID = UUID(uuidString: "6ec0bd7f-11c0-43da-975e-2a8ad9ebae0b")!
    private static let reporterID = UUID(uuidString: "3fa85f64-5717-4562-b3fc-2c963f66afa6")!

    private static let flagJSON = """
    {
      "id": "e2c1a2f0-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
      "reporter_id": "\(reporterID.uuidString)",
      "bodega_id": "\(bodegaID.uuidString)",
      "review_id": null,
      "photo_id": null,
      "reason": "Closed permanently",
      "created_at": "2026-07-21T18:32:00.000000+00:00"
    }
    """

    /// Body PostgREST actually returns (with HTTP 409) when an insert trips
    /// one of `flags`' partial unique indexes on (reporter_id, target).
    private static let uniqueViolationJSON = """
    {
      "code": "23505",
      "details": "Key (reporter_id, bodega_id)=(3fa85f64-5717-4562-b3fc-2c963f66afa6, 8f14e45f-ceea-467e-adc9-15476f4eaa15) already exists.",
      "hint": null,
      "message": "duplicate key value violates unique constraint \\"flags_unique_bodega\\""
    }
    """

    private func makeViewModel(target: FlagTarget = .bodega(bodegaID), session: Session?) throws -> FlagIssueViewModel {
        FlagIssueViewModel(
            target: target,
            flagService: FlagService(postgrest: makeTestPostgrestClient()),
            sessionStore: SessionStore(auth: try makeTestAuthClient(session: session))
        )
    }

    private func submitAndCaptureJSON(_ viewModel: FlagIssueViewModel) async throws -> [String: Any] {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.flagJSON.utf8)) { request in
            capturedRequest.set(request)
        }

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func submitRequiresSignInWhenNoSessionAndSendsNoRequest() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.flagJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeViewModel(session: nil)

        viewModel.submit()

        #expect(viewModel.submissionState == .signInRequired)
        #expect(capturedRequest.get() == nil)
    }

    @Test func dismissSignInPromptResetsToIdleSoASecondSubmitReasksForSignIn() async throws {
        let viewModel = try makeViewModel(session: nil)

        viewModel.submit()
        #expect(viewModel.submissionState == .signInRequired)

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

    @Test func submitForABodegaTargetEncodesBodegaIDOnlyWithReporterAndReason() async throws {
        let viewModel = try makeViewModel(session: makeTestSession(userID: Self.reporterID))
        viewModel.reason = .closedPermanently

        let json = try await submitAndCaptureJSON(viewModel)

        guard case .submitted = viewModel.submissionState else {
            Issue.record("expected .submitted, got \(viewModel.submissionState)")
            return
        }
        #expect(json["bodega_id"] as? String == Self.bodegaID.uuidString.uppercased())
        #expect(json["review_id"] == nil)
        #expect(json["photo_id"] == nil)
        #expect(json["reporter_id"] as? String == Self.reporterID.uuidString.uppercased())
        #expect(json["reason"] as? String == "Closed permanently")
    }

    @Test func submitForAReviewTargetEncodesReviewIDOnly() async throws {
        let viewModel = try makeViewModel(target: .review(Self.reviewID), session: makeTestSession())

        let json = try await submitAndCaptureJSON(viewModel)

        #expect(json["review_id"] as? String == Self.reviewID.uuidString.uppercased())
        #expect(json["bodega_id"] == nil)
        #expect(json["photo_id"] == nil)
    }

    @Test func submitForAPhotoTargetEncodesPhotoIDOnly() async throws {
        let viewModel = try makeViewModel(target: .photo(Self.photoID), session: makeTestSession())

        let json = try await submitAndCaptureJSON(viewModel)

        #expect(json["photo_id"] as? String == Self.photoID.uuidString.uppercased())
        #expect(json["bodega_id"] == nil)
        #expect(json["review_id"] == nil)
    }

    @Test func closedPermanentlyIsOfferedOnlyForTheBodegaTarget() throws {
        let session = makeTestSession()
        #expect(try makeViewModel(session: session).reasonOptions.contains(.closedPermanently))
        let reviewOptions = try makeViewModel(target: .review(Self.reviewID), session: session).reasonOptions
        let photoOptions = try makeViewModel(target: .photo(Self.photoID), session: session).reasonOptions
        #expect(!reviewOptions.contains(.closedPermanently))
        #expect(!photoOptions.contains(.closedPermanently))
        #expect(reviewOptions.contains(.wrongDetails), "default reason must be offered for every target")
    }

    @Test func nonBlankDetailsAreAppendedToTheReason() async throws {
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.reason = .other
        viewModel.details = "  Now a laundromat  "

        let json = try await submitAndCaptureJSON(viewModel)

        #expect(json["reason"] as? String == "Other: Now a laundromat")
    }

    @Test func aDuplicateFlagSurfacesAFriendlyAlreadyFlaggedMessage() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(statusCode: 409, body: Data(Self.uniqueViolationJSON.utf8))
        let viewModel = try makeViewModel(session: makeTestSession())

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(viewModel.submissionState == .failed(FlagIssueViewModel.alreadyFlaggedMessage))
    }

    @Test func aGenericFailureSurfacesTheUnderlyingMessage() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(statusCode: 500, body: Data("{\"message\":\"boom\"}".utf8))
        let viewModel = try makeViewModel(session: makeTestSession())

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(viewModel.submissionState == .failed("boom"))
    }
}

}
