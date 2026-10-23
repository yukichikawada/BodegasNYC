//
//  PhotoServiceTests.swift
//  BodegasNYCTests
//
//  Verifies PhotoService's two-step upload (Storage object, then the
//  matching `photos` row) happens in the right order with matching paths,
//  and that delete removes the DB row before the Storage object — the
//  opposite order risks a live row pointing at an already-deleted file.
//

import Foundation
import Testing

@testable import BodegasNYC

extension NetworkingTests {

@Suite
struct PhotoServiceTests {
    private static let bodegaID = UUID(uuidString: "8f14e45f-ceea-467e-adc9-15476f4eaa15")!
    private static let uploaderID = UUID(uuidString: "3fa85f64-5717-4562-b3fc-2c963f66afa6")!

    private static let photoID = UUID(uuidString: "c56a4180-65aa-42ec-a945-5fd21dec0538")!
    private static let storageJSON = #"{"Key": "photos/placeholder.jpg", "Id": "some-object-id"}"#

    private static var expectedPath: String { "\(bodegaID.uuidString)/\(photoID.uuidString).jpg" }

    private static func photoRowJSON(caption: String?) -> String {
        """
        {
          "id": "\(photoID.uuidString)",
          "bodega_id": "\(bodegaID.uuidString)",
          "uploaded_by": "\(uploaderID.uuidString)",
          "storage_path": "\(expectedPath)",
          "is_hidden": false,
          "caption": \(caption.map { "\"\($0)\"" } ?? "null"),
          "created_at": "2026-07-21T18:31:12.500000+00:00"
        }
        """
    }

    private static func recorder() -> (Captured<[URLRequest]>, @Sendable (URLRequest) -> Void) {
        let captured = Captured<[URLRequest]>([])
        return (captured, { request in captured.set(captured.get() + [request]) })
    }

    private static func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func upload(caption: String?) async throws -> Photo {
        let service = PhotoService(postgrest: makeTestPostgrestClient(), storage: makeTestStorageClient())
        return try await service.upload(
            id: Self.photoID,
            bodegaId: Self.bodegaID,
            uploadedBy: Self.uploaderID,
            data: Data("fake-image-bytes".utf8),
            caption: caption
        )
    }

    /// protects: upload stores `<bodega>/<id>.jpg`, then inserts the row with that id, path and caption (eng A1).
    /// fails_when: the object name isn't the given id, the row has no id or another path, or the caption is dropped.
    /// no_claim: RLS and the check constraint (local Supabase QA).
    @Test func uploadStoresFileThenInsertsMatchingRow() async throws {
        MockURLProtocol.reset()
        let (captured, record) = Self.recorder()
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8), onRequest: record)
        MockURLProtocol.stub(body: Data(Self.photoRowJSON(caption: "Front door").utf8), onRequest: record)

        let photo = try await upload(caption: "Front door")

        #expect(photo.id == Self.photoID)
        #expect(photo.caption == "Front door")
        let requests = captured.get()
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/storage/v1/object/photos/\(Self.expectedPath)")
        #expect(requests[1].url?.path == "/rest/v1/photos")
        let json = try Self.json(requests[1])
        #expect(json["id"] as? String == Self.photoID.uuidString)
        #expect(json["bodega_id"] as? String == Self.bodegaID.uuidString)
        #expect(json["uploaded_by"] as? String == Self.uploaderID.uuidString)
        #expect(json["storage_path"] as? String == Self.expectedPath)
        #expect(json["caption"] as? String == "Front door")
    }

    /// protects: a nil caption is left out of the insert, so the column stays NULL (spec: encoded only when non-nil).
    /// fails_when: the body carries `"caption": null` or `""`.
    /// no_claim: what PostgREST does with an explicit null (same result; not asserted).
    @Test func newPhotoRecordOmitsANilCaption() throws {
        let record = NewPhotoRecord(
            id: Self.photoID, bodegaId: Self.bodegaID, uploadedBy: Self.uploaderID, storagePath: "a/b.jpg", caption: nil
        )
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )

        #expect(Set(json.keys) == ["id", "bodega_id", "uploaded_by", "storage_path"])
    }

    /// protects: a retry whose first attempt's object landed treats Storage's "already exists" as uploaded and
    /// goes on to the insert (eng A1).
    /// fails_when: the duplicate error fails the upload, or a second object path is tried.
    /// no_claim: the exact status the hosted Storage returns (400 vs 409 both handled; local Supabase QA).
    @Test func storageAlreadyExistsCountsAsUploaded() async throws {
        MockURLProtocol.reset()
        let (captured, record) = Self.recorder()
        MockURLProtocol.stub(
            statusCode: 400,
            body: Data(#"{"statusCode":"409","error":"Duplicate","message":"The resource already exists"}"#.utf8),
            onRequest: record
        )
        MockURLProtocol.stub(body: Data(Self.photoRowJSON(caption: nil).utf8), onRequest: record)

        let photo = try await upload(caption: nil)

        #expect(photo.id == Self.photoID)
        let requests = captured.get()
        #expect(requests.count == 2)
        #expect(requests[1].httpMethod == "POST")
        #expect(requests[1].url?.path == "/rest/v1/photos")
    }

    /// protects: an insert that hits a unique violation (the first attempt's row landed) fetches that row by id and
    /// returns it, so a retry never makes a duplicate (eng A1, AC 8).
    /// fails_when: 23505 fails the upload, or the fetch isn't by the item's id.
    /// no_claim: RLS letting the uploader read their own row (photos_select; local Supabase QA).
    @Test func uniqueViolationOnInsertFetchesTheExistingRowByID() async throws {
        MockURLProtocol.reset()
        let (captured, record) = Self.recorder()
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8), onRequest: record)
        MockURLProtocol.stub(
            statusCode: 409,
            body: Data(#"{"code":"23505","details":null,"hint":null,"message":"duplicate key value violates unique constraint \"photos_pkey\""}"#.utf8),
            onRequest: record
        )
        MockURLProtocol.stub(body: Data(Self.photoRowJSON(caption: "Front door").utf8), onRequest: record)

        let photo = try await upload(caption: "Front door")

        #expect(photo.id == Self.photoID)
        let requests = captured.get()
        #expect(requests.count == 3)
        #expect(requests[2].httpMethod == "GET")
        #expect(requests[2].url?.path == "/rest/v1/photos")
        let query = requests[2].url?.query?.removingPercentEncoding ?? ""
        #expect(query.contains("id=eq.\(Self.photoID.uuidString)") || query.contains("id=eq.\(Self.photoID.uuidString.lowercased())"))
    }

    /// protects: any other insert error still fails the upload (only 23505 means "already there").
    /// fails_when: an arbitrary PostgREST error is swallowed as success.
    /// no_claim: none beyond that.
    @Test func otherInsertErrorsStillFail() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8))
        MockURLProtocol.stub(statusCode: 400, body: Data(#"{"code":"23514","message":"check violation"}"#.utf8))

        await #expect(throws: (any Error).self) {
            _ = try await upload(caption: String(repeating: "x", count: 141))
        }
    }

    @Test func publicURLPointsAtPhotosBucket() throws {
        let service = PhotoService(postgrest: makeTestPostgrestClient(), storage: makeTestStorageClient())
        let photo = Photo(
            id: UUID(),
            bodegaId: Self.bodegaID,
            uploadedBy: Self.uploaderID,
            storagePath: "abc/front-door.jpg",
            isHidden: false,
            createdAt: Date()
        )

        let url = try service.publicURL(for: photo)

        #expect(url.path.contains("/storage/v1/object/public/photos/abc/front-door.jpg"))
    }

    @Test func deleteRemovesDBRowBeforeStorageObject() async throws {
        MockURLProtocol.reset()
        let capturedRequests = Captured<[URLRequest]>([])
        let record: @Sendable (URLRequest) -> Void = { request in
            capturedRequests.set(capturedRequests.get() + [request])
        }
        MockURLProtocol.stub(body: Data(), onRequest: record)
        MockURLProtocol.stub(body: Data("[]".utf8), onRequest: record)

        let service = PhotoService(postgrest: makeTestPostgrestClient(), storage: makeTestStorageClient())
        try await service.delete(id: UUID(), storagePath: "abc/front-door.jpg")

        let requests = capturedRequests.get()
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/rest/v1/photos")
        #expect(requests[0].httpMethod == "DELETE")
        #expect(requests[1].url?.path.contains("/storage/v1/object/photos") == true)
    }
}

}
