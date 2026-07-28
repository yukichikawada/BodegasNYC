import Foundation
import PostgREST
import Storage

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
