import Foundation
import PostHog

/// Product analytics (D1, D2). One of the two files that import an SDK
/// (eng E1; `.swiftlint.yml` enforces it).
///
/// Set up only once sharing is on (#151), like `SentrySink`: the SDK loads
/// its remote config at `setup` whatever its opt-out says, so a launch
/// with sharing off never sets it up and touches no PostHog host. The first
/// `start()` sets it up, then opts in; `stop()` opts out once it is set up.
/// A `reset()` while it is not set up is remembered on disk and applied
/// right after the next setup, before opting in, so a sign-out while off
/// still leaves the next event anonymous (eng E2).
///
/// Lifecycle events stay on; screen views, autocapture, replay, feature
/// flags, surveys, GeoIP and PostHog's own error tracking are off.
final class PostHogSink: TelemetrySink {
    nonisolated static let pendingResetKey = "telemetry.posthog.pendingReset"

    private let client: any PostHogClient
    private let apiKey: String
    private let host: URL
    private let environment: String
    private let userDefaults: UserDefaults
    private var isSetUp = false

    init(
        apiKey: String,
        host: URL,
        environment: String,
        client: any PostHogClient = LivePostHogClient(),
        userDefaults: UserDefaults = .standard
    ) {
        self.client = client
        self.apiKey = apiKey
        self.host = host
        self.environment = environment
        self.userDefaults = userDefaults
    }

    /// Spec item 3, exactly. `personProfiles` stays `.identifiedOnly` and
    /// `errorTrackingConfig.autoCapture` stays false (Sentry owns the crash
    /// handlers; two must not both install). Set up opted out: `start()`
    /// opts in right after, once a pending reset has run. `remoteConfig` is
    /// not set: in posthog-ios 3.93 it is a deprecated no-op (the SDK always
    /// loads it), which is why setup waits for consent instead.
    static func makeConfig(apiKey: String, host: URL) -> PostHogConfig {
        let config = PostHogConfig(projectToken: apiKey, host: host.absoluteString)
        config.captureScreenViews = false
        config.captureApplicationLifecycleEvents = true
        config.preloadFeatureFlags = false
        config.surveys = false
        config.sessionReplay = false
        config.disableGeoIp = true
        config.optOut = true
        return config
    }

    func start() {
        if !isSetUp {
            isSetUp = true
            client.setup(apiKey: apiKey, host: host)
            if userDefaults.bool(forKey: Self.pendingResetKey) {
                client.reset()
                userDefaults.removeObject(forKey: Self.pendingResetKey)
            }
            client.register(["environment": environment])
        }
        client.optIn()
    }

    /// Opt out at once; nothing is captured or flushed first (design DS3).
    /// Never set up means nothing to opt out of.
    func stop() {
        guard isSetUp else { return }
        client.optOut()
    }

    func capture(_ event: TelemetryEvent) {
        guard isSetUp else { return }
        client.capture(event.name, properties: event.properties.mapValues(\.sdkValue))
    }

    /// Handled errors are Sentry's.
    func record(_ report: TelemetryErrorReport) {}

    /// The Supabase user id and no person property (AC 6).
    func identify(_ userID: UUID) {
        guard isSetUp else { return }
        client.identify(userID.uuidString.lowercased())
    }

    /// Local in the SDK, so it runs while sharing is off; before setup it
    /// waits on disk for the next one.
    func reset() {
        if isSetUp {
            client.reset()
        } else {
            userDefaults.set(true, forKey: Self.pendingResetKey)
        }
    }
}

/// The calls `PostHogSink` makes on the SDK, so a test can record them
/// without linking PostHog (#151). Only PostHog's own types stay in this
/// file.
protocol PostHogClient: AnyObject {
    func setup(apiKey: String, host: URL)
    func register(_ properties: [String: Any])
    func optIn()
    func optOut()
    func capture(_ event: String, properties: [String: Any])
    func identify(_ distinctID: String)
    func reset()
}

/// `PostHogSDK.shared`.
final class LivePostHogClient: PostHogClient {
    private var sdk: PostHogSDK { PostHogSDK.shared }

    func setup(apiKey: String, host: URL) {
        sdk.setup(PostHogSink.makeConfig(apiKey: apiKey, host: host))
    }

    func register(_ properties: [String: Any]) { sdk.register(properties) }
    func optIn() { sdk.optIn() }
    func optOut() { sdk.optOut() }
    func capture(_ event: String, properties: [String: Any]) { sdk.capture(event, properties: properties) }
    func identify(_ distinctID: String) { sdk.identify(distinctID) }
    func reset() { sdk.reset() }
}
