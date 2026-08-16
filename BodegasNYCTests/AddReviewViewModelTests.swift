//
//  AddReviewViewModelTests.swift
//  BodegasNYCTests
//
//  Follows AddBodegaViewModelTests's pattern (makeTestPostgrestClient() +
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
struct AddReviewViewModelTests {
    private static let bodegaID = UUID(uuidString: "8f14e45f-ceea-467e-adc9-15476f4eaa15")!
    private static let reviewID = UUID(uuidString: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed")!
    private static let authorID = UUID(uuidString: "3fa85f64-5717-4562-b3fc-2c963f66afa6")!

    private static let reviewJSON = """
    {
      "id": "\(reviewID.uuidString)",
      "bodega_id": "\(bodegaID.uuidString)",
      "author_id": "\(authorID.uuidString)",
      "rating": 4,
      "body": "Rocco the bodega cat says hi",
      "is_hidden": false,
      "created_at": "2026-07-21T18:30:00+00:00",
      "updated_at": "2026-07-21T18:30:00+00:00"
    }
    """

    private static let existingReview = Review(
        id: reviewID,
        bodegaId: bodegaID,
        authorId: authorID,
        rating: 2,
        body: "Meh",
        isHidden: false,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    private func makeViewModel(existingReview: Review? = nil, session: Session?) throws -> AddReviewViewModel {
        AddReviewViewModel(
            bodegaId: Self.bodegaID,
            existingReview: existingReview,
            reviewService: ReviewService(postgrest: makeTestPostgrestClient()),
            sessionStore: SessionStore(auth: try makeTestAuthClient(session: session))
        )
    }

    @Test func submitIsRejectedWithoutARating() async throws {
        let viewModel = try makeViewModel(session: makeTestSession())

        viewModel.submit()

        #expect(viewModel.submissionState == .failed("Please choose a star rating."))
    }

    @Test func newReviewPrefillsToNoRatingAndEmptyBody() throws {
        let viewModel = try makeViewModel(session: makeTestSession())

        #expect(viewModel.rating == 0)
        #expect(viewModel.body == "")
    }

    @Test func editingPrefillsFromTheExistingReview() throws {
        let viewModel = try makeViewModel(existingReview: Self.existingReview, session: makeTestSession())

        #expect(viewModel.rating == 2)
        #expect(viewModel.body == "Meh")
    }

    @Test func submitWithNoExistingReviewInsertsWithBodegaAndAuthorIDs() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.reviewJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeViewModel(session: makeTestSession(userID: Self.authorID))
        viewModel.rating = 4
        viewModel.body = "Rocco the bodega cat says hi"

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        guard case .submitted = viewModel.submissionState else {
            Issue.record("expected .submitted, got \(viewModel.submissionState)")
            return
        }
        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["bodega_id"] as? String == Self.bodegaID.uuidString.uppercased())
        #expect(json["author_id"] as? String == Self.authorID.uuidString.uppercased())
        #expect(json["rating"] as? Int == 4)
    }

    @Test func submitOmitsBodyWhenBlank() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.reviewJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.rating = 3
        viewModel.body = "   "

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        let request = try #require(capturedRequest.get())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["body"] == nil)
    }

    @Test func submitWithAnExistingReviewSendsAPatchScopedByItsID() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.reviewJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeViewModel(existingReview: Self.existingReview, session: makeTestSession(userID: Self.authorID))
        viewModel.rating = 5
        viewModel.body = "Actually great"

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        guard case .submitted = viewModel.submissionState else {
            Issue.record("expected .submitted, got \(viewModel.submissionState)")
            return
        }
        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "PATCH")
        let query = try #require(request.url?.query)
        #expect(query.contains("id=eq.\(Self.reviewID.uuidString)"))
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["rating"] as? Int == 5)
        #expect(json["body"] as? String == "Actually great")
        #expect(json["bodega_id"] == nil, "ReviewUpdate carries no bodega_id/author_id fields to overwrite")
    }

    @Test func submitRequiresSignInWhenNoSessionAndSendsNoRequest() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.reviewJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeViewModel(session: nil)
        viewModel.rating = 4

        viewModel.submit()

        #expect(viewModel.submissionState == .signInRequired)
        #expect(capturedRequest.get() == nil)
    }

    @Test func dismissSignInPromptResetsToIdleSoASecondSubmitReasksForSignIn() async throws {
        let viewModel = try makeViewModel(session: nil)
        viewModel.rating = 4

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

    @Test func aFailedSubmitDrivesSubmissionStateToFailed() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(statusCode: 500, body: Data("{\"message\":\"boom\"}".utf8))
        let viewModel = try makeViewModel(session: makeTestSession())
        viewModel.rating = 3

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        guard case .failed = viewModel.submissionState else {
            Issue.record("expected .failed, got \(viewModel.submissionState)")
            return
        }
    }
}

}
