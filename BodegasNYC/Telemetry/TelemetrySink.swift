import Foundation

/// One vendor behind `Telemetry` (eng E1). `Telemetry` owns consent and
/// identity and calls a sink only while sharing is on, except `stop()` and
/// `reset()` (E2). `SentrySink` and `PostHogSink` are the only conformers
/// in the app, and the only files that import an SDK; tests use a
/// recording sink.
@MainActor
protocol TelemetrySink: AnyObject {
    /// Sharing turned on, or on at launch: PostHog opts in, Sentry starts.
    func start()
    /// Sharing turned off, or off at launch: PostHog opts out, Sentry closes.
    /// Nothing is captured or flushed first (design DS3).
    func stop()
    func capture(_ event: TelemetryEvent)
    func record(_ report: TelemetryErrorReport)
    func identify(_ userID: UUID)
    /// A local operation in both SDKs, so it runs even while sharing is off.
    func reset()
}

/// A handled error as the vendors may see it (eng E5): where it happened,
/// its Swift type, and a machine code. Never the error itself, its message
/// or its `localizedDescription`, which can echo user input.
nonisolated struct TelemetryErrorReport: Equatable, Sendable {
    var context: String
    var errorType: String
    var code: String?
}
