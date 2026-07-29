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
func makeTestBodega(
    id: UUID = UUID(),
    name: String = "Test Bodega",
    latitude: Double,
    longitude: Double
) throws -> Bodega {
    let json = """
    {
      "id": "\(id.uuidString)",
      "created_by": "00000000-0000-0000-0000-000000000000",
      "name": "\(name)",
      "latitude": \(latitude),
      "longitude": \(longitude),
      "address": null,
      "has_cat": false,
      "serves_hot_food": false,
      "sells_cigarettes": false,
      "sells_beer": false,
      "sells_lotto": false,
      "hours": null,
      "is_hidden": false,
      "created_at": "2026-07-21T18:30:00.000000+00:00",
      "updated_at": "2026-07-21T18:30:00.000000+00:00"
    }
    """
    return try PostgRESTDecoding.makeDecoder().decode(Bodega.self, from: Data(json.utf8))
}

/// An in-memory `ModelContainer` for `WalkedPoint` — isolated per test,
/// never touches disk.
@MainActor
func makeInMemoryModelContainer() throws -> ModelContainer {
    try ModelContainer(
        for: WalkedPoint.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}
