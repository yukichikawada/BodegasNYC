import Foundation

/// A `URLProtocol` stub so networking-layer tests can verify request shape
/// (method/path/headers/body) and response decoding without a live
/// Supabase project. `URLSession` instantiates protocol instances
/// internally, so the stub queue and request log necessarily live in
/// process-wide static state, guarded by a lock — call `reset()` between
/// tests, and put tests that use this in a `@Suite(.serialized)` suite so
/// they can't steal each other's stubbed responses.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
        var onRequest: (@Sendable (URLRequest) -> Void)?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []

    static func stub(
        statusCode: Int = 200,
        headers: [String: String] = ["Content-Type": "application/json"],
        body: Data,
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) {
        lock.withLock {
            stubs.append(Stub(statusCode: statusCode, headers: headers, body: body, onRequest: onRequest))
        }
    }

    static func reset() {
        lock.withLock { stubs.removeAll() }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub: Stub? = Self.lock.withLock {
            guard !Self.stubs.isEmpty else { return nil }
            return Self.stubs.removeFirst()
        }
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        stub.onRequest?(Self.materializingBody(of: request))
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.supabase.co")!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `URLSession` commonly moves a request's body from `httpBody` into
    /// `httpBodyStream` before handing the request to a custom
    /// `URLProtocol` — a well-known footgun for `URLProtocol`-based
    /// mocking. Returns a copy with `httpBody` populated from the stream
    /// when that's where the body actually ended up, so callers can just
    /// read `.httpBody` without knowing which path it came in on.
    private static func materializingBody(of request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }
        var request = request
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)
        }
        request.httpBody = data
        return request
    }
}

/// A lock-protected box for values a `@Sendable` stub closure needs to hand
/// back to the test that installed it — a bare local `var` can't be mutated
/// from inside `@Sendable` closure under Swift 6 strict concurrency.
final class Captured<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }

    func get() -> Value {
        lock.withLock { value }
    }
}
