#if DEBUG
import Foundation

/// DEBUG-only offline seam for `BodegasNYCUITests` (#101): launched with
/// `-UITestFixtures`, the app's Supabase clients talk to
/// `FixtureURLProtocol` instead of the network, so a UI test gets a known
/// bodega without the hosted database. Everything above the transport
/// (services, decoding, view models, the map) runs unchanged.
///
/// Absent from Release builds; without the argument nothing here is used.
nonisolated enum UITestFixtures {
    static let launchArgument = "-UITestFixtures"

    static var isEnabled: Bool {
        CommandLine.arguments.contains(launchArgument)
    }

    /// The one fixture bodega, at `MapScreenView.newYorkCityDefault`'s
    /// centre so it sits mid-screen on the default camera. Its name is what
    /// the UI test taps and then expects as the detail title.
    static let bodegaName = "Fixture Deli"

    static func urlSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Answers every request locally: `bodegas` selects and the
/// `nearby_bodegas` RPC return the fixture row, any other PostgREST or
/// Storage read returns an empty JSON array.
nonisolated final class FixtureURLProtocol: URLProtocol {
    static let bodegaJSON = """
    [{
      "id": "6E1C7A52-4B0B-4C8F-9C61-0F2E8E5A1B01",
      "created_by": "00000000-0000-0000-0000-000000000001",
      "name": "\(UITestFixtures.bodegaName)",
      "latitude": 40.7128,
      "longitude": -74.006,
      "address": "1 Fixture St",
      "has_cat": true,
      "serves_hot_food": true,
      "sells_cigarettes": false,
      "sells_beer": true,
      "sells_lotto": false,
      "hours": null,
      "is_hidden": false,
      "created_at": "2026-10-01T12:00:00+00:00",
      "updated_at": "2026-10-01T12:00:00+00:00"
    }]
    """

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: String
        if path.hasSuffix("/rest/v1/bodegas") || path.hasSuffix("/rpc/nearby_bodegas") {
            body = Self.bodegaJSON
        } else {
            body = "[]"
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
