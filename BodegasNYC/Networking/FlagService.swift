import Foundation
import PostgREST

/// Payload for creating a flag. Encodes `target` into whichever single FK
/// column it represents, mirroring the DB's exclusive-arc CHECK — see
/// `FlagTarget` in `Models/Flag.swift`.
nonisolated struct NewFlag: Encodable, Sendable {
    var reporterId: UUID
    var target: FlagTarget
    var reason: String?

    private enum CodingKeys: String, CodingKey {
        case reason
        case reporterId = "reporter_id"
        case bodegaId = "bodega_id"
        case reviewId = "review_id"
        case photoId = "photo_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reporterId, forKey: .reporterId)
        try container.encodeIfPresent(reason, forKey: .reason)
        switch target {
        case .bodega(let id):
            try container.encode(id, forKey: .bodegaId)
        case .review(let id):
            try container.encode(id, forKey: .reviewId)
        case .photo(let id):
            try container.encode(id, forKey: .photoId)
        }
    }
}

/// Reads/creates over `public.flags`, matching `flags_select` /
/// `flags_insert` RLS. No update/delete methods — no such policy exists
/// ("unflagging isn't a v1 feature").
nonisolated struct FlagService: Sendable {
    private let postgrest: PostgrestClient

    init(postgrest: PostgrestClient) {
        self.postgrest = postgrest
    }

    /// Rows returned are exactly the ones the current user reported —
    /// `flags_select`'s RLS filters to `auth.uid() = reporter_id`.
    func fetchMine() async throws -> [Flag] {
        try await postgrest
            .from("flags")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    @discardableResult
    func insert(_ draft: NewFlag) async throws -> Flag {
        try await postgrest
            .from("flags")
            .insert(draft)
            .select()
            .single()
            .execute()
            .value
    }
}
