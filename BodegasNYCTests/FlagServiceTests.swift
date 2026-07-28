//
//  FlagServiceTests.swift
//  BodegasNYCTests
//
//  Verifies NewFlag encodes its FlagTarget into exactly one FK column,
//  mirroring the DB's exclusive-arc CHECK.
//

import Foundation
import Testing

@testable import BodegasNYC

extension NetworkingTests {

@Suite
struct FlagServiceTests {
    private static let flagJSON = """
    {
      "id": "e2c1a2f0-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
      "reporter_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
      "bodega_id": "8f14e45f-ceea-467e-adc9-15476f4eaa15",
      "review_id": null,
      "photo_id": null,
      "reason": "Closed permanently",
      "created_at": "2026-07-21T18:32:00.000000+00:00"
    }
    """

    @Test func fetchMineReturnsOwnFlags() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.flagJSON)]".utf8))
        let service = FlagService(postgrest: makeTestPostgrestClient())

        let flags = try await service.fetchMine()

        #expect(flags.count == 1)
        #expect(flags.first?.reason == "Closed permanently")
    }

    @Test func insertEncodesBodegaTargetIntoBodegaIDColumnOnly() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.flagJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let service = FlagService(postgrest: makeTestPostgrestClient())
        let draft = NewFlag(
            reporterId: UUID(uuidString: "3fa85f64-5717-4562-b3fc-2c963f66afa6")!,
            target: .bodega(UUID(uuidString: "8f14e45f-ceea-467e-adc9-15476f4eaa15")!),
            reason: "Closed permanently"
        )

        let flag = try await service.insert(draft)

        guard case .bodega = flag.target else {
            Issue.record("expected a bodega target")
            return
        }
        let request = try #require(capturedRequest.get())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["bodega_id"] as? String == "8F14E45F-CEEA-467E-ADC9-15476F4EAA15")
        #expect(json["review_id"] == nil)
        #expect(json["photo_id"] == nil)
    }
}

}
