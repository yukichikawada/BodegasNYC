//
//  SupabaseFetchTests.swift
//  BodegasNYCTests
//
//  Verifies SupabaseEnvironment's auth-header wiring: with no signed-in
//  session, both PostgREST and Storage requests should carry the anon key
//  as a Bearer token — not be missing Authorization entirely. Serialized
//  because MockURLProtocol's stub queue is process-wide static state.
//

import Foundation
import PostgREST
import Storage
import Testing

@testable import BodegasNYC

extension NetworkingTests {

@Suite
struct SupabaseFetchTests {

    @Test func propagatesAnonKeyToPostgrestByDefault() async throws {
        MockURLProtocol.reset()
        let capturedAuthHeader = Captured<String?>(nil)
        let capturedAPIKeyHeader = Captured<String?>(nil)
        MockURLProtocol.stub(body: Data("[]".utf8)) { request in
            capturedAuthHeader.set(request.value(forHTTPHeaderField: "Authorization"))
            capturedAPIKeyHeader.set(request.value(forHTTPHeaderField: "apikey"))
        }

        let environment = await SupabaseEnvironment(
            config: SupabaseConfig(
                projectURL: URL(string: "https://example.supabase.co")!,
                anonKey: "test-anon-key"
            ),
            urlSession: MockURLProtocol.makeSession()
        )

        _ = try await environment.postgrest.from("bodegas").select().execute() as PostgrestResponse<Void>

        #expect(capturedAuthHeader.get() == "Bearer test-anon-key")
        #expect(capturedAPIKeyHeader.get() == "test-anon-key")
    }

    @Test func propagatesAnonKeyToStorageByDefault() async throws {
        MockURLProtocol.reset()
        let capturedAuthHeader = Captured<String?>(nil)
        MockURLProtocol.stub(body: Data("[]".utf8)) { request in
            capturedAuthHeader.set(request.value(forHTTPHeaderField: "Authorization"))
        }

        let environment = await SupabaseEnvironment(
            config: SupabaseConfig(
                projectURL: URL(string: "https://example.supabase.co")!,
                anonKey: "test-anon-key"
            ),
            urlSession: MockURLProtocol.makeSession()
        )

        _ = try await environment.storage.from("photos").list()

        #expect(capturedAuthHeader.get() == "Bearer test-anon-key")
    }

    @Test func bearerTokenUsesValidSessionAccessToken() {
        let session = makeTestSession(accessToken: "user-token")

        #expect(SupabaseEnvironment.bearerToken(for: session, anonKey: "test-anon-key") == "user-token")
    }

    @Test func bearerTokenFallsBackToAnonKeyForExpiredSession() {
        let session = makeTestSession(accessToken: "stale-token", expiresIn: -60)

        #expect(SupabaseEnvironment.bearerToken(for: session, anonKey: "test-anon-key") == "test-anon-key")
    }

    @Test func bearerTokenFallsBackToAnonKeyWithNoSession() {
        #expect(SupabaseEnvironment.bearerToken(for: nil, anonKey: "test-anon-key") == "test-anon-key")
    }
}

}
