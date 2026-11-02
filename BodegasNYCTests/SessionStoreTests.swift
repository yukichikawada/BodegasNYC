import Auth
import Foundation
import Testing

@testable import BodegasNYC

extension NetworkingTests {

@Suite
@MainActor
struct SessionStoreTests {
    private static func sessionJSON(userID: UUID) -> String {
        """
        {
          "access_token": "new-access-token",
          "token_type": "bearer",
          "expires_in": 3600,
          "expires_at": 4102444800,
          "refresh_token": "new-refresh-token",
          "user": {
            "id": "\(userID.uuidString)",
            "aud": "authenticated",
            "created_at": "2026-07-21T18:30:00Z",
            "updated_at": "2026-07-21T18:30:00Z",
            "app_metadata": {},
            "user_metadata": {},
            "is_anonymous": false
          }
        }
        """
    }

    @Test func startsSignedOutWithNoStoredSession() throws {
        let store = SessionStore(auth: try makeTestAuthClient())
        #expect(store.isSignedIn == false)
    }

    @Test func seedsSignedInStateFromAnAlreadyStoredSession() throws {
        let userID = UUID()
        let store = SessionStore(auth: try makeTestAuthClient(session: makeTestSession(userID: userID)))
        #expect(store.isSignedIn)
        #expect(store.currentUserID == userID)
    }

    @Test func completeAppleSignInEstablishesASession() async throws {
        MockURLProtocol.reset()
        let userID = UUID()
        MockURLProtocol.stub(body: Data(Self.sessionJSON(userID: userID).utf8))
        let store = SessionStore(auth: try makeTestAuthClient())

        await store.completeAppleSignIn(idToken: "test-id-token", nonce: "test-nonce")

        #expect(store.isSignedIn)
        #expect(store.currentUserID == userID)
        #expect(store.lastAuthError == nil)
    }

    @Test func completeAppleSignInSurfacesAFailure() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(
            statusCode: 400,
            body: Data("{\"error\":\"invalid_grant\",\"error_description\":\"Invalid id_token\"}".utf8)
        )
        let store = SessionStore(auth: try makeTestAuthClient())

        await store.completeAppleSignIn(idToken: "bad-token", nonce: "test-nonce")

        #expect(store.isSignedIn == false)
        #expect(store.lastAuthError != nil)
    }

    #if DEBUG
    @Test func emailPasswordSignInEstablishesASession() async throws {
        MockURLProtocol.reset()
        let userID = UUID()
        let requestedURL = Captured<URL?>(nil)
        MockURLProtocol.stub(body: Data(Self.sessionJSON(userID: userID).utf8)) { request in
            requestedURL.set(request.url)
        }
        let store = SessionStore(auth: try makeTestAuthClient())

        await store.signIn(email: "qa@example.com", password: "test-password")

        #expect(store.isSignedIn)
        #expect(store.currentUserID == userID)
        #expect(store.lastAuthError == nil)
        let url = try #require(requestedURL.get())
        #expect(url.path == "/auth/v1/token")
        #expect(url.query?.contains("grant_type=password") == true)
    }

    @Test func emailPasswordSignInSurfacesAFailure() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(
            statusCode: 400,
            body: Data("{\"error\":\"invalid_grant\",\"error_description\":\"Invalid login credentials\"}".utf8)
        )
        let store = SessionStore(auth: try makeTestAuthClient())

        await store.signIn(email: "qa@example.com", password: "wrong-password")

        #expect(store.isSignedIn == false)
        #expect(store.lastAuthError != nil)
    }
    #endif

    /// protects=an Apple user's Account sheet asks Apple first (#127): a
    /// stored session with an `apple` identity reads `signedInWithApple`,
    /// and signing out clears it;
    /// fails_when=the flag stays false for an Apple user, or survives sign-out;
    /// no_claim=what GoTrue returns in `identities` for a real Apple sign-in
    /// (device test under #139).
    @Test func signedInWithAppleIsTrueForAnAppleIdentity() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data())
        let userID = UUID()
        let session = makeTestSession(
            userID: userID,
            identities: [
                makeTestIdentity(provider: "email", userID: userID),
                makeTestIdentity(provider: "apple", userID: userID)
            ]
        )
        let store = SessionStore(auth: try makeTestAuthClient(session: session))
        #expect(store.signedInWithApple)

        await store.signOut()

        #expect(store.signedInWithApple == false)
    }

    /// protects=a DEBUG email user, and a user whose identities are unknown,
    /// skip the Apple step (eng "code quality": `nil` identities read false);
    /// fails_when=an email-only or identity-less session reads as Apple;
    /// no_claim=none beyond protects.
    @Test func signedInWithAppleIsFalseForEmailOrUnknownIdentities() throws {
        let userID = UUID()
        let email = SessionStore(auth: try makeTestAuthClient(session: makeTestSession(
            userID: userID, identities: [makeTestIdentity(provider: "email", userID: userID)]
        )))
        let unknown = SessionStore(auth: try makeTestAuthClient(session: makeTestSession(identities: nil)))

        #expect(email.isSignedIn)
        #expect(email.signedInWithApple == false)
        #expect(unknown.isSignedIn)
        #expect(unknown.signedInWithApple == false)
    }

    @Test func signOutClearsAnEstablishedSession() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data())
        let store = SessionStore(auth: try makeTestAuthClient(session: makeTestSession()))
        #expect(store.isSignedIn)

        await store.signOut()

        #expect(store.isSignedIn == false)
        #expect(store.currentUserID == nil)
    }

    // MARK: Telemetry identity (#147 eng E2)

    /// Lets the store's `authStateChanges` listener deliver the initial
    /// session before a test acts, so its echo cannot land mid-test.
    private static func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// protects=nil to A identifies with A's id (a stored session at launch,
    /// or a sign-in) and captures `signed_in` after the identify, so the
    /// event is attributed; fails_when=no identify, a second identify, or
    /// the event before the identify; no_claim=PostHog's person merge.
    @Test func signInIdentifiesThenCapturesSignedIn() async throws {
        MockURLProtocol.reset()
        let userID = UUID()
        MockURLProtocol.stub(body: Data(Self.sessionJSON(userID: userID).utf8))
        let (telemetry, sink) = makeRecordingTelemetry()
        let store = SessionStore(auth: try makeTestAuthClient(), telemetry: telemetry)
        await Self.settle()

        await store.completeAppleSignIn(idToken: "test-id-token", nonce: "test-nonce")
        await Self.settle()

        #expect(sink.calls == [.identify(userID), .capture(.signedIn)])
    }

    /// protects=A to nil resets, after `signed_out` is captured for A;
    /// fails_when=no reset, two resets, or the event after the reset;
    /// no_claim=the SDKs' new anonymous id (live QA, AC 6).
    @Test func signOutCapturesThenResets() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data())
        let userID = UUID()
        let (telemetry, sink) = makeRecordingTelemetry()
        let store = SessionStore(auth: try makeTestAuthClient(session: makeTestSession(userID: userID)), telemetry: telemetry)
        await Self.settle()

        await store.signOut()
        await Self.settle()

        #expect(sink.calls == [.identify(userID), .capture(.signedOut), .reset])
    }

    /// protects=A to B resets then identifies B, and A to A does nothing;
    /// fails_when=B is identified on top of A's identity, or a repeat of
    /// the same user re-identifies; no_claim=none beyond protects.
    @Test func switchingUsersResetsThenIdentifiesAndTheSameUserIsANoOp() async throws {
        MockURLProtocol.reset()
        let userA = UUID()
        let userB = UUID()
        MockURLProtocol.stub(body: Data(Self.sessionJSON(userID: userA).utf8))
        MockURLProtocol.stub(body: Data(Self.sessionJSON(userID: userB).utf8))
        let (telemetry, sink) = makeRecordingTelemetry()
        let store = SessionStore(auth: try makeTestAuthClient(session: makeTestSession(userID: userA)), telemetry: telemetry)
        await Self.settle()

        await store.completeAppleSignIn(idToken: "same-user", nonce: "n")
        await Self.settle()
        #expect(sink.identity == [.identify(userA)])

        await store.completeAppleSignIn(idToken: "other-user", nonce: "n")
        await Self.settle()
        #expect(sink.identity == [.identify(userA), .reset, .identify(userB)])
    }

    /// protects=the transitions run while sharing is off (E2): the sign-out
    /// reset reaches the sinks, the sign-in identify waits, and turning
    /// sharing back on identifies the signed-in user; fails_when=a reset is
    /// skipped while off, or an identify leaks while off; no_claim=none
    /// beyond protects.
    @Test func transitionsRunWhileSharingIsOff() async throws {
        MockURLProtocol.reset()
        let userA = UUID()
        let userB = UUID()
        MockURLProtocol.stub(body: Data())
        MockURLProtocol.stub(body: Data(Self.sessionJSON(userID: userB).utf8))
        let (telemetry, sink) = makeRecordingTelemetry()
        let store = SessionStore(auth: try makeTestAuthClient(session: makeTestSession(userID: userA)), telemetry: telemetry)
        await Self.settle()
        telemetry.setEnabled(false)

        await store.signOut()
        await Self.settle()
        await store.completeAppleSignIn(idToken: "test-id-token", nonce: "test-nonce")
        await Self.settle()
        #expect(sink.calls == [.identify(userA), .stop, .reset])

        telemetry.setEnabled(true)
        #expect(sink.calls == [.identify(userA), .stop, .reset, .start, .identify(userB)])
    }
}

}
