//
//  BodegaServiceTests.swift
//  BodegasNYCTests
//
//  Verifies BodegaService's request shape against the actual RLS/schema
//  constraints, not just that decoding works: insert must send EWKT
//  `location`, never the generated `latitude`/`longitude` columns; update
//  must omit unset fields rather than nulling them.
//

import Foundation
import PostgREST
import Testing

@testable import BodegasNYC

extension NetworkingTests {

@Suite
struct BodegaServiceTests {
    private static let bodegaJSON = """
    {
      "id": "8f14e45f-ceea-467e-adc9-15476f4eaa15",
      "created_by": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
      "name": "El Sol Deli & Grocery",
      "latitude": 40.7291,
      "longitude": -73.9965,
      "address": "123 E 7th St, New York, NY",
      "has_cat": true,
      "serves_hot_food": true,
      "sells_cigarettes": true,
      "sells_beer": true,
      "sells_lotto": false,
      "hours": null,
      "is_hidden": false,
      "created_at": "2026-07-21T18:30:00.123456+00:00",
      "updated_at": "2026-07-22T00:15:59.000042+00:00"
    }
    """

    @Test func fetchAllOrdersByCreatedAtDescending() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON)]".utf8)) { request in
            capturedRequest.set(request)
        }
        let service = BodegaService(postgrest: makeTestPostgrestClient())

        let bodegas = try await service.fetchAll()

        #expect(bodegas.first?.name == "El Sol Deli & Grocery")
        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/rest/v1/bodegas")
        let query = try #require(request.url?.query)
        #expect(query.contains("order=created_at.desc"))
    }

    @Test func fetchNearbyCallsRPCWithNamedParams() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data("[\(Self.bodegaJSON)]".utf8)) { request in
            capturedRequest.set(request)
        }
        let service = BodegaService(postgrest: makeTestPostgrestClient())

        let bodegas = try await service.fetchNearby(latitude: 40.7291, longitude: -73.9965, radiusMeters: 500)

        #expect(bodegas.count == 1)
        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/rpc/nearby_bodegas")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["lat"] as? Double == 40.7291)
        #expect(json["long"] as? Double == -73.9965)
        #expect(json["radius_meters"] as? Double == 500)
    }

    @Test func insertEncodesLocationAsEWKTNotGeneratedColumns() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let service = BodegaService(postgrest: makeTestPostgrestClient())
        let draft = NewBodega(
            createdBy: UUID(uuidString: "3FA85F64-5717-4562-B3FC-2C963F66AFA6")!,
            name: "El Sol Deli & Grocery",
            coordinate: Coordinate(latitude: 40.7291, longitude: -73.9965),
            address: "123 E 7th St, New York, NY",
            hasCat: true,
            servesHotFood: true,
            sellsCigarettes: true,
            sellsBeer: true,
            sellsLotto: false
        )

        let inserted = try await service.insert(draft)

        #expect(inserted.name == "El Sol Deli & Grocery")
        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/bodegas")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["location"] as? String == "SRID=4326;POINT(-73.9965 40.7291)")
        #expect(json["latitude"] == nil)
        #expect(json["longitude"] == nil)
    }

    @Test func updateSendsOnlyProvidedFields() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.bodegaJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let service = BodegaService(postgrest: makeTestPostgrestClient())
        let id = UUID(uuidString: "8F14E45F-CEEA-467E-ADC9-15476F4EAA15")!

        _ = try await service.update(id: id, BodegaUpdate(hasCat: false))

        let request = try #require(capturedRequest.get())
        #expect(request.httpMethod == "PATCH")
        let query = try #require(request.url?.query)
        #expect(query.contains("id=eq.\(id.uuidString)"))
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json.count == 1)
        #expect(json["has_cat"] as? Bool == false)
    }

    @Test func updateEncodesExplicitNullsOnlyForFieldsToClear() throws {
        let cleared = BodegaUpdate(name: "El Sol", fieldsToClear: [.address, .hours])
        let clearedJSON = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(cleared)) as? [String: Any]
        )
        #expect(Set(clearedJSON.keys) == ["name", "address", "hours"])
        #expect(clearedJSON["address"] is NSNull)
        #expect(clearedJSON["hours"] is NSNull)

        // A value set on the same field wins over clearing it.
        let both = BodegaUpdate(address: "1 Main St", fieldsToClear: [.address])
        let bothJSON = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(both)) as? [String: Any]
        )
        #expect(bothJSON["address"] as? String == "1 Main St")
    }
}

}
