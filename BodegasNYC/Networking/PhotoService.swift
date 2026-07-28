import Foundation
import PostgREST
import Storage

/// Payload for the `photos` row created after a successful Storage upload.
/// `storagePath` must match the path actually used for the upload.
nonisolated struct NewPhotoRecord: Encodable, Sendable {
    var bodegaId: UUID
    var uploadedBy: UUID
    var storagePath: String

    private enum CodingKeys: String, CodingKey {
        case bodegaId = "bodega_id"
        case uploadedBy = "uploaded_by"
        case storagePath = "storage_path"
    }
}

/// Storage upload + `public.photos` CRUD, matching `photos_select` /
/// `photos_insert` / `photos_delete` RLS (no update policy — nothing
/// mutable besides `is_hidden`, which only the flags auto-hide trigger
/// touches).
///
/// Bucket named `"photos"` — no bucket-naming convention existed before
/// this slice. `storage_path` (the DB column) is the full bucket-relative
/// path, namespaced as `"<bodegaId>/<uuid>.<extension>"` on upload.
nonisolated struct PhotoService: Sendable {
    static let bucket = "photos"

    private let postgrest: PostgrestClient
    private let storage: SupabaseStorageClient

    init(postgrest: PostgrestClient, storage: SupabaseStorageClient) {
        self.postgrest = postgrest
        self.storage = storage
    }

    func fetchAll(bodegaId: UUID) async throws -> [Photo] {
        try await postgrest
            .from("photos")
            .select()
            .eq("bodega_id", value: bodegaId)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    @discardableResult
    func upload(
        bodegaId: UUID,
        uploadedBy: UUID,
        data: Data,
        fileExtension: String,
        contentType: String
    ) async throws -> Photo {
        let path = "\(bodegaId)/\(UUID().uuidString).\(fileExtension)"
        _ = try await storage.from(Self.bucket).upload(
            path,
            data: data,
            options: FileOptions(contentType: contentType)
        )
        return try await postgrest
            .from("photos")
            .insert(NewPhotoRecord(bodegaId: bodegaId, uploadedBy: uploadedBy, storagePath: path))
            .select()
            .single()
            .execute()
            .value
    }

    func publicURL(for photo: Photo) throws -> URL {
        try storage.from(Self.bucket).getPublicURL(path: photo.storagePath)
    }

    /// Deletes the DB row before the Storage object: if the Storage removal
    /// fails afterward, the worst case is an orphaned-but-harmless object
    /// left in the bucket. Doing it in the other order risks the opposite —
    /// a live DB row pointing at an already-deleted file.
    func delete(id: UUID, storagePath: String) async throws {
        try await postgrest
            .from("photos")
            .delete()
            .eq("id", value: id)
            .execute()
        _ = try await storage.from(Self.bucket).remove(paths: [storagePath])
    }
}
