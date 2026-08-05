import Testing

@testable import BodegasNYC

@Suite
struct AppleSignInNonceTests {
    @Test func randomNonceStringProducesTheRequestedLength() {
        #expect(AppleSignInNonce.randomNonceString(length: 32).count == 32)
    }

    @Test func randomNonceStringsAreNotRepeated() {
        #expect(AppleSignInNonce.randomNonceString() != AppleSignInNonce.randomNonceString())
    }

    @Test func sha256IsDeterministicAndMatchesAKnownDigest() {
        #expect(
            AppleSignInNonce.sha256("hello")
                == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }
}
