//
//  AccountServiceTests.swift
//  BodegasNYCTests
//
//  The delete-account edge function call (#127, spec item 3): request shape,
//  the 204/202 outcomes, the {code, message} error body and a transport
//  failure. MockURLProtocol stands in for the function; the auth client is
//  seeded with a stored, unexpired session so no token refresh is sent.
//

import Auth
import Foundation
import Testing

@testable import BodegasNYC

/// The service under test, backed by `MockURLProtocol`.
func makeTestAccountService(session: Session? = makeTestSession()) throws -> AccountService {
    let urlSession = MockURLProtocol.makeSession()
    return AccountService(
        auth: try makeTestAuthClient(session: session),
        functionsURL: URL(string: "https://example.supabase.co/functions/v1")!,
        anonKey: "test-anon-key",
        fetch: { try await urlSession.data(for: $0) }
    )
}

extension NetworkingTests {

@Suite
@MainActor
struct AccountServiceTests {
    private static func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
        let body = try #require(request?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// protects=the request the function receives: POST to
    /// /functions/v1/delete-account with the user's access token as the
    /// bearer, the anon key, JSON, and `appleAuthorizationCode` as the code
    /// or an explicit null (spec AC 4);
    /// fails_when=the method, path, bearer or apikey is wrong, or a nil code
    /// is omitted instead of sent as null;
    /// no_claim=that the hosted gateway accepts the token (local-stack curl).
    @Test func sendsTheBearerAndTheCodeOrAnExplicitNull() async throws {
        MockURLProtocol.reset()
        let requests = Captured<[URLRequest]>([])
        for _ in 0..<2 {
            MockURLProtocol.stub(statusCode: 204, body: Data()) { request in
                requests.set(requests.get() + [request])
            }
        }
        let service = try makeTestAccountService(session: makeTestSession(accessToken: "user-access-token"))

        _ = try await service.deleteAccount(appleAuthorizationCode: "apple-code")
        _ = try await service.deleteAccount(appleAuthorizationCode: nil)

        let sent = requests.get()
        try #require(sent.count == 2)
        let request = sent[0]
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://example.supabase.co/functions/v1/delete-account")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer user-access-token")
        #expect(request.value(forHTTPHeaderField: "apikey") == "test-anon-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try Self.jsonBody(sent[0])["appleAuthorizationCode"] as? String == "apple-code")
        let nullBody = try Self.jsonBody(sent[1])
        #expect(nullBody.keys.contains("appleAuthorizationCode"))
        #expect(nullBody["appleAuthorizationCode"] is NSNull)
    }

    /// protects=204 reads as deleted and 202 (`cleanup_pending`) as deleted
    /// with photos still being removed (design DS6);
    /// fails_when=a 202 throws (the client would say "not deleted" about a
    /// deleted account) or the two outcomes are conflated;
    /// no_claim=none beyond protects.
    @Test func twoOhFourAndTwoOhTwoAreBothDeletions() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(statusCode: 204, body: Data())
        MockURLProtocol.stub(
            statusCode: 202,
            body: Data(#"{"code":"cleanup_pending","message":"Some photos will be removed later."}"#.utf8)
        )
        let service = try makeTestAccountService()

        #expect(try await service.deleteAccount(appleAuthorizationCode: nil) == .deleted)
        #expect(try await service.deleteAccount(appleAuthorizationCode: nil) == .deletedCleanupPending)
    }

    /// protects=an error answer surfaces its status and the body's stable
    /// `code`, which the view model maps to copy;
    /// fails_when=the code is lost, the status is wrong, or an error status
    /// is treated as success;
    /// no_claim=which codes the function sends (lib_test.ts).
    @Test func anErrorBodySurfacesItsStatusAndCode() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(
            statusCode: 400,
            body: Data(#"{"code":"apple_code_required","message":"Confirm with Apple first."}"#.utf8)
        )
        MockURLProtocol.stub(statusCode: 503, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8))
        let service = try makeTestAccountService()

        await #expect(throws: AccountService.Error.server(
            status: 400, code: "apple_code_required", message: "Confirm with Apple first."
        )) {
            try await service.deleteAccount(appleAuthorizationCode: nil)
        }
        await #expect(throws: AccountService.Error.server(status: 503, code: nil, message: nil)) {
            try await service.deleteAccount(appleAuthorizationCode: nil)
        }
    }

    /// protects=no HTTP answer is `.transport`, and no session at all is
    /// `.notSignedIn` with nothing sent;
    /// fails_when=a dropped connection reads as a server refusal, or a
    /// signed-out call sends a request without a bearer;
    /// no_claim=real network failure modes (a stubbed URLError stands in).
    @Test func noAnswerIsTransportAndNoSessionIsNotSignedIn() async throws {
        MockURLProtocol.reset() // empty queue: the stub fails the request with URLError(.unknown)
        let service = try makeTestAccountService()

        await #expect {
            try await service.deleteAccount(appleAuthorizationCode: nil)
        } throws: { error in
            if case .transport = error as? AccountService.Error { return true }
            return false
        }

        let requestSent = Captured(false)
        MockURLProtocol.stub(statusCode: 204, body: Data()) { _ in requestSent.set(true) }
        let signedOut = try makeTestAccountService(session: nil)
        await #expect(throws: AccountService.Error.notSignedIn) {
            try await signedOut.deleteAccount(appleAuthorizationCode: nil)
        }
        #expect(requestSent.get() == false)
        MockURLProtocol.reset()
    }
}

}
