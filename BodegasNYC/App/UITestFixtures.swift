#if DEBUG
import Auth
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

    // MARK: Upload sheet (#107 eng O4)

    /// With `-UITestFixtures`, opens the Add Photos sheet on the fixture
    /// bodega's detail with `addPhotoItemIDs.count` fixture photos.
    static let addPhotosLaunchArgument = "-UITestAddPhotos"

    static var opensAddPhotos: Bool {
        isEnabled && CommandLine.arguments.contains(addPhotosLaunchArgument)
    }

    /// Fixed so `FixtureURLProtocol` can tell the photos apart: the second
    /// one's first insert fails.
    static let addPhotoItemIDs: [UUID] = (1...3).map { number in
        UUID(uuidString: "5B1D0C3A-0000-4000-8000-00000000000\(number)")!
    }

    static var failingAddPhotoID: UUID { addPhotoItemIDs[1] }

    /// One generated JPEG per item, standing in for the picker's bytes.
    static func addPhotoSources() -> [AddPhotoViewModel.PhotoSource] {
        (1...addPhotoItemIDs.count).map { number in
            { FixtureURLProtocol.photoJPEG(for: "pick-\(number)") }
        }
    }

    /// A session store already signed in as the fixture user, from an
    /// in-memory auth store, so Upload does not stop at the sign-in sheet.
    @MainActor
    static func makeSignedInSessionStore() -> SessionStore {
        let storage = FixtureAuthStorage()
        let session = Session(
            accessToken: "fixture-access-token",
            tokenType: "bearer",
            expiresIn: 86_400,
            expiresAt: Date().addingTimeInterval(86_400).timeIntervalSince1970,
            refreshToken: "fixture-refresh-token",
            user: User(
                id: FixtureURLProtocol.fixtureUserID,
                appMetadata: [:],
                userMetadata: [:],
                aud: "authenticated",
                createdAt: Date(),
                updatedAt: Date()
            )
        )
        // The live store's encoding (a plain JSONEncoder) under the SDK's
        // default key, as `makeTestAuthClient` does in the unit tests.
        try? storage.store(key: "supabase.auth.token", value: JSONEncoder().encode(session))
        let authSession = urlSession()
        let auth = AuthClient(
            configuration: AuthClient.Configuration(
                url: URL(string: "https://fixture.supabase.co/auth/v1")!,
                headers: ["apikey": "fixture-anon-key"],
                localStorage: storage,
                logger: nil,
                fetch: { try await authSession.data(for: $0) }
            )
        )
        return SessionStore(auth: auth)
    }
}

/// In-memory `AuthLocalStorage` for the fixture session; never the Keychain.
nonisolated private final class FixtureAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func store(key: String, value: Data) throws { lock.withLock { storage[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { storage[key] } }
    func remove(key: String) throws { lock.withLock { storage[key] = nil } }
}

/// Answers every request locally: `bodegas` GETs and the
/// `nearby_bodegas` RPC return the fixture row, `photos` GETs the three
/// fixture photo rows, public photo objects a small JPEG, any other GET an
/// empty JSON array. Writes: a Storage photo upload succeeds once per path
/// and answers a repeat with Storage's "already exists"; a `photos` insert
/// echoes the row back, except the first insert of
/// `UITestFixtures.failingAddPhotoID`, which fails (#107 eng O4). Any other
/// write fails with a 501.
nonisolated final class FixtureURLProtocol: URLProtocol {
    static let bodegaID = "6E1C7A52-4B0B-4C8F-9C61-0F2E8E5A1B01"
    static let photoCount = 3
    static let failingPhotoRequests = RequestBudget(failures: UITestFixtures.photoFailureCount)
    static let fixtureUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// The first fixture photo's caption (eng T1: one captioned row).
    static let captionedPhotoCaption = "The cat runs the counter."

    /// Newest first, as `PhotoService.fetchAll` orders them; the first has
    /// a caption, the others have none (one with the key null, one without
    /// it).
    static let photosJSON: String = {
        let rows = (1...photoCount).map { number in
            let caption = switch number {
            case 1: "\n  \"caption\": \"\(captionedPhotoCaption)\","
            case 2: "\n  \"caption\": null,"
            default: ""
            }
            return """
            {\(caption)
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

    /// Upload state across requests (URLSession makes a new protocol
    /// instance per request).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var uploadedPaths: Set<String> = []
    nonisolated(unsafe) private static var failedInsertIDs: Set<String> = []

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
        } else if method == "POST" && path.contains("/storage/v1/object/photos/") {
            let objectPath = String(path[path.range(of: "/storage/v1/object/photos/")!.upperBound...])
            let isRepeat = Self.lock.withLock { !Self.uploadedPaths.insert(objectPath).inserted }
            if isRepeat {
                statusCode = 400
                body = Data(#"{"statusCode":"409","error":"Duplicate","message":"The resource already exists"}"#.utf8)
            } else {
                body = Data(#"{"Key":"photos/\#(objectPath)","Id":"\#(UUID().uuidString)"}"#.utf8)
            }
        } else if method == "POST" && path.hasSuffix("/rest/v1/photos") {
            let inserted = Self.insertPhoto(Self.requestBody(of: request))
            statusCode = inserted.status
            body = inserted.body
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

    /// Echoes the inserted row back as PostgREST would for
    /// `insert(...).select().single()`, or fails the first insert of the
    /// fixture's failing photo with a 500.
    private static func insertPhoto(_ body: Data) -> (status: Int, body: Data) {
        guard var row = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let id = row["id"] as? String else {
            return (400, Data(#"{"code":"PGRST102","message":"UITestFixtures: unreadable insert"}"#.utf8))
        }
        let failsNow = Self.lock.withLock {
            id.uppercased() == UITestFixtures.failingAddPhotoID.uuidString && Self.failedInsertIDs.insert(id).inserted
        }
        if failsNow {
            return (500, Data(#"{"code":"XX000","message":"UITestFixtures: injected failure"}"#.utf8))
        }
        row["is_hidden"] = false
        row["created_at"] = ISO8601DateFormatter().string(from: Date())
        let data = (try? JSONSerialization.data(withJSONObject: row)) ?? Data("{}".utf8)
        return (201, data)
    }

    /// `URLSession` usually hands a custom protocol the body as a stream.
    private static func requestBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
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
