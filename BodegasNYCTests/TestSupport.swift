import Auth
import Foundation
import PostgREST
import Storage
import SwiftData

@testable import BodegasNYC

/// A bare `PostgrestClient` pointed at a `MockURLProtocol`-backed session —
/// used by service tests that only need to verify request shape/decoding,
/// not the `SupabaseEnvironment` auth-propagation wiring (see
/// `SupabaseFetchTests` for that).
func makeTestPostgrestClient() -> PostgrestClient {
    let session = MockURLProtocol.makeSession()
    return PostgrestClient(
        url: URL(string: "https://example.supabase.co/rest/v1")!,
        schema: "public",
        headers: ["apikey": "test-anon-key"],
        logger: nil,
        fetch: { try await session.data(for: $0) },
        decoder: PostgRESTDecoding.makeDecoder()
    )
}

func makeTestStorageClient() -> SupabaseStorageClient {
    let session = MockURLProtocol.makeSession()
    return SupabaseStorageClient(
        configuration: StorageClientConfiguration(
            url: URL(string: "https://example.supabase.co/storage/v1")!,
            headers: ["apikey": "test-anon-key"],
            session: StorageHTTPSession(session: session),
            logger: nil
        )
    )
}

/// Builds a minimal `Bodega` via its real `Codable` decoding path (`Bodega`
/// has no memberwise initializer — defining `init(from:)` suppresses the
/// synthesized one) rather than adding a test-only initializer to
/// production code.
///
/// Built as a dictionary through `JSONSerialization` rather than string
/// interpolation into a JSON literal, so names/addresses containing quotes
/// or non-ASCII characters (e.g. `BodegaFilterTests`' diacritic cases) are
/// escaped correctly.
func makeTestBodega(
    id: UUID = UUID(),
    name: String = "Test Bodega",
    latitude: Double = 40.7291,
    longitude: Double = -73.9965,
    address: String? = nil,
    hasCat: Bool = false,
    servesHotFood: Bool = false,
    sellsCigarettes: Bool = false,
    sellsBeer: Bool = false,
    sellsLotto: Bool = false,
    hasAtm: Bool = false
) throws -> Bodega {
    let object: [String: Any] = [
        "id": id.uuidString,
        "created_by": "00000000-0000-0000-0000-000000000000",
        "name": name,
        "latitude": latitude,
        "longitude": longitude,
        "address": address ?? NSNull(),
        "has_cat": hasCat,
        "serves_hot_food": servesHotFood,
        "sells_cigarettes": sellsCigarettes,
        "sells_beer": sellsBeer,
        "sells_lotto": sellsLotto,
        "has_atm": hasAtm,
        "hours": NSNull(),
        "is_hidden": false,
        "created_at": "2026-07-21T18:30:00.000000+00:00",
        "updated_at": "2026-07-21T18:30:00.000000+00:00"
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    return try PostgRESTDecoding.makeDecoder().decode(Bodega.self, from: data)
}

/// An in-memory `ModelContainer` for the Streets Walked models
/// (`WalkedPoint`, plus `WalkedBlock` and `WalkedMatchState` since #108) —
/// isolated per test, never touches disk.
@MainActor
func makeInMemoryModelContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Schema(StreetsWalkedSchema.models),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}

/// An in-memory `AuthLocalStorage` double — never touches the Keychain, one
/// fresh instance per test.
final class InMemoryAuthLocalStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func store(key: String, value: Data) throws { lock.withLock { storage[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { storage[key] } }
    func remove(key: String) throws { lock.withLock { storage[key] = nil } }
}

/// Builds a `Session` via its real memberwise initializer, defaulting to a
/// long-lived expiry so `AuthClient.session`/`SessionStore` resolve it
/// without a network refresh call (see `Session.isExpired`). `identities`
/// stays `nil` by default, the shape `SessionStore.signedInWithApple` reads
/// as "not Apple"; pass `makeTestIdentity(provider:userID:)` values to set
/// them (#127).
func makeTestSession(
    userID: UUID = UUID(),
    accessToken: String = "test-access-token",
    expiresIn: TimeInterval = 3600,
    identities: [UserIdentity]? = nil
) -> Session {
    Session(
        accessToken: accessToken,
        tokenType: "bearer",
        expiresIn: expiresIn,
        expiresAt: Date().addingTimeInterval(expiresIn).timeIntervalSince1970,
        refreshToken: "test-refresh-token",
        user: User(
            id: userID,
            appMetadata: [:],
            userMetadata: [:],
            aud: "authenticated",
            createdAt: Date(),
            updatedAt: Date(),
            identities: identities
        )
    )
}

/// One `UserIdentity` for `makeTestSession(identities:)`: `provider` is
/// "apple" or "email".
func makeTestIdentity(provider: String, userID: UUID) -> UserIdentity {
    UserIdentity(
        id: provider == "apple" ? "001234.test-apple-sub.0001" : userID.uuidString,
        identityId: UUID(),
        userId: userID,
        identityData: [:],
        provider: provider,
        createdAt: nil,
        lastSignInAt: nil,
        updatedAt: nil
    )
}

/// An `AuthClient` backed by `MockURLProtocol` and an isolated in-memory
/// local storage, optionally pre-seeded with `session` under the SDK's real
/// default storage key (`"supabase.auth.token"`), encoded exactly the way
/// the live `SessionStorage.live.store(_:)` does it (a plain `JSONEncoder()`
/// — *not* `AuthClient.Configuration.jsonEncoder`) so `auth.currentSession`
/// resolves with no network call.
func makeTestAuthClient(session: Session? = nil) throws -> AuthClient {
    let storage = InMemoryAuthLocalStorage()
    if let session {
        try storage.store(key: "supabase.auth.token", value: JSONEncoder().encode(session))
    }
    let urlSession = MockURLProtocol.makeSession()
    return AuthClient(
        configuration: AuthClient.Configuration(
            url: URL(string: "https://example.supabase.co/auth/v1")!,
            headers: ["apikey": "test-anon-key"],
            localStorage: storage,
            logger: nil,
            fetch: { try await urlSession.data(for: $0) }
        )
    )
}
