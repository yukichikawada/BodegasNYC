//
//  SharedWalkTelemetryTests.swift
//  BodegasNYCTests
//
//  #177 PR 2, AC 15: a walk link's fragment is the walk itself, so no
//  outbound telemetry payload may hold any piece of it. PostHog's own
//  `Deep Link Opened` (built by posthog-ios 3.93.1 from the full URL) is
//  dropped in `beforeSend`, URL properties are stripped from the SDK's
//  other events, and Sentry's breadcrumbs lose the fragment
//  (`SentrySink.strippingQuery`, already in place; tested here).
//

import Foundation
import Sentry
import Testing

@testable import BodegasNYC

/// Records every property a `PostHogSink` hands the SDK, serialized.
@MainActor
final class PayloadRecordingPostHogClient: PostHogClient {
    private(set) var payloads: [String] = []

    private func record(_ value: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        payloads.append(String(decoding: data, as: UTF8.self))
    }

    func setup(apiKey: String, host: URL) { record(["host": host.absoluteString]) }
    func register(_ properties: [String: Any]) { record(properties) }
    func optIn() {}
    func optOut() {}
    func capture(_ event: String, properties: [String: Any]) { record(["event": event, "properties": properties]) }
    func identify(_ distinctID: String) { record(["id": distinctID]) }
    func reset() {}
}

@Suite
@MainActor
struct SharedWalkTelemetryTests {
    /// A real walk link and its fragment.
    static func link() throws -> (url: URL, fragment: String) {
        let walk = SharedWalk(
            firstDay: WalkedDayKey(value: 20261103),
            lastDay: WalkedDayKey(value: 20261109),
            blockIDs: UITestFixtures.sharedWalkFixtureIDs,
            meters: 3_380,
            newCount: 6,
            isEstimate: true
        )
        guard case .url(let url) = SharedWalkLink.encode(walk), let fragment = url.fragment() else {
            throw CancellationError()
        }
        return (url, fragment)
    }

    /// Every 6-character piece of the fragment's payload (the version and
    /// end letter alone are not the walk).
    static func pieces(of fragment: String) -> [String] {
        let payload = Array(fragment.dropFirst(2).dropLast(2))
        guard payload.count >= 6 else { return [String(payload)] }
        return (0 ... payload.count - 6).map { String(payload[$0 ..< $0 + 6]) }
    }

    static func expectNoPiece(of fragment: String, in payload: String, _ where: String) {
        let leaked = pieces(of: fragment).first { payload.contains($0) }
        #expect(leaked == nil, "\(`where`) holds \"\(leaked ?? "")\" from the fragment")
    }

    /// protects=AC 15 for PostHog's own events: `Deep Link Opened`, built
    /// as posthog-ios 3.93.1 builds it (`url` = the full URL, fragment
    /// included), is dropped whole; a lifecycle event that carries `url`
    /// or `$current_url` keeps its other properties and loses those; the
    /// app's own events pass unchanged; fails_when=the deep-link event
    /// survives, a URL property survives on any event, or an unrelated
    /// property is stripped; no_claim=that the SDK runs `beforeSend` on
    /// every event (posthog-ios's contract; read in its source) or a live
    /// proxied run (QA).
    @Test func beforeSendDropsTheDeepLinkAndStripsURLs() throws {
        let (url, fragment) = try Self.link()
        #expect(PostHogSink.scrubbed(event: "Deep Link Opened", properties: ["url": url.absoluteString]) == nil)
        let opened = try #require(PostHogSink.scrubbed(
            event: "Application Opened",
            properties: ["url": url.absoluteString, "$current_url": url.absoluteString, "from_background": true]
        ))
        #expect(Set(opened.keys) == ["from_background"])
        let json = String(decoding: try JSONSerialization.data(withJSONObject: opened), as: UTF8.self)
        Self.expectNoPiece(of: fragment, in: json, "Application Opened")
        let own = try #require(PostHogSink.scrubbed(event: "shared_walk_opened", properties: ["result": "ok"]))
        #expect(own["result"] as? String == "ok" && own.count == 1)
    }

    /// protects=AC 15 end to end through the app's side of PostHog: opening
    /// a walk link with consent on sends exactly one `shared_walk_opened`
    /// with `result` = `ok`, and no payload the sink hands the SDK (setup,
    /// register, capture) holds any 6-character piece of the link's
    /// fragment; fails_when=the URL, fragment or any decoded value reaches
    /// a call; no_claim=what the SDK adds after the sink (dropped or
    /// stripped by `beforeSend`, test above).
    @Test func openingALinkSendsNoPieceOfItToPostHog() throws {
        let (url, fragment) = try Self.link()
        let client = PayloadRecordingPostHogClient()
        let sink = PostHogSink(
            apiKey: "test-key",
            host: URL(string: "https://example.invalid")!,
            environment: "debug",
            client: client,
            userDefaults: makeTelemetryDefaults()
        )
        let telemetry = Telemetry(sinks: [sink], userDefaults: makeTelemetryDefaults())
        telemetry.setEnabled(true)
        sink.start()
        let inbox = SharedWalkInbox { telemetry.capture($0) }
        inbox.receive(url)
        let captures = client.payloads.filter { $0.contains("\"event\"") }
        #expect(captures == [#"{"event":"shared_walk_opened","properties":{"result":"ok"}}"#])
        for payload in client.payloads {
            Self.expectNoPiece(of: fragment, in: payload, "PostHog payload")
        }
    }

    /// protects=AC 15 for Sentry: a navigation breadcrumb whose `url` is a
    /// walk link keeps the host and path and loses the fragment, so its
    /// serialized form holds no 6-character piece of it; fails_when=the
    /// fragment, or any piece of it, survives `strippingQuery`;
    /// no_claim=Sentry's own automatic breadcrumbs, which the SDK passes
    /// through `beforeBreadcrumb` (its contract).
    @Test func sentryBreadcrumbsLoseTheFragment() throws {
        let (url, fragment) = try Self.link()
        let breadcrumb = Breadcrumb(level: .info, category: "navigation")
        breadcrumb.data = ["url": url.absoluteString]
        let stripped = SentrySink.strippingQuery(from: breadcrumb)
        #expect(stripped.data?["url"] as? String == SharedWalkLink.base)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: stripped.serialize()), as: UTF8.self)
        Self.expectNoPiece(of: fragment, in: json, "Sentry breadcrumb")
    }
}
