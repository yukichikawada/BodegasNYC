import Foundation

/// Mirrors a row in `public.photos`. No `updatedAt`/mutable fields besides
/// `isHidden`, which only the flags auto-hide trigger touches.
nonisolated struct Photo: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var bodegaId: UUID
    var uploadedBy: UUID
    var storagePath: String
    var isHidden: Bool
    var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case bodegaId = "bodega_id"
        case uploadedBy = "uploaded_by"
        case storagePath = "storage_path"
        case isHidden = "is_hidden"
        case createdAt = "created_at"
    }
}
