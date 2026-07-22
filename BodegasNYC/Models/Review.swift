import Foundation

/// Mirrors a row in `public.reviews`. One review per (bodega, author),
/// enforced at the DB level by a unique constraint, not just app logic.
nonisolated struct Review: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var bodegaId: UUID
    var authorId: UUID
    var rating: Int
    var body: String?
    var isHidden: Bool
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, rating, body
        case bodegaId = "bodega_id"
        case authorId = "author_id"
        case isHidden = "is_hidden"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
