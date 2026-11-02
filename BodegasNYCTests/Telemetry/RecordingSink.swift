//
//  RecordingSink.swift
//  BodegasNYCTests
//
//  A `TelemetrySink` that writes every call into one ordered log (#147 eng
//  E1), standing in for both vendors. It conforms to the real protocol, so
//  `Telemetry`'s consent, identity and on/off logic runs unmodified on top
//  of it; what it cannot show is what either SDK does with a call.
//

import Foundation

@testable import BodegasNYC

@MainActor
final class RecordingSink: TelemetrySink {
    enum Call: Equatable {
        case start
        case stop
        case capture(TelemetryEvent)
        case record(TelemetryErrorReport)
        case identify(UUID)
        case reset
    }

    private(set) var calls: [Call] = []
    /// The consent flag the SDK callbacks read, as this sink saw it at each
    /// `stop()` and `start()`, so a test can pin the off/on order (DS3).
    var consent: TelemetryConsent?
    private(set) var consentAtStop: [Bool] = []
    private(set) var consentAtStart: [Bool] = []

    var events: [TelemetryEvent] {
        calls.compactMap { if case .capture(let event) = $0 { event } else { nil } }
    }

    var reports: [TelemetryErrorReport] {
        calls.compactMap { if case .record(let report) = $0 { report } else { nil } }
    }

    /// Only the identify and reset calls, in order.
    var identity: [Call] {
        calls.filter {
            switch $0 {
            case .identify, .reset: true
            default: false
            }
        }
    }

    func clear() {
        calls = []
        consentAtStop = []
        consentAtStart = []
    }

    func start() {
        calls.append(.start)
        if let consent { consentAtStart.append(consent.isEnabled) }
    }

    func stop() {
        calls.append(.stop)
        if let consent { consentAtStop.append(consent.isEnabled) }
    }
    func capture(_ event: TelemetryEvent) { calls.append(.capture(event)) }
    func record(_ report: TelemetryErrorReport) { calls.append(.record(report)) }
    func identify(_ userID: UUID) { calls.append(.identify(userID)) }
    func reset() { calls.append(.reset) }
}

/// A fresh, isolated defaults suite, so the stored setting starts absent.
func makeTelemetryDefaults() -> UserDefaults {
    UserDefaults(suiteName: "TelemetryTests.\(UUID().uuidString)")!
}

/// A `Telemetry` over one `RecordingSink`, with the setting on (absent).
@MainActor
func makeRecordingTelemetry(defaults: UserDefaults = makeTelemetryDefaults()) -> (Telemetry, RecordingSink) {
    let sink = RecordingSink()
    let telemetry = Telemetry(sinks: [sink], userDefaults: defaults)
    sink.consent = telemetry.consent
    sink.clear()
    return (telemetry, sink)
}
