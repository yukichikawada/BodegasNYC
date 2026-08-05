import CryptoKit
import Foundation

/// Nonce generation/hashing for Sign in with Apple's replay-protection
/// handshake: a random raw nonce is SHA256-hashed before being sent to
/// Apple as `ASAuthorizationAppleIDRequest.nonce`; the *raw* nonce is later
/// handed to Supabase's `OpenIDConnectCredentials(nonce:)`, which verifies
/// it against the hash embedded in Apple's identity token claims. Pure and
/// independent of `ASAuthorization` — unlike `SignInView`'s delegate-
/// boundary code, this is fully unit-testable.
nonisolated enum AppleSignInNonce {
    private static let charset: [Character] =
        Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")

    static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
            for random in randoms where remainingLength > 0 {
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
