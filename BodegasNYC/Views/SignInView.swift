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

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Sign in to add bodegas, reviews, and photos")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Browsing never requires an account — this is only needed to contribute.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SignInWithAppleButton(.signIn, onRequest: configure, onCompletion: handle)
                .signInWithAppleButtonStyle(.black)
                .frame(height: 44)
                .padding(.top, 8)
                .disabled(isSigningIn)
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
                isSigningIn = false
                if sessionStore.isSignedIn {
                    dismiss()
                } else {
                    errorMessage = sessionStore.lastAuthError
                }
            }
        case .failure(let error):
            // The user simply dismissed Apple's sheet — not a real error.
            if (error as? ASAuthorizationError)?.code != .canceled {
                errorMessage = error.localizedDescription
            }
        }
    }
}
