import Foundation
import Sentry

/// Crashes, app hangs and the hand-picked handled errors (D4). One of the
/// two files that import an SDK (eng E1; `.swiftlint.yml` enforces it).
///
/// Started only while sharing is on; closed when it goes off, so no crash
/// or hang is written to disk while off. A crash is reported only if
/// sharing was on when it happened and at the launch that uploads it (eng
/// E7): a launch with sharing off never starts the SDK, so a crash file
/// from an earlier launch is neither sent nor discarded until a launch with
/// sharing on, and `beforeSend` drops anything still in flight once the
/// flag goes false.
final class SentrySink: TelemetrySink {
    private let dsn: String
    private let environment: String
    private let release: String
    private let consent: TelemetryConsent
    private var isStarted = false

    init(dsn: String, environment: String, release: String, consent: TelemetryConsent) {
        self.dsn = dsn
        self.environment = environment
        self.release = release
        self.consent = consent
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let configure = Self.configure(dsn: dsn, environment: environment, release: release, consent: consent)
        SentrySDK.start(configureOptions: configure)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        SentrySDK.close()
    }

    /// Product events are PostHog's.
    func capture(_ event: TelemetryEvent) {}

    func record(_ report: TelemetryErrorReport) {
        guard isStarted else { return }
        SentrySDK.capture(event: Self.makeEvent(for: report))
    }

    func identify(_ userID: UUID) {
        guard isStarted else { return }
        SentrySDK.setUser(User(userId: userID.uuidString.lowercased()))
    }

    func reset() {
        guard isStarted else { return }
        SentrySDK.setUser(nil)
    }

    // MARK: Configuration (spec item 3, exactly)

    /// The options closure, built off the main actor's state so Sentry can
    /// call `beforeSend` and `beforeBreadcrumb` on its own queue.
    nonisolated static func configure(
        dsn: String,
        environment: String,
        release: String,
        consent: TelemetryConsent
    ) -> @Sendable (Options) -> Void {
        { options in
            options.dsn = dsn
            options.environment = environment
            options.releaseName = release
            options.enableAppHangTracking = true
            options.enableUserInteractionTracing = false
            options.enableAutoPerformanceTracing = false
            options.sendDefaultPii = false
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            // tracesSampleRate stays unset and the session replay rates at 0.
            options.beforeSend = { event in consent.isEnabled ? event : nil }
            options.beforeBreadcrumb = { breadcrumb in strippingQuery(from: breadcrumb) }
        }
    }

    /// Network breadcrumbs keep the URL's path and drop its query string
    /// (defense in depth: the nearby RPC is a POST, so no coordinate is in a
    /// URL anyway).
    nonisolated static func strippingQuery(from breadcrumb: Breadcrumb) -> Breadcrumb {
        guard let url = breadcrumb.data?["url"] as? String,
              var components = URLComponents(string: url),
              components.query != nil || components.fragment != nil else { return breadcrumb }
        components.query = nil
        components.fragment = nil
        breadcrumb.setData(value: components.string ?? url, key: "url")
        return breadcrumb
    }

    // MARK: Handled errors (eng E5)

    /// A hand-built event: message = the Swift type name, tags `context` and
    /// `error_type`, extra `code` only. The original error object never
    /// reaches the SDK, so no message string or user info can leave.
    nonisolated static func makeEvent(for report: TelemetryErrorReport) -> Event {
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: report.errorType)
        event.tags = ["context": report.context, "error_type": report.errorType]
        if let code = report.code {
            event.extra = ["code": code]
        }
        return event
    }

    #if DEBUG
    /// `-TelemetryCrashTest` (AC 3/4): a real crash Sentry symbolicates.
    static func crashForTesting() {
        SentrySDK.crash()
        fatalError("TelemetryCrashTest")
    }
    #endif
}
