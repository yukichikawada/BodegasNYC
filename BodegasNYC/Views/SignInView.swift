import AuthenticationServices
import SwiftUI

/// Presented as a `.sheet` from `BrowseView`'s account toolbar item when
/// signed out. Uses SwiftUI's native `SignInWithAppleButton` rather than
/// driving `ASAuthorizationController` by hand.
struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    private let sessionStore: SessionStore
    @State private var currentNonce: String?
    @State private var errorMessage: String?
    @State private var isSigningIn = false
    #if DEBUG
    @State private var debugEmail = ""
    @State private var debugPassword = ""
    #endif

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(AppCopy.signInTitle.copy.text)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(AppCopy.signInBody.copy.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SignInWithAppleButton(.signIn, onRequest: configure, onCompletion: handle)
                .signInWithAppleButtonStyle(.black)
                .frame(height: 44)
                .padding(.top, 8)
                .disabled(isSigningIn)
            #if DEBUG
            debugEmailSignInSection
            #endif
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding()
    }

    private func configure(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = AppleSignInNonce.randomNonceString()
        currentNonce = nonce
        request.nonce = AppleSignInNonce.sha256(nonce)
    }

    private func handle(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let nonce = currentNonce
            else {
                errorMessage = "Couldn't read Apple's response. Please try again."
                return
            }
            isSigningIn = true
            Task {
                await sessionStore.completeAppleSignIn(idToken: idToken, nonce: nonce)
                finishSignInAttempt()
            }
        case .failure(let error):
            // The user simply dismissed Apple's sheet — not a real error.
            if (error as? ASAuthorizationError)?.code != .canceled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishSignInAttempt() {
        isSigningIn = false
        if sessionStore.isSignedIn {
            dismiss()
        } else {
            errorMessage = sessionStore.lastAuthError
        }
    }
}

#if DEBUG
/// DEBUG-only email/password sign-in, so QA agents can drive authenticated
/// flows in the Simulator without Sign in with Apple. The one-tap test
/// account button reads `TEST_ACCOUNT_EMAIL`/`TEST_ACCOUNT_PASSWORD` from
/// Info.plist, populated from a gitignored `Local.xcconfig` via
/// `Config/Debug.xcconfig` — see CLAUDE.md. Compiled out of Release.
extension SignInView {
    private static var testAccountCredentials: (email: String, password: String)? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard
            let email = info["TEST_ACCOUNT_EMAIL"] as? String, !email.isEmpty,
            let password = info["TEST_ACCOUNT_PASSWORD"] as? String, !password.isEmpty
        else { return nil }
        return (email, password)
    }

    @ViewBuilder
    var debugEmailSignInSection: some View {
        VStack(spacing: 8) {
            Divider()
                .padding(.vertical, 8)
            // Hidden entirely when Local.xcconfig doesn't supply both keys.
            if let credentials = Self.testAccountCredentials {
                Text("Test account (DEBUG)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Sign in with test account") {
                    debugSignIn(email: credentials.email, password: credentials.password)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("debug.signInWithTestAccount")
                .padding(.bottom, 8)
            }
            Text("Email sign-in (DEBUG)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Email", text: $debugEmail)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("debug.email")
            SecureField("Password", text: $debugPassword)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("debug.password")
            Button("Sign In") {
                debugSignIn(email: debugEmail, password: debugPassword)
            }
            .disabled(debugEmail.isEmpty || debugPassword.isEmpty)
            .accessibilityIdentifier("debug.signIn")
        }
        .disabled(isSigningIn)
    }

    private func debugSignIn(email: String, password: String) {
        errorMessage = nil
        isSigningIn = true
        Task {
            await sessionStore.signIn(email: email, password: password)
            finishSignInAttempt()
        }
    }
}
#endif
