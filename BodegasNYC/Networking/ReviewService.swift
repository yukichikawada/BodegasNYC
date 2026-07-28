import Foundation
import PostgREST

/// Payload for creating a review. `bodegaId`/`authorId` must be supplied by
/// the caller — RLS's `with check (auth.uid() = author_id)` doesn't fill it
/// in for us.
nonisolated struct NewReview: Encodable, Sendable {
    var bodegaId: UUID
    var authorId: UUID
    var rating: Int
    var body: String?

    private enum CodingKeys: String, CodingKey {
        case rating, body
        case bodegaId = "bodega_id"
        case authorId = "author_id"
    }
}

/// Partial update — the only fields an author can change on their review.
nonisolated struct ReviewUpdate: Encodable, Sendable {
    var rating: Int?
    var body: String?
}

/// CRUD over `public.reviews`, matching `reviews_select` / `reviews_insert`
/// / `reviews_update` / `reviews_delete` RLS: reads are public, writes are
/// author-only.
nonisolated struct ReviewService: Sendable {
    private let postgrest: PostgrestClient

    init(postgrest: PostgrestClient) {
        self.postgrest = postgrest
    }

    func fetchAll(bodegaId: UUID) async throws -> [Review] {
        try await postgrest
            .from("reviews")
            .select()
            .eq("bodega_id", value: bodegaId)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    @discardableResult
    func insert(_ draft: NewReview) async throws -> Review {
        try await postgrest
            .from("reviews")
            .insert(draft)
            .select()
            .single()
            .execute()
            .value
    }

    @discardableResult
    func update(id: UUID, _ values: ReviewUpdate) async throws -> Review {
        try await postgrest
            .from("reviews")
            .update(values)
            .eq("id", value: id)
            .select()
            .single()
            .execute()
            .value
    }

    func delete(id: UUID) async throws {
        try await postgrest
            .from("reviews")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}
