//
//  AccountViewModelTests.swift
//  BodegasNYCTests
//
//  Delete Account's state machine (#127, spec item 5, eng D7 and D8, design
//  DS4 to DS6). MockURLProtocol stands in for the delete-account function
//  and for GoTrue's /logout; the session is a stored test session, with or
//  without an `apple` identity.
//

import AuthenticationServices
import Auth
import Foundation
import Testing

@testable import BodegasNYC

/// The view model with its store, and a log of the function requests.
@MainActor
private struct AccountTestHarness {
    let viewModel: AccountViewModel
    let sessionStore: SessionStore
    /// Every request to the function, in order.
    let deleteRequests: Captured<[URLRequest]>
}

extension NetworkingTests {

@Suite
@MainActor
struct AccountViewModelTests {
    private static let deleteURL = "https://example.supabase.co/functions/v1/delete-account"

    /// One stored session (Apple or email) shared by the store and the
    /// service, as in the app, where both wrap the same `AuthClient`.
    private func makeAccountTestHarness(apple: Bool) throws -> AccountTestHarness {
        let userID = UUID()
        let identity = makeTestIdentity(provider: apple ? "apple" : "email", userID: userID)
        let auth = try makeTestAuthClient(session: makeTestSession(userID: userID, identities: [identity]))
        let urlSession = MockURLProtocol.makeSession()
        let service = AccountService(
            auth: auth,
            functionsURL: URL(string: "https://example.supabase.co/functions/v1")!,
            anonKey: "test-anon-key",
            fetch: { try await urlSession.data(for: $0) }
        )
        let sessionStore = SessionStore(auth: auth)
        return AccountTestHarness(
            viewModel: AccountViewModel(accountService: service, sessionStore: sessionStore),
            sessionStore: sessionStore,
            deleteRequests: Captured([])
        )
    }

    /// Queues the function's answer (and, for a success, the /logout that
    /// follows), logging each function request.
    private func stubDelete(_ harness: AccountTestHarness, status: Int, body: String = "", gate: StubGate? = nil) {
        let log = harness.deleteRequests
        let deleteURL = Self.deleteURL
        MockURLProtocol.stub(statusCode: status, body: Data(body.utf8), gate: gate) { request in
            if request.url?.absoluteString == deleteURL { log.set(log.get() + [request]) }
        }
        if status == 204 || status == 202 {
            MockURLProtocol.stub(statusCode: 204, body: Data())
        }
    }

    private func sentCode(_ request: URLRequest) throws -> Any? {
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return json["appleAuthorizationCode"]
    }

    /// protects=AC 3 and eng D8: for an Apple user, confirming leads to the
    /// Apple step and nothing is sent until Apple returns a code; the code is
    /// what is sent; a second `appleAuthorized` sends no second request;
    /// fails_when=a request leaves before the code, without it, or twice;
    /// no_claim=Apple's sheet itself (device test under #139).
    @Test func anAppleUserSendsNothingUntilAppleReturnsACode() async throws {
        MockURLProtocol.reset()
        let harness = try makeAccountTestHarness(apple: true)
        let viewModel = harness.viewModel
        stubDelete(harness, status: 204)

        viewModel.confirmRequested()
        #expect(viewModel.state == .confirming)
        viewModel.proceed()
        #expect(viewModel.state == .awaitingApple)
        #expect(harness.deleteRequests.get().isEmpty)

        viewModel.appleAuthorized(code: "fresh-code")
        viewModel.appleAuthorized(code: "second-code")
        await viewModel.waitForPendingDeleteForTesting()

        let requests = harness.deleteRequests.get()
        try #require(requests.count == 1)
        #expect(try sentCode(requests[0]) as? String == "fresh-code")
        #expect(viewModel.state == .deleted(.deleted))
    }

    /// protects=DS4 (amending eng D8): Apple's own cancel keeps the Apple
    /// step with no request and no error; another Apple error shows "Apple
    /// couldn't confirm it's you." there; the step's Cancel returns to idle;
    /// fails_when=Apple's cancel drops back to the dialog or idle, any of it
    /// sends a request, or a real error is silent;
    /// no_claim=which ASAuthorizationError codes iOS sends for what.
    @Test func appleCancelKeepsTheAppleStep() async throws {
        MockURLProtocol.reset()
        let harness = try makeAccountTestHarness(apple: true)
        let viewModel = harness.viewModel
        viewModel.confirmRequested()
        viewModel.proceed()

        viewModel.appleFailed(ASAuthorizationError(.canceled))
        #expect(viewModel.state == .awaitingApple)
        #expect(viewModel.appleError == nil)

        viewModel.appleFailed(ASAuthorizationError(.failed))
        #expect(viewModel.state == .awaitingApple)
        #expect(viewModel.appleError == .appleFailed)

        viewModel.cancel()
        #expect(viewModel.state == .idle)
        #expect(viewModel.appleError == nil)
        #expect(harness.deleteRequests.get().isEmpty)
    }

    /// protects=AC 4, AC 5 and eng D8: an email user's confirmation sends the
    /// request at once with a null code, a double tap sends one request, and
    /// a 204 ends `.deleted` with the local session cleared;
    /// fails_when=an Apple step is shown, the code is not null, two requests
    /// go out, or the store stays signed in;
    /// no_claim=the sheet's terminal layout (live QA).
    @Test func anEmailUserIsDeletedDirectlyAndSignedOut() async throws {
        MockURLProtocol.reset()
        let harness = try makeAccountTestHarness(apple: false)
        let viewModel = harness.viewModel
        stubDelete(harness, status: 204)
        #expect(harness.sessionStore.isSignedIn)

        viewModel.confirmRequested()
        viewModel.proceed()
        viewModel.proceed()
        #expect(viewModel.state == .deleting)
        await viewModel.waitForPendingDeleteForTesting()

        let requests = harness.deleteRequests.get()
        try #require(requests.count == 1)
        #expect(try sentCode(requests[0]) is NSNull)
        #expect(viewModel.state == .deleted(.deleted))
        #expect(harness.sessionStore.isSignedIn == false)
    }

    /// protects=AC 6 and DS6: a failure leaves the session signed in, shows
    /// the mapped line, and Delete Account retries; a 202 ends deleted with
    /// the cleanup-pending line; the code/status map (DS6, eng "error codes");
    /// fails_when=a failure signs out, a 202 reads as a failure, or a code
    /// maps to a line that misstates whether the account still exists;
    /// no_claim=the rendered sheet.
    @Test func failuresKeepTheSessionAndMapToDS6Lines() async throws {
        MockURLProtocol.reset()
        let harness = try makeAccountTestHarness(apple: false)
        let viewModel = harness.viewModel
        stubDelete(harness, status: 502, body: #"{"code":"delete_failed","message":"x"}"#)

        viewModel.confirmRequested()
        viewModel.proceed()
        await viewModel.waitForPendingDeleteForTesting()
        #expect(viewModel.state == .failed(.notDeleted))
        #expect(viewModel.failure == .notDeleted)
        #expect(harness.sessionStore.isSignedIn)

        stubDelete(harness, status: 202, body: #"{"code":"cleanup_pending","message":"x"}"#)
        viewModel.confirmRequested()
        #expect(viewModel.state == .confirming)
        viewModel.proceed()
        await viewModel.waitForPendingDeleteForTesting()
        #expect(viewModel.state == .deleted(.deletedCleanupPending))
        #expect(harness.sessionStore.isSignedIn == false)

        let table: [(AccountService.Error, AppCopy.Account)] = [
            (.server(status: 400, code: "apple_code_required", message: nil), .appleMismatch),
            (.server(status: 403, code: "apple_identity_mismatch", message: nil), .appleMismatch),
            (.server(status: 502, code: "apple_exchange_failed", message: nil), .notDeleted),
            (.server(status: 502, code: "apple_revoke_failed", message: nil), .notDeleted),
            (.server(status: 502, code: "delete_failed", message: nil), .notDeleted),
            (.server(status: 401, code: "unauthorized", message: nil), .signInAgain),
            (.server(status: 401, code: nil, message: nil), .signInAgain),
            (.server(status: 404, code: nil, message: nil), .notDeleted),
            (.server(status: 500, code: nil, message: nil), .unreachable),
            (.transport("offline"), .unreachable),
            (.notSignedIn, .signInAgain)
        ]
        for (error, expected) in table {
            #expect(AccountViewModel.failureMessage(for: error) == expected, "\(error)")
        }
    }

    /// protects=eng D7: while the request is in flight, Cancel and Delete
    /// Account do nothing, and a completion that arrives late still reaches
    /// `.deleted` and clears the session;
    /// fails_when=an in-flight delete can be cancelled back to idle (the
    /// sheet would show a live account that is gone) or a late answer is
    /// dropped;
    /// no_claim=that the sheet cannot be swiped away (`interactiveDismissDisabled`,
    /// live QA).
    @Test func aLateCompletionStillReachesDeleted() async throws {
        MockURLProtocol.reset()
        let harness = try makeAccountTestHarness(apple: false)
        let viewModel = harness.viewModel
        let gate = StubGate()
        stubDelete(harness, status: 204, gate: gate)

        viewModel.confirmRequested()
        viewModel.proceed()
        #expect(viewModel.isDeleting)
        viewModel.cancel()
        viewModel.confirmRequested()
        #expect(viewModel.state == .deleting)

        gate.open()
        await viewModel.waitForPendingDeleteForTesting()
        #expect(viewModel.state == .deleted(.deleted))
        #expect(harness.sessionStore.isSignedIn == false)
        #expect(harness.deleteRequests.get().count == 1)
    }
}

}
