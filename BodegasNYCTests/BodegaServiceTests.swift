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
      "has_atm": false,
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

    /// A JSON array of `count` bodegas named "Bodega <n>" from `start`, so a
    /// test can check rows across pages arrive in order.
    private static func pageJSON(start: Int, count: Int) -> Data {
        let rows = (start..<(start + count)).map { index in
            Self.bodegaJSON
                .replacingOccurrences(of: "8f14e45f-ceea-467e-adc9-15476f4eaa15",
                                      with: String(format: "00000000-0000-4000-8000-%012d", index))
                .replacingOccurrences(of: "El Sol Deli & Grocery", with: "Bodega \(index)")
        }
        return Data("[\(rows.joined(separator: ","))]".utf8)
    }

    /// Stubs one response per page and returns the requests in the order made.
    private static func stubPages(_ counts: [Int]) -> Captured<[URLRequest]> {
        let requests = Captured<[URLRequest]>([])
        var start = 0
        for count in counts {
            MockURLProtocol.stub(body: pageJSON(start: start, count: count)) { request in
                requests.set(requests.get() + [request])
            }
            start += count
        }
        return requests
    }

    private static func queryItems(of request: URLRequest) -> [String: String] {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    @Test func fetchAllPagesPastTheRowCap() async throws {
        MockURLProtocol.reset()
        let requests = Self.stubPages([1000, 1])
        let service = BodegaService(postgrest: makeTestPostgrestClient())

        let bodegas = try await service.fetchAll()

        #expect(bodegas.count == 1001)
        #expect(bodegas.map(\.name) == (0..<1001).map { "Bodega \($0)" })
        let made = requests.get()
        try #require(made.count == 2)
        let first = Self.queryItems(of: made[0])
        let second = Self.queryItems(of: made[1])
        #expect(first["offset"] == "0")
        #expect(first["limit"] == "1000")
        #expect(second["offset"] == "1000")
        #expect(second["limit"] == "1000")
        #expect(first["order"] == "created_at.desc.nullslast,id.desc.nullslast")
        #expect(second["order"] == first["order"])
    }

    @Test func fetchAllStopsOnAnEmptyPageAfterAnExactMultiple() async throws {
        MockURLProtocol.reset()
        let requests = Self.stubPages([1000, 0])
        let service = BodegaService(postgrest: makeTestPostgrestClient())

        let bodegas = try await service.fetchAll()

        #expect(bodegas.count == 1000)
        let made = requests.get()
        try #require(made.count == 2)
        #expect(Self.queryItems(of: made[1])["offset"] == "1000")
    }

    @Test func fetchAllDropsARowRepeatedByAnInsertBetweenPages() async throws {
        MockURLProtocol.reset()
        // An insert between requests shifts the offset, so page 2 starts
        // with page 1's last row ("Bodega 999") again.
        MockURLProtocol.stub(body: Self.pageJSON(start: 0, count: 1000))
        let secondRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Self.pageJSON(start: 999, count: 2)) { request in
            secondRequest.set(request)
        }
        let service = BodegaService(postgrest: makeTestPostgrestClient())

        let bodegas = try await service.fetchAll()

        #expect(bodegas.map(\.name) == (0..<1001).map { "Bodega \($0)" })
        #expect(Set(bodegas.map(\.id)).count == 1001)
        let request = try #require(secondRequest.get())
        #expect(Self.queryItems(of: request)["offset"] == "1000")
    }

    @Test func fetchAllThrowsWhenALaterPageFails() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Self.pageJSON(start: 0, count: 1000))
        MockURLProtocol.stub(statusCode: 500, body: Data("{\"message\":\"boom\"}".utf8))
        let service = BodegaService(postgrest: makeTestPostgrestClient())

        await #expect(throws: (any Error).self) {
            _ = try await service.fetchAll()
        }
    }

    @Test func fetchAllMakesOneRequestForAShortFirstPage() async throws {
        MockURLProtocol.reset()
        let requests = Self.stubPages([3])
        let service = BodegaService(postgrest: makeTestPostgrestClient())

        let bodegas = try await service.fetchAll()

        #expect(bodegas.map(\.name) == ["Bodega 0", "Bodega 1", "Bodega 2"])
        #expect(requests.get().count == 1)
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
