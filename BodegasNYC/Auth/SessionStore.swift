import Auth
import Foundation
import Observation

/// Wraps the app's single `AuthClient` (owned by `SupabaseEnvironment`,
/// constructed once in `AppEnvironment.init`) to expose Sign in with Apple
/// as observable `@MainActor` state for `BrowseView`/`SignInView`.
///
/// Named `Store` rather than `Client` (contrast `LocationPermissionClient`,
/// which owns the `CLLocationManager` it wraps): `auth` is handed in,
/// already constructed by `SupabaseEnvironment` — this type only derives
/// and republishes state from it.
///
/// Constructed once and held for the app's full session, same as
/// `SupabaseEnvironment`/`LocationPermissionClient`/`StreetsWalkedViewModel`
/// — the background `Task` below is never expected to be torn down
/// mid-session, so it captures `self` directly rather than adding
/// `weak self`/cancellation ceremony that only matters for an instance
/// expected to deinit.
@MainActor
@Observable
final class SessionStore {
    private(set) var currentUserID: UUID?
    /// Set by `completeAppleSignIn`/`signIn`/`signOut` on failure, cleared at the
    /// start of each — `SignInView` reads this once per attempt rather
    /// than binding continuously, so a stale error never resurfaces on a
    /// later, unrelated sheet presentation.
    private(set) var lastAuthError: String?

    private let auth: AuthClient

    var isSignedIn: Bool { currentUserID != nil }

    init(auth: AuthClient) {
        self.auth = auth
        currentUserID = auth.currentSession?.user.id
        Task {
            for await (_, session) in auth.authStateChanges {
                currentUserID = session?.user.id
            }
        }
    }

    /// Given Apple's already-extracted identity token and the raw nonce
    /// used to request it (see `AppleSignInNonce`/`SignInView` —
    /// extracting these from `ASAuthorization` is deliberately kept out of
    /// this type: there's no public initializer for
    /// `ASAuthorizationAppleIDCredential`, matching this codebase's stance
    /// on other OS-delegate boundaries, e.g. `CLLocationManagerDelegate`).
    func completeAppleSignIn(idToken: String, nonce: String) async {
        lastAuthError = nil
        do {
            let session = try await auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
            )
            currentUserID = session.user.id
        } catch {
            lastAuthError = error.localizedDescription
        }
    }

    #if DEBUG
    /// DEBUG-only email/password sign-in so QA agents can exercise
    /// authenticated flows in the Simulator, where Sign in with Apple can't
    /// be driven (see `SignInView`'s "Test account (DEBUG)" section).
    /// Compiled out of Release entirely.
    func signIn(email: String, password: String) async {
        lastAuthError = nil
        do {
            let session = try await auth.signIn(email: email, password: password)
            currentUserID = session.user.id
        } catch {
            lastAuthError = error.localizedDescription
        }
    }
    #endif

    func signOut() async {
        lastAuthError = nil
        do {
            try await auth.signOut()
            currentUserID = nil
        } catch {
            lastAuthError = error.localizedDescription
        }
    }
}
