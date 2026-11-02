//
//  TelemetryTests.swift
//  BodegasNYCTests
//
//  `Telemetry`, the one owner (#147 eng E1 to E3, E5, design DS3): the
//  persisted setting, the off/on sequence, identity bookkeeping while off,
//  the record filter and the Sentry event's allow-list. A `RecordingSink`
//  stands in for both vendors except in the last test, which builds the
//  real Sentry event (the test target links `Sentry` for it) without
//  starting the SDK.
//

import AuthenticationServices
import Foundation
import PostgREST
import Sentry
import Testing

@testable import BodegasNYC

@MainActor
struct TelemetryTests {
    private static let userA = UUID(uuidString: "3fa85f64-5717-4562-b3fc-2c963f66afa6")!

    // MARK: The setting

    /// protects=the switch is on for a device that never set it, a change
    /// persists under `telemetry.isEnabled` and survives a relaunch (a new
    /// instance over the same defaults), and the consent flag the SDK
    /// callbacks read mirrors it; fails_when=the default is off, the value
    /// is not persisted, or the consent flag disagrees; no_claim=the SDKs'
    /// own persisted opt-out (live QA, AC 4).
    @Test func settingDefaultsOnAndPersists() {
        let defaults = makeTelemetryDefaults()
        let first = Telemetry(sinks: [], userDefaults: defaults)
        #expect(first.isEnabled)
        #expect(first.consent.isEnabled)
        #expect(defaults.object(forKey: Telemetry.isEnabledKey) == nil)

        first.setEnabled(false)
        #expect(defaults.object(forKey: Telemetry.isEnabledKey) as? Bool == false)
        #expect(first.consent.isEnabled == false)

        let relaunched = Telemetry(sinks: [], userDefaults: defaults)
        #expect(relaunched.isEnabled == false)
        #expect(relaunched.consent.isEnabled == false)
    }

    /// protects=a launch starts each sink when the setting is on and stops
    /// it when off, so an SDK's persisted state cannot drift from it;
    /// fails_when=an off launch starts a sink or an on launch stops one;
    /// no_claim=what each SDK does with start/stop (live QA).
    @Test func launchStartsOrStopsSinksPerTheSetting() {
        let defaults = makeTelemetryDefaults()
        let onSink = RecordingSink()
        _ = Telemetry(sinks: [onSink], userDefaults: defaults)
        #expect(onSink.calls == [.start])

        defaults.set(false, forKey: Telemetry.isEnabledKey)
        let offSink = RecordingSink()
        _ = Telemetry(sinks: [offSink], userDefaults: defaults)
        #expect(offSink.calls == [.stop])
    }

    // MARK: Off and on (DS3)

    /// protects=off means off: the off-switch stops the sinks with no final
    /// event, nothing is captured or recorded after it, and the on-switch
    /// starts them and re-identifies the signed-in user without capturing;
    /// an off/on/off run repeats that exactly (AC 5); the consent flag the
    /// SDK callbacks read is already false when the sinks stop and already
    /// true when they start; fails_when=a `telemetry_disabled`-style event
    /// goes out, an event leaks after off, the on-switch captures or forgets
    /// the user, or `setEnabled` flips consent after stopping or before
    /// starting the sinks; no_claim=that the SDKs send nothing after opting
    /// out (proxy check, AC 4).
    @Test func offThenOnSequence() {
        let (telemetry, sink) = makeRecordingTelemetry()
        telemetry.identify(Self.userA)
        sink.clear()

        telemetry.setEnabled(false)
        #expect(sink.calls == [.stop])
        telemetry.capture(.locateMeTapped)
        telemetry.record(URLError(.timedOut), context: "test")
        telemetry.identify(Self.userA)
        #expect(sink.calls == [.stop])

        telemetry.setEnabled(true)
        #expect(sink.calls == [.stop, .start, .identify(Self.userA)])
        #expect(sink.events.isEmpty)

        telemetry.setEnabled(false)
        #expect(sink.calls == [.stop, .start, .identify(Self.userA), .stop])
        #expect(sink.events.isEmpty)

        telemetry.setEnabled(false)
        #expect(sink.calls.count == 4)
        #expect(sink.consentAtStop == [false, false])
        #expect(sink.consentAtStart == [true])
    }

    /// protects=identity is tracked while off (E2): signed in as A, turn
    /// off, sign out, turn on, and the next event is anonymous (the reset
    /// reached the sinks while off; no identify on re-enable);
    /// fails_when=the reset waits for consent, or re-enabling identifies A;
    /// no_claim=PostHog's new anonymous id (live QA, AC 6).
    @Test func signOutWhileOffStaysAnonymousAfterReEnable() {
        let (telemetry, sink) = makeRecordingTelemetry()
        telemetry.identify(Self.userA)
        telemetry.setEnabled(false)
        telemetry.reset()
        telemetry.setEnabled(true)
        telemetry.capture(.locateMeTapped)

        #expect(sink.calls == [.identify(Self.userA), .stop, .reset, .start, .capture(.locateMeTapped)])
        #expect(telemetry.currentUserID == nil)
    }

    // MARK: Handled errors (E5)

    /// protects=user cancels never reach a sink (CancellationError,
    /// URLError.cancelled, ASAuthorizationError.canceled), while a real
    /// failure does; fails_when=a cancel is recorded or a failure dropped;
    /// no_claim=none beyond protects.
    @Test func cancellationsAreDropped() {
        let (telemetry, sink) = makeRecordingTelemetry()
        telemetry.record(CancellationError(), context: "test")
        telemetry.record(URLError(.cancelled), context: "test")
        telemetry.record(ASAuthorizationError(.canceled), context: "test")
        #expect(sink.reports.isEmpty)

        telemetry.record(URLError(.notConnectedToInternet), context: "list.fetch")
        #expect(sink.reports == [
            TelemetryErrorReport(context: "list.fetch", errorType: "Foundation.URLError", code: "-1009")
        ])
    }

    /// protects=a PostgREST error whose message is an email address reaches
    /// the sink as context, type and SQLSTATE only, and the Sentry event
    /// built from it serializes to the allow-list: message = the type name,
    /// tags `context` and `error_type`, extra `code`, with the email nowhere
    /// in the payload (AC 8); fails_when=the message, detail or hint leaks
    /// into any serialized value, or an unexpected top-level key appears;
    /// no_claim=what the SDK adds when it sends (device context, breadcrumbs,
    /// release), and crash reports, which the OS produces.
    @Test func handledErrorEventCarriesNoMessage() throws {
        let email = "someone@example.com"
        let error = PostgrestError(detail: "Key (email)=(\(email))", hint: email, code: "23505", message: email)
        let (telemetry, sink) = makeRecordingTelemetry()
        telemetry.record(error, context: "review.submit")

        let report = try #require(sink.reports.first)
        #expect(report == TelemetryErrorReport(
            context: "review.submit",
            errorType: "Helpers.PostgrestError",
            code: "23505"
        ))

        let serialized = SentrySink.makeEvent(for: report).serialize()
        let allowed: Set<String> = ["event_id", "timestamp", "platform", "level", "message", "tags", "extra"]
        #expect(Set(serialized.keys).isSubset(of: allowed), "\(serialized.keys.sorted())")
        #expect((serialized["message"] as? [String: Any])?["formatted"] as? String == "Helpers.PostgrestError")
        #expect(serialized["tags"] as? [String: String] == ["context": "review.submit", "error_type": "Helpers.PostgrestError"])
        #expect((serialized["extra"] as? [String: Any]).map { Set($0.keys) } == ["code"])
        let json = String(decoding: try JSONSerialization.data(withJSONObject: serialized), as: UTF8.self)
        #expect(!json.contains(email))
    }
}
