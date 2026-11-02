//
//  TelemetryConfigTests.swift
//  BodegasNYCTests
//
//  The vendor keys out of an Info.plist dictionary and the launch gate that
//  decides which vendors start (#147 D5, D7, item 2). Pure values: no SDK is
//  touched and nothing is sent.
//

import Foundation
import Testing

@testable import BodegasNYC

struct TelemetryConfigTests {
    private static var full: [String: Any] {
        [
        "SENTRY_DSN": "https://public@o0.ingest.us.sentry.io/0",
        "POSTHOG_API_KEY": "phc_test",
        "POSTHOG_HOST": "https://us.i.posthog.com"
        ]
    }

    /// protects=the three Info.plist keys reach the config unchanged;
    /// fails_when=a key is dropped, renamed or its host is not parsed;
    /// no_claim=that the build settings substitute into the real Info.plist
    /// (AC 1, the Release build's `plutil` check).
    @Test func readsAllThreeKeys() {
        let config = TelemetryConfig(infoDictionary: Self.full)
        #expect(config.sentryDSN == "https://public@o0.ingest.us.sentry.io/0")
        #expect(config.posthogAPIKey == "phc_test")
        #expect(config.posthogHost == URL(string: "https://us.i.posthog.com"))
    }

    /// protects=the committed placeholders (empty strings) and missing keys
    /// both read as "not configured"; fails_when=an empty string survives as
    /// a key an SDK would be started with; no_claim=none beyond protects.
    @Test func emptyOrMissingKeysAreNil() {
        let empty = TelemetryConfig(infoDictionary: ["SENTRY_DSN": "", "POSTHOG_API_KEY": "  ", "POSTHOG_HOST": ""])
        let missing = TelemetryConfig(infoDictionary: [:])
        for config in [empty, missing] {
            #expect(config.sentryDSN == nil)
            #expect(config.posthogAPIKey == nil)
            #expect(config.posthogHost == nil)
        }
    }

    /// protects=a host that is not an absolute http(s) URL is treated as
    /// missing (no built-in default host); fails_when=a bare word or a
    /// scheme-less string becomes a host; no_claim=none beyond protects.
    @Test func unparsableHostIsNil() {
        for host in ["us.i.posthog.com", "not a url", "ftp://us.i.posthog.com", "https://"] {
            var info = Self.full
            info["POSTHOG_HOST"] = host
            #expect(TelemetryConfig(infoDictionary: info).posthogHost == nil, "\(host)")
        }
    }

    // MARK: The launch gate (TelemetryPlan)

    private static let configured = TelemetryConfig(infoDictionary: full)

    /// protects=a DEBUG launch without `-Telemetry` (every UI test and
    /// `run-tests.sh` run) starts no vendor (AC 2); fails_when=any vendor is
    /// planned without the argument; no_claim=that no request leaves the
    /// simulator (the QA lane's proxy check).
    @Test func debugWithoutTheArgumentStartsNothing() {
        let plan = TelemetryPlan.make(config: Self.configured, launchArguments: ["-UITestFixtures"], isDebugBuild: true)
        #expect(plan.vendors.isEmpty)
        #expect(plan.environment == "debug")
    }

    /// protects=DEBUG with `-Telemetry` plans both vendors, PostHog first,
    /// tagged `debug`, and Release plans them tagged `production` with no
    /// argument (D5); fails_when=the environment is wrong, a vendor is
    /// missing, or Release needs the argument; no_claim=that the vendors
    /// receive the environment (live QA, AC 3).
    @Test func debugWithTheArgumentAndReleasePlanBothVendors() throws {
        let host = try #require(URL(string: "https://us.i.posthog.com"))
        let expected: [TelemetryPlan.Vendor] = [
            .posthog(apiKey: "phc_test", host: host),
            .sentry(dsn: "https://public@o0.ingest.us.sentry.io/0")
        ]
        let debug = TelemetryPlan.make(config: Self.configured, launchArguments: ["-Telemetry"], isDebugBuild: true)
        let release = TelemetryPlan.make(config: Self.configured, launchArguments: [], isDebugBuild: false)
        #expect(debug.vendors == expected)
        #expect(debug.environment == "debug")
        #expect(release.vendors == expected)
        #expect(release.environment == "production")
        #expect(release.notices.isEmpty)
    }

    /// protects=the committed empty keys plan no vendor and say so, one
    /// notice each, without a key in the text; fails_when=an empty key
    /// starts an SDK, or a notice is missing; no_claim=the OSLog output.
    @Test func emptyKeysPlanNoVendors() {
        let empty = TelemetryConfig(infoDictionary: ["SENTRY_DSN": "", "POSTHOG_API_KEY": "", "POSTHOG_HOST": "x"])
        let plan = TelemetryPlan.make(config: empty, launchArguments: [], isDebugBuild: false)
        #expect(plan.vendors.isEmpty)
        #expect(plan.notices.count == 2)
    }

    /// protects=a PostHog key without a usable host skips PostHog only;
    /// Sentry still starts; fails_when=PostHog is planned with no host, or
    /// Sentry is skipped too; no_claim=none beyond protects.
    @Test func keyWithoutHostSkipsPostHogOnly() {
        var config = Self.configured
        config.posthogHost = nil
        let plan = TelemetryPlan.make(config: config, launchArguments: [], isDebugBuild: false)
        #expect(plan.vendors == [.sentry(dsn: "https://public@o0.ingest.us.sentry.io/0")])
        #expect(plan.notices == ["PostHog skipped: POSTHOG_HOST is empty or not a URL"])
    }
}
