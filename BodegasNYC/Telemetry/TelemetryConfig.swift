import Foundation

/// The two vendors' keys (#147 D7), baked into Info.plist from the
/// `SENTRY_DSN`, `POSTHOG_API_KEY` and `POSTHOG_HOST` build settings, the
/// same way `SupabaseConfig` reads `SUPABASE_URL`. Never throws: an empty
/// or missing key becomes `nil` and that vendor is skipped, so a missing
/// key can never affect launch.
nonisolated struct TelemetryConfig: Equatable, Sendable {
    var sentryDSN: String?
    var posthogAPIKey: String?
    /// `nil` when empty or unparsable; there is no built-in default host.
    var posthogHost: URL?

    init(sentryDSN: String?, posthogAPIKey: String?, posthogHost: URL?) {
        self.sentryDSN = sentryDSN
        self.posthogAPIKey = posthogAPIKey
        self.posthogHost = posthogHost
    }

    init(infoDictionary: [String: Any]) {
        sentryDSN = Self.nonEmpty(infoDictionary["SENTRY_DSN"])
        posthogAPIKey = Self.nonEmpty(infoDictionary["POSTHOG_API_KEY"])
        posthogHost = Self.nonEmpty(infoDictionary["POSTHOG_HOST"]).flatMap(Self.hostURL)
    }

    init(bundle: Bundle = .main) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }
        return string
    }

    /// An absolute http(s) URL with a host, else `nil`.
    private static func hostURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }
}

/// Which vendors a launch starts, decided before any SDK is touched, so the
/// gate is unit-testable with no network (spec D5, item 2).
nonisolated struct TelemetryPlan: Equatable, Sendable {
    enum Vendor: Equatable, Sendable {
        case posthog(apiKey: String, host: URL)
        case sentry(dsn: String)
    }

    /// `"debug"` in a DEBUG build, `"production"` in Release.
    var environment: String
    /// PostHog first, then Sentry: the off-switch opts PostHog out before
    /// Sentry stops, and the on-switch opts it in before Sentry starts (DS3).
    var vendors: [Vendor]
    /// One line per skipped vendor, for the startup log. Never a key.
    var notices: [String]

    static let launchArgument = "-Telemetry"
    static let crashTestArgument = "-TelemetryCrashTest"

    /// Release always sends; DEBUG only with `-Telemetry` (D5). UI tests and
    /// `run-tests.sh` never pass it, so they never start a vendor.
    static func make(config: TelemetryConfig, launchArguments: [String], isDebugBuild: Bool) -> TelemetryPlan {
        let environment = isDebugBuild ? "debug" : "production"
        guard !isDebugBuild || launchArguments.contains(launchArgument) else {
            return TelemetryPlan(
                environment: environment,
                vendors: [],
                notices: ["telemetry off: DEBUG build without \(launchArgument)"]
            )
        }
        var vendors: [Vendor] = []
        var notices: [String] = []
        switch (config.posthogAPIKey, config.posthogHost) {
        case (nil, _):
            notices.append("PostHog skipped: POSTHOG_API_KEY is empty")
        case (_?, nil):
            notices.append("PostHog skipped: POSTHOG_HOST is empty or not a URL")
        case let (apiKey?, host?):
            vendors.append(.posthog(apiKey: apiKey, host: host))
        }
        if let dsn = config.sentryDSN {
            vendors.append(.sentry(dsn: dsn))
        } else {
            notices.append("Sentry skipped: SENTRY_DSN is empty")
        }
        return TelemetryPlan(environment: environment, vendors: vendors, notices: notices)
    }
}
