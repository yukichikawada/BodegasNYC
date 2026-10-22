import Auth
import Foundation
import PostgREST
import Storage

/// A lock-protected box holding the current bearer token, read fresh by
/// Storage's `fetch`/`upload` closures on every request.
///
/// Necessary because, unlike `PostgrestClient.setAuth(_:)`, `StorageApi`'s
/// `setHeader(_:forKey:)` only updates the *instance* it's called on — and
/// `SupabaseStorageClient.from(_:)` (the only way `PhotoService` ever
/// touches Storage) builds a brand-new `StorageFileApi` from the client's
/// static `configuration.headers` each time, ignoring any prior
/// `setHeader` call entirely. A live-read token box in the transport
/// closures is the only place that's actually shared across every
/// `.from(bucket)` call.
private nonisolated final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String

    init(_ token: String) {
        self.token = token
    }

    func set(_ newToken: String) {
        lock.withLock { token = newToken }
    }

    func get() -> String {
        lock.withLock { token }
    }
}

/// Owns the three Supabase clients used by this app (only `Auth`,
/// `PostgREST`, and `Storage` are linked — no umbrella `Supabase` package,
/// no `Realtime`/`Functions`, matching the MVP's no-chat scope).
///
/// There's no umbrella `SupabaseClient` to do this wiring for us, so this
/// reimplements just the piece it normally handles: reacting to
/// `AuthClient.authStateChanges` and propagating the resulting token to
/// PostgREST (via `setAuth(_:)`) and Storage (via a live-read `TokenBox` —
/// see its doc comment for why `setHeader` alone doesn't work). Falls back
/// to the anon key (never to no `Authorization` header at all) so
/// unauthenticated public-read requests still carry a valid token, matching
/// what real Supabase clients send.
nonisolated final class SupabaseEnvironment: Sendable {
    let auth: AuthClient
    let postgrest: PostgrestClient
    let storage: SupabaseStorageClient

    /// `async`: awaits the first `authStateChanges` event (always emitted
    /// immediately, per that property's doc comment) before returning, so
    /// there's never a window where a caller holds an environment whose
    /// `postgrest`/`storage` clients haven't been given an `Authorization`
    /// header yet. Subsequent events (sign-in/out, token refresh) keep
    /// propagating via a background `Task` continuing the same iterator.
    ///
    /// Opts in to `emitLocalSessionAsInitialSession` (the SDK's next-major
    /// default; supabase-swift #822): the initial event carries the stored
    /// session as-is, possibly expired, and the SDK refreshes it in the
    /// background, emitting `tokenRefreshed` (or `signedOut`) afterwards.
    /// See `bearerToken(for:anonKey:)` for how an expired one is handled.
    init(config: SupabaseConfig, urlSession: URLSession = .shared) async {
        let anonKey = config.anonKey
        let tokenBox = TokenBox(anonKey)
        let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await urlSession.data(for: request)
        }

        auth = AuthClient(
            configuration: AuthClient.Configuration(
                url: config.projectURL.appendingPathComponent("auth/v1"),
                headers: ["apikey": anonKey],
                localStorage: AuthClient.Configuration.defaultLocalStorage,
                logger: nil,
                fetch: fetch,
                emitLocalSessionAsInitialSession: true
            )
        )
        postgrest = PostgrestClient(
            url: config.projectURL.appendingPathComponent("rest/v1"),
            schema: "public",
            headers: ["apikey": anonKey],
            logger: nil,
            fetch: fetch,
            decoder: PostgRESTDecoding.makeDecoder()
        )
        storage = SupabaseStorageClient(
            configuration: StorageClientConfiguration(
                url: config.projectURL.appendingPathComponent("storage/v1"),
                headers: ["apikey": anonKey],
                session: StorageHTTPSession(
                    fetch: { request in
                        var request = request
                        request.setValue("Bearer \(tokenBox.get())", forHTTPHeaderField: "Authorization")
                        return try await urlSession.data(for: request)
                    },
                    upload: { request, data in
                        var request = request
                        request.setValue("Bearer \(tokenBox.get())", forHTTPHeaderField: "Authorization")
                        return try await urlSession.upload(for: request, from: data)
                    }
                ),
                logger: nil
            )
        )

        let postgrest = postgrest
        func applyAuth(_ session: Session?) {
            let token = Self.bearerToken(for: session, anonKey: anonKey)
            postgrest.setAuth(token)
            tokenBox.set(token)
        }

        var iterator = auth.authStateChanges.makeAsyncIterator()
        if let (_, session) = await iterator.next() {
            applyAuth(session)
        }
        Task {
            while let (_, session) = await iterator.next() {
                applyAuth(session)
            }
        }
    }

    /// The bearer token to send for `session`: its access token while it's
    /// valid, otherwise the anon key. An expired session only reaches here
    /// as the initial event (see `init`), and sending its access token would
    /// get every request rejected until the background refresh lands;
    /// public reads work fine on the anon key in the meantime.
    static func bearerToken(for session: Session?, anonKey: String) -> String {
        guard let session, !session.isExpired else { return anonKey }
        return session.accessToken
    }
}
