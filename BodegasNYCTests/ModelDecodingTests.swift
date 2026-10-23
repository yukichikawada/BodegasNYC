//
//  ModelDecodingTests.swift
//  BodegasNYCTests
//
//  Verifies the model layer's Codable mapping against JSON shaped like a
//  real PostgREST response, before any networking code exists to depend on
//  it — see PostgRESTDecoding.swift for why this needs a custom date
//  strategy rather than JSONDecoder's built-in `.iso8601`.
//

import Testing
import Foundation
@testable import BodegasNYC

struct ModelDecodingTests {

    @Test func decodesBodegaWithFractionalSecondTimestamps() throws {
        let json = """
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
          "hours": {
            "mon": { "open": "06:00", "close": "23:00", "isClosed": false },
            "sun": { "open": "00:00", "close": "00:00", "isClosed": true }
          },
          "is_hidden": false,
          "created_at": "2026-07-21T18:30:00.123456+00:00",
          "updated_at": "2026-07-22T00:15:59.000042+00:00"
        }
        """
        let bodega = try PostgRESTDecoding.makeDecoder().decode(Bodega.self, from: Data(json.utf8))

        #expect(bodega.name == "El Sol Deli & Grocery")
        #expect(bodega.coordinate.latitude == 40.7291)
        #expect(bodega.coordinate.longitude == -73.9965)
        #expect(bodega.hasCat == true)
        #expect(bodega.sellsLotto == false)
        #expect(bodega.hours?.mon?.open == "06:00")
        #expect(bodega.hours?.sun?.isClosed == true)
        #expect(bodega.hours?.tue == nil)
    }

    @Test func decodesReviewWithWholeSecondTimestamps() throws {
        let json = """
        {
          "id": "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
          "bodega_id": "8f14e45f-ceea-467e-adc9-15476f4eaa15",
          "author_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
          "rating": 5,
          "body": "Rocco the bodega cat says hi",
          "is_hidden": false,
          "created_at": "2026-07-21T18:30:00+00:00",
          "updated_at": "2026-07-21T18:30:00+00:00"
        }
        """
        let review = try PostgRESTDecoding.makeDecoder().decode(Review.self, from: Data(json.utf8))

        #expect(review.rating == 5)
        #expect(review.body == "Rocco the bodega cat says hi")
        #expect(review.isHidden == false)
    }

    @Test func decodesPhoto() throws {
        let json = """
        {
          "id": "c56a4180-65aa-42ec-a945-5fd21dec0538",
          "bodega_id": "8f14e45f-ceea-467e-adc9-15476f4eaa15",
          "uploaded_by": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
          "storage_path": "bodega-photos/8f14e45f/front-door.jpg",
          "is_hidden": false,
          "created_at": "2026-07-21T18:31:12.500000+00:00"
        }
        """
        let photo = try PostgRESTDecoding.makeDecoder().decode(Photo.self, from: Data(json.utf8))

        #expect(photo.storagePath == "bodega-photos/8f14e45f/front-door.jpg")
        #expect(photo.caption == nil)
    }

    /// protects: a row's caption decodes, and an explicit null decodes as nil (#107).
    /// fails_when: the caption key is wrong, or null throws.
    /// no_claim: that a build without PR 2 ignores the column (AC 10: Decodable ignores unknown keys; not re-run here).
    @Test func decodesPhotoCaptionAndNullCaption() throws {
        func row(_ caption: String) -> Data {
            Data("""
            {
              "id": "c56a4180-65aa-42ec-a945-5fd21dec0538",
              "bodega_id": "8f14e45f-ceea-467e-adc9-15476f4eaa15",
              "uploaded_by": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
              "storage_path": "8f14e45f/front-door.jpg",
              "is_hidden": false,
              "caption": \(caption),
              "created_at": "2026-07-21T18:31:12.500000+00:00"
            }
            """.utf8)
        }
        let decoder = PostgRESTDecoding.makeDecoder()

        #expect(try decoder.decode(Photo.self, from: row(#""The cat runs the counter.""#)).caption == "The cat runs the counter.")
        #expect(try decoder.decode(Photo.self, from: row("null")).caption == nil)
    }

    @Test func decodesFlagAndResolvesTarget() throws {
        let json = """
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
        let flag = try PostgRESTDecoding.makeDecoder().decode(Flag.self, from: Data(json.utf8))

        guard case .bodega(let id) = flag.target else {
            Issue.record("Expected .bodega target")
            return
        }
        #expect(id == flag.bodegaId)
    }
}
