import Foundation

/// What a flag targets — mirrors the DB's "exactly one of three FKs"
/// exclusive-arc constraint as a proper Swift enum instead of three loose
/// optionals at every call site.
nonisolated enum FlagTarget: Sendable, Hashable {
    case bodega(UUID)
    case review(UUID)
    case photo(UUID)
}

/// Mirrors a row in `public.flags`.
nonisolated struct Flag: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var reporterId: UUID
    var bodegaId: UUID?
    var reviewId: UUID?
    var photoId: UUID?
    var reason: String?
    var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, reason
        case reporterId = "reporter_id"
        case bodegaId = "bodega_id"
        case reviewId = "review_id"
        case photoId = "photo_id"
        case createdAt = "created_at"
    }

    var target: FlagTarget {
        if let bodegaId { return .bodega(bodegaId) }
        if let reviewId { return .review(reviewId) }
        if let photoId { return .photo(photoId) }
        preconditionFailure("Flag row violates exactly-one-target invariant")
    }
}
