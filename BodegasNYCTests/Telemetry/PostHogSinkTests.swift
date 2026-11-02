//
//  PostHogSinkTests.swift
//  BodegasNYCTests
//
//  `PostHogSink` over a recording `PostHogClient` (#151): when the SDK is
//  set up, and what it is told while sharing is off. The fake stands in for
//  `PostHogSDK.shared`, so what the SDK itself does with a call (its
//  remote-config fetch, its queue) is the live check's, not these tests'.
//

import Foundation
import Testing

@testable import BodegasNYC

@MainActor
final class RecordingPostHogClient: PostHogClient {
    enum Call: Equatable {
        case setup
        case register(keys: [String])
        case optIn
        case optOut
        case capture(String)
        case identify(String)
        case reset
    }

    private(set) var calls: [Call] = []

    func setup(apiKey: String, host: URL) { calls.append(.setup) }
    func register(_ properties: [String: Any]) { calls.append(.register(keys: properties.keys.sorted())) }
    func optIn() { calls.append(.optIn) }
    func optOut() { calls.append(.optOut) }
    func capture(_ event: String, properties: [String: Any]) { calls.append(.capture(event)) }
    func identify(_ distinctID: String) { calls.append(.identify(distinctID)) }
    func reset() { calls.append(.reset) }
}

@MainActor
struct PostHogSinkTests {
    private static let userA = UUID(uuidString: "3fa85f64-5717-4562-b3fc-2c963f66afa6")!

    private func makeSink(defaults: UserDefaults) -> (PostHogSink, RecordingPostHogClient) {
        let client = RecordingPostHogClient()
        let sink = PostHogSink(
            apiKey: "test-key",
            host: URL(string: "https://example.invalid")!,
            environment: "debug",
            client: client,
            userDefaults: defaults
        )
        return (sink, client)
    }

    /// protects=an opted-out launch never sets the SDK up (so it cannot
    /// fetch its remote config), and a capture, identify or the launch's
    /// stop reach no SDK call; fails_when=construction or `stop()` calls
    /// setup, or anything reaches the SDK before `start()`; no_claim=that
    /// the SDK makes no request once set up (live log-stream check).
    @Test func optedOutLaunchNeverSetsUp() {
        let defaults = makeTelemetryDefaults()
        defaults.set(false, forKey: Telemetry.isEnabledKey)
        let (sink, client) = makeSink(defaults: defaults)
        let telemetry = Telemetry(sinks: [sink], userDefaults: defaults)
        telemetry.capture(.locateMeTapped)
        telemetry.identify(Self.userA)
        #expect(client.calls.isEmpty)
    }

    /// protects=turning sharing on sets the SDK up once, registers the
    /// environment, then opts in, and re-identifies the signed-in user;
    /// off then on again opts out and back in without a second setup;
    /// fails_when=optIn precedes setup, setup runs twice, or stop skips
    /// optOut once set up; no_claim=the SDK's persisted opt-out (live QA).
    @Test func startSetsUpThenOptsIn() {
        let defaults = makeTelemetryDefaults()
        defaults.set(false, forKey: Telemetry.isEnabledKey)
        let (sink, client) = makeSink(defaults: defaults)
        let telemetry = Telemetry(sinks: [sink], userDefaults: defaults)
        telemetry.identify(Self.userA)

        telemetry.setEnabled(true)
        let distinctID = Self.userA.uuidString.lowercased()
        #expect(client.calls == [.setup, .register(keys: ["environment"]), .optIn, .identify(distinctID)])

        telemetry.setEnabled(false)
        telemetry.setEnabled(true)
        #expect(client.calls.suffix(3) == [.optOut, .optIn, .identify(distinctID)])
        #expect(client.calls.filter { $0 == .setup }.count == 1)
    }

    /// protects=a launch with sharing on sets up and opts in at once, as
    /// before #151; fails_when=an on launch waits for a toggle;
    /// no_claim=none beyond protects.
    @Test func onLaunchSetsUpImmediately() {
        let defaults = makeTelemetryDefaults()
        let (sink, client) = makeSink(defaults: defaults)
        _ = Telemetry(sinks: [sink], userDefaults: defaults)
        #expect(client.calls == [.setup, .register(keys: ["environment"]), .optIn])
    }

    /// protects=a sign-out while off and never set up (eng E2) survives a
    /// relaunch on disk and runs right after the next setup, before opt-in,
    /// so the first event after re-enabling is anonymous; fails_when=the
    /// reset is dropped, lost across a relaunch, runs after optIn, or runs
    /// again on a later start; no_claim=PostHog's new anonymous id (AC 6).
    @Test func resetWhileNeverSetUpRunsAfterNextSetup() {
        let defaults = makeTelemetryDefaults()
        defaults.set(false, forKey: Telemetry.isEnabledKey)
        let (firstSink, firstClient) = makeSink(defaults: defaults)
        let first = Telemetry(sinks: [firstSink], userDefaults: defaults)
        first.reset()
        #expect(firstClient.calls.isEmpty)

        let (sink, client) = makeSink(defaults: defaults)
        let relaunched = Telemetry(sinks: [sink], userDefaults: defaults)
        relaunched.setEnabled(true)
        #expect(client.calls == [.setup, .reset, .register(keys: ["environment"]), .optIn])

        let (laterSink, laterClient) = makeSink(defaults: defaults)
        laterSink.start()
        #expect(laterClient.calls == [.setup, .register(keys: ["environment"]), .optIn])
    }
}
