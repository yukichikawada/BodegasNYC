import Foundation
import PostgREST
import Storage

/// Payload for the `photos` row created after a successful Storage upload.
/// `storagePath` must match the path actually used for the upload. `id` is
/// the client's stable id for the photo (#107 eng A1): the same id names the
/// Storage object, so a retry after a lost response finds both again instead
/// of making a second object and row. `caption` is left out of the JSON when
/// `nil` (synthesized `encodeIfPresent`), so the column stays NULL.
nonisolated struct NewPhotoRecord: Encodable, Sendable {
    var id: UUID
    var bodegaId: UUID
    var uploadedBy: UUID
    var storagePath: String
    var caption: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case bodegaId = "bodega_id"
        case uploadedBy = "uploaded_by"
        case storagePath = "storage_path"
        case caption
    }
}

/// Storage upload + `public.photos` CRUD, matching `photos_select` /
/// `photos_insert` / `photos_delete` RLS (no update policy — nothing
/// mutable besides `is_hidden`, which only the flags auto-hide trigger
/// touches).
///
/// Bucket named `"photos"` — no bucket-naming convention existed before
/// this slice. `storage_path` (the DB column) is the full bucket-relative
/// path, namespaced as `"<bodegaId>/<photoId>.jpg"` on upload.
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

    /// The Storage path for a photo: `<bodegaId>/<id>.jpg`.
    static func storagePath(id: UUID, bodegaId: UUID) -> String {
        "\(bodegaId.uuidString)/\(id.uuidString).jpg"
    }

    /// Uploads one prepared JPEG under the caller's stable `id` (#107 eng
    /// A1), then inserts its row with that same id. Safe to repeat: a
    /// Storage "already exists" means an earlier attempt's object landed, so
    /// it carries on to the insert; a Postgres unique violation (`23505`) on
    /// the insert means the earlier attempt's row landed too, so it fetches
    /// that row by id and returns it. Either way there is one object and one
    /// row per `id`.
    ///
    /// `caption` is sent as given; callers trim it and pass `nil` for empty
    /// (`AddPhotoViewModel.normalizedCaption(_:)`).
    @discardableResult
    func upload(id: UUID, bodegaId: UUID, uploadedBy: UUID, data: Data, caption: String?) async throws -> Photo {
        let path = Self.storagePath(id: id, bodegaId: bodegaId)
        do {
            _ = try await storage.from(Self.bucket).upload(
                path,
                data: data,
                options: FileOptions(contentType: "image/jpeg")
            )
        } catch where Self.isAlreadyExists(error) {
            // An earlier attempt uploaded it. Objects are immutable and the
            // path is this item's own id, so the bytes are the same.
        }
        let record = NewPhotoRecord(
            id: id, bodegaId: bodegaId, uploadedBy: uploadedBy, storagePath: path, caption: caption
        )
        do {
            return try await postgrest
                .from("photos")
                .insert(record)
                .select()
                .single()
                .execute()
                .value
        } catch where Self.isUniqueViolation(error) {
            return try await postgrest
                .from("photos")
                .select()
                .eq("id", value: id)
                .single()
                .execute()
                .value
        }
    }

    /// Storage answers a second upload to the same path with
    /// `{"statusCode": "409", "error": "Duplicate", "message": "The resource
    /// already exists"}` (over HTTP 400 or 409, depending on the server).
    static func isAlreadyExists(_ error: any Error) -> Bool {
        if let error = error as? StorageError {
            return error.statusCode == "409"
                || error.error == "Duplicate"
                || error.message.localizedCaseInsensitiveContains("already exists")
        }
        if let error = error as? HTTPError {
            return error.response.statusCode == 409
        }
        return false
    }

    /// Postgres `unique_violation`, which PostgREST passes through as `code`.
    static func isUniqueViolation(_ error: any Error) -> Bool {
        (error as? PostgrestError)?.code == "23505"
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
