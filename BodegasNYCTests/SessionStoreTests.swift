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

    @Test func signOutClearsAnEstablishedSession() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data())
        let store = SessionStore(auth: try makeTestAuthClient(session: makeTestSession()))
        #expect(store.isSignedIn)

        await store.signOut()

        #expect(store.isSignedIn == false)
        #expect(store.currentUserID == nil)
    }
}

}
