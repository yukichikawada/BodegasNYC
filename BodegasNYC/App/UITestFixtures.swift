#if DEBUG
import CoreGraphics
import Foundation
import ImageIO

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

    /// Called at launch (#107 eng T1): registers `FixtureURLProtocol` for
    /// `URLSession.shared` too, which `AsyncImage` and the photo viewer use,
    /// so photo bytes come from the fixture and not the network.
    /// `-UITestPhotoFailures N`: the first N requests for the last fixture
    /// photo's image answer 404, later ones succeed (#107 design D17). The
    /// gallery thumbnail makes the first request, so N = 2 fails the
    /// viewer's first load of that page and lets its Retry succeed.
    static let photoFailuresArgument = "-UITestPhotoFailures"

    static var photoFailureCount: Int {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: photoFailuresArgument), flag + 1 < arguments.count else {
            return 0
        }
        return Int(arguments[flag + 1]) ?? 0
    }

    static func registerForSharedSession() {
        guard isEnabled else { return }
        URLProtocol.registerClass(FixtureURLProtocol.self)
    }
}

/// Answers every request locally: `bodegas` GETs and the
/// `nearby_bodegas` RPC return the fixture row, `photos` GETs the three
/// fixture photo rows, public photo objects a small JPEG, any other GET an
/// empty JSON array, and any other write fails with a 501.
nonisolated final class FixtureURLProtocol: URLProtocol {
    static let bodegaID = "6E1C7A52-4B0B-4C8F-9C61-0F2E8E5A1B01"
    static let photoCount = 3
    static let failingPhotoRequests = RequestBudget(failures: UITestFixtures.photoFailureCount)

    /// Newest first, as `PhotoService.fetchAll` orders them; no `caption`
    /// column yet (PR 2).
    static let photosJSON: String = {
        let rows = (1...photoCount).map { number in
            """
            {
              "id": "7A0F3C2E-0000-4000-8000-00000000000\(number)",
              "bodega_id": "\(bodegaID)",
              "uploaded_by": "00000000-0000-0000-0000-000000000001",
              "storage_path": "\(bodegaID)/fixture-\(number).jpg",
              "is_hidden": false,
              "created_at": "2026-10-0\(4 - number)T12:00:00+00:00"
            }
            """
        }
        return "[" + rows.joined(separator: ",") + "]"
    }()

    /// Generated rather than shipped as a resource, so Release carries no
    /// fixture bytes: a 640x480 JPEG, a different grey per photo so pages
    /// are told apart in recordings.
    static func photoJPEG(for path: String) -> Data {
        let number = path.last(where: \.isNumber).flatMap { Int(String($0)) } ?? 1
        let grey = CGFloat(number) / CGFloat(photoCount + 1)
        let width = 640
        let height = 480
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return Data() }
        context.setFillColor(CGColor(red: grey, green: grey, blue: grey, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }

    static let bodegaJSON = """
    [{
      "id": "\(bodegaID)",
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
        let method = request.httpMethod ?? "GET"
        let body: Data
        var statusCode = 200
        var contentType = "application/json"
        if (method == "GET" && path.hasSuffix("/rest/v1/bodegas")) || path.hasSuffix("/rpc/nearby_bodegas") {
            body = Data(Self.bodegaJSON.utf8)
        } else if method == "GET" && path.hasSuffix("/rest/v1/photos") {
            body = Data(Self.photosJSON.utf8)
        } else if method == "GET" && path.contains("/storage/v1/object/public/photos/") {
            if path.hasSuffix("fixture-\(Self.photoCount).jpg"), Self.failingPhotoRequests.nextFails() {
                statusCode = 404
                contentType = "text/plain"
                body = Data("UITestFixtures: forced 404".utf8)
            } else {
                body = Self.photoJPEG(for: path)
                contentType = "image/jpeg"
            }
        } else if method == "GET" {
            body = Data("[]".utf8)
        } else {
            // Unknown writes fail loudly, so a write test can't pass on a silent `[]`.
            statusCode = 501
            contentType = "text/plain"
            body = Data("UITestFixtures: no fixture for \(method) \(path)".utf8)
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Counts requests across `URLProtocol` instances (which start on any
/// thread): the first `failures` calls to `nextFails()` return true.
nonisolated final class RequestBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(failures: Int) {
        remaining = failures
    }

    func nextFails() -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}
#endif
