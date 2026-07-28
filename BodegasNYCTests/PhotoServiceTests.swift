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

    @Test func uploadStoresFileThenInsertsMatchingRow() async throws {
        MockURLProtocol.reset()
        let capturedRequests = Captured<[URLRequest]>([])
        let record: @Sendable (URLRequest) -> Void = { request in
            capturedRequests.set(capturedRequests.get() + [request])
        }
        MockURLProtocol.stub(body: Data("""
        {"Key": "photos/placeholder.jpg", "Id": "some-object-id"}
        """.utf8), onRequest: record)
        MockURLProtocol.stub(body: Data("""
        {
          "id": "c56a4180-65aa-42ec-a945-5fd21dec0538",
          "bodega_id": "\(Self.bodegaID.uuidString)",
          "uploaded_by": "\(Self.uploaderID.uuidString)",
          "storage_path": "\(Self.bodegaID.uuidString)/front-door.jpg",
          "is_hidden": false,
          "created_at": "2026-07-21T18:31:12.500000+00:00"
        }
        """.utf8), onRequest: record)

        let service = PhotoService(postgrest: makeTestPostgrestClient(), storage: makeTestStorageClient())

        let photo = try await service.upload(
            bodegaId: Self.bodegaID,
            uploadedBy: Self.uploaderID,
            data: Data("fake-image-bytes".utf8),
            fileExtension: "jpg",
            contentType: "image/jpeg"
        )

        #expect(photo.storagePath == "\(Self.bodegaID.uuidString)/front-door.jpg")
        let requests = capturedRequests.get()
        #expect(requests.count == 2)
        #expect(requests[0].url?.path.contains("/storage/v1/object/photos") == true)
        #expect(requests[1].url?.path == "/rest/v1/photos")
        let body = try #require(requests[1].httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["bodega_id"] as? String == Self.bodegaID.uuidString)
        #expect(json["uploaded_by"] as? String == Self.uploaderID.uuidString)
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
