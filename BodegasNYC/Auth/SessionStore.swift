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
    /// Whether the signed-in user has an `apple` identity, so deleting the
    /// account needs Apple's re-confirmation first (#127). `false` when
    /// signed out or when the user's identities are unknown (`nil`), which
    /// is the DEBUG email account's case on the local stack.
    private(set) var signedInWithApple = false
    /// The signed-in user's email. Only the DEBUG Account sheet shows it, in
    /// place of "Signed in with Apple." for the test account.
    private(set) var currentUserEmail: String?
    /// Set by `completeAppleSignIn`/`signOut` (and, in DEBUG builds only,
    /// `signIn(email:password:)`) on failure, cleared at the start of each
    /// — `SignInView` reads this once per attempt rather than binding
    /// continuously, so a stale error never resurfaces on a later,
    /// unrelated sheet presentation.
    private(set) var lastAuthError: String?

    private let auth: AuthClient
    /// Identified with the user id while signed in, reset on every sign-out
    /// (#147 eng E2); see `apply(_:)`.
    @ObservationIgnored private let telemetry: Telemetry
    /// Set while a user-initiated sign-out is in flight, so `apply(_:)`
    /// captures `signed_out` just before the reset, whichever path (this
    /// call or the `authStateChanges` listener) clears the user first.
    @ObservationIgnored private var capturesSignedOut = false

    var isSignedIn: Bool { currentUserID != nil }

    init(auth: AuthClient, telemetry: Telemetry = Telemetry(sinks: [])) {
        self.auth = auth
        self.telemetry = telemetry
        apply(auth.currentSession?.user)
        Task {
            for await (_, session) in auth.authStateChanges {
                apply(session?.user)
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
            apply(session.user)
            telemetry.capture(.signedIn)
        } catch {
            telemetry.record(error, context: "session.apple_sign_in")
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
            apply(session.user)
            telemetry.capture(.signedIn)
        } catch {
            telemetry.record(error, context: "session.email_sign_in")
            lastAuthError = error.localizedDescription
        }
    }
    #endif

    /// `emitsEvent` is false only after an account deletion, whose own
    /// event follows the reset (`AccountViewModel.delete`).
    func signOut(emitsEvent: Bool = true) async {
        lastAuthError = nil
        capturesSignedOut = emitsEvent
        defer { capturesSignedOut = false }
        do {
            try await auth.signOut()
            apply(nil)
        } catch {
            telemetry.record(error, context: "session.sign_out")
            lastAuthError = error.localizedDescription
        }
    }

    /// The one place the user-derived state is set, so `currentUserID`,
    /// `signedInWithApple` and `currentUserEmail` never disagree. Telemetry
    /// follows the id (eng E2): nil to A identifies, A to nil resets, A to B
    /// resets then identifies, A to A does nothing.
    private func apply(_ user: User?) {
        let previousUserID = currentUserID
        let userID = user?.id
        if previousUserID != userID {
            if previousUserID != nil {
                if userID == nil, capturesSignedOut { telemetry.capture(.signedOut) }
                telemetry.reset()
            }
            if let userID { telemetry.identify(userID) }
        }
        currentUserID = user?.id
        signedInWithApple = Self.hasAppleIdentity(user)
        currentUserEmail = user?.email
    }

    nonisolated static func hasAppleIdentity(_ user: User?) -> Bool {
        user?.identities?.contains { $0.provider == "apple" } ?? false
    }
}
