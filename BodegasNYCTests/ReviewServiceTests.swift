//
//  ReviewServiceTests.swift
//  BodegasNYCTests
//

import Foundation
import Testing

@testable import BodegasNYC

extension NetworkingTests {

@Suite
struct ReviewServiceTests {
    private static let bodegaID = "8f14e45f-ceea-467e-adc9-15476f4eaa15"
    private static let reviewJSON = """
    {
      "id": "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
      "bodega_id": "\(bodegaID)",
      "author_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
      "rating": 5,
      "body": "Rocco the bodega cat says hi",
      "is_hidden": false,
      "created_at": "2026-07-21T18:30:00+00:00",
      "updated_at": "2026-07-21T18:30:00+00:00"
    }
    """

    @Test func fetchAllFiltersByBodegaID() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data("[\(Self.reviewJSON)]".utf8)) { request in
            capturedRequest.set(request)
        }
        let service = ReviewService(postgrest: makeTestPostgrestClient())

        let reviews = try await service.fetchAll(bodegaId: UUID(uuidString: Self.bodegaID)!)

        #expect(reviews.first?.rating == 5)
        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "GET")
        let query = try #require(request.url?.query)
        #expect(query.contains("bodega_id=eq.\(Self.bodegaID.uppercased())"))
    }

    @Test func insertSendsBodegaAndAuthorIDs() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.reviewJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let service = ReviewService(postgrest: makeTestPostgrestClient())
        let draft = NewReview(
            bodegaId: UUID(uuidString: Self.bodegaID)!,
            authorId: UUID(uuidString: "3fa85f64-5717-4562-b3fc-2c963f66afa6")!,
            rating: 5,
            body: "Rocco the bodega cat says hi"
        )

        let inserted = try await service.insert(draft)

        #expect(inserted.rating == 5)
        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["bodega_id"] as? String == Self.bodegaID.uppercased())
        #expect(json["rating"] as? Int == 5)
    }

    @Test func updateSendsOnlyProvidedFields() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.reviewJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let service = ReviewService(postgrest: makeTestPostgrestClient())

        _ = try await service.update(
            id: UUID(uuidString: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed")!,
            ReviewUpdate(body: "Updated review text")
        )

        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "PATCH")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json.count == 1)
        #expect(json["body"] as? String == "Updated review text")
    }

    @Test func deleteSendsDeleteRequestScopedByID() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data()) { request in
            capturedRequest.set(request)
        }
        let service = ReviewService(postgrest: makeTestPostgrestClient())
        let id = UUID(uuidString: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed")!

        try await service.delete(id: id)

        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "DELETE")
        let query = try #require(request.url?.query)
        #expect(query.contains("id=eq.\(id.uuidString)"))
    }
}

}
