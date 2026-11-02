import Foundation
import PostHog

/// Product analytics (D1, D2). One of the two files that import an SDK
/// (eng E1; `.swiftlint.yml` enforces it).
///
/// Set up once at launch, on or off, so the SDK's persisted opt-out always
/// matches the setting and `reset()` works while sharing is off (eng E2).
/// Lifecycle events stay on; screen views, autocapture, replay, feature
/// flags, surveys, GeoIP and PostHog's own error tracking are off.
final class PostHogSink: TelemetrySink {
    private var sdk: PostHogSDK { PostHogSDK.shared }

    init(apiKey: String, host: URL, environment: String, optedOut: Bool) {
        sdk.setup(Self.makeConfig(apiKey: apiKey, host: host, optedOut: optedOut))
        sdk.register(["environment": environment])
    }

    /// Spec item 3, exactly. `personProfiles` stays `.identifiedOnly` and
    /// `errorTrackingConfig.autoCapture` stays false (Sentry owns the crash
    /// handlers; two must not both install).
    static func makeConfig(apiKey: String, host: URL, optedOut: Bool) -> PostHogConfig {
        let config = PostHogConfig(projectToken: apiKey, host: host.absoluteString)
        config.captureScreenViews = false
        config.captureApplicationLifecycleEvents = true
        config.preloadFeatureFlags = false
        config.surveys = false
        config.sessionReplay = false
        config.disableGeoIp = true
        config.optOut = optedOut
        return config
    }

    func start() {
        sdk.optIn()
    }

    /// Opt out at once; nothing is captured or flushed first (design DS3).
    func stop() {
        sdk.optOut()
    }

    func capture(_ event: TelemetryEvent) {
        sdk.capture(event.name, properties: event.properties.mapValues(\.sdkValue))
    }

    /// Handled errors are Sentry's.
    func record(_ report: TelemetryErrorReport) {}

    /// The Supabase user id and no person property (AC 6).
    func identify(_ userID: UUID) {
        sdk.identify(userID.uuidString.lowercased())
    }

    func reset() {
        sdk.reset()
    }
}
