import AuthenticationServices
import Auth
import Foundation
import Observation
import OSLog
import PostgREST
import Synchronization

/// The consent flag the SDKs' own callbacks read (Sentry's `beforeSend`
/// runs on its queue). A `Mutex<Bool>` behind a class, so it can be shared
/// with those callbacks under Swift 6; only `Telemetry.setEnabled(_:)`
/// writes it (eng E3).
nonisolated final class TelemetryConsent: Sendable {
    private let flag: Mutex<Bool>

    init(_ isEnabled: Bool) {
        flag = Mutex(isEnabled)
    }

    var isEnabled: Bool { flag.withLock { $0 } }

    fileprivate func set(_ isEnabled: Bool) {
        flag.withLock { $0 = isEnabled }
    }
}

/// The app's one telemetry owner (#147, eng E1): the "Share Usage and
/// Diagnostics" setting, the consent flag, the off/on sequence, identity
/// bookkeeping and the DEBUG gate. Built first in
/// `AppDelegate.didFinishLaunching`; views and view models only ever call
/// `capture`, `record`, `identify`, `reset` and `setEnabled`.
///
/// `Telemetry(sinks: [])` is the no-op: it still persists the setting, so
/// the menu toggle works in DEBUG and in UI tests, but sends nothing.
@MainActor
@Observable
final class Telemetry {
    nonisolated static let isEnabledKey = "telemetry.isEnabled"

    /// The setting, per device; on when never set (D3, design DS7).
    private(set) var isEnabled: Bool
    /// Tracked whether or not sharing is on (eng E2), so turning it back on
    /// re-identifies the right user and a sign-out while off still resets.
    @ObservationIgnored private(set) var currentUserID: UUID?
    @ObservationIgnored let consent: TelemetryConsent
    @ObservationIgnored private let sinks: [any TelemetrySink]
    @ObservationIgnored private let userDefaults: UserDefaults

    nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BodegasNYC",
        category: "Telemetry"
    )

    /// Starts each sink when the stored setting is on, stops it otherwise,
    /// so the SDKs' own persisted state can never disagree with the setting.
    init(sinks: [any TelemetrySink], userDefaults: UserDefaults = .standard, consent: TelemetryConsent? = nil) {
        let isEnabled = Self.storedIsEnabled(in: userDefaults)
        let consent = consent ?? TelemetryConsent(isEnabled)
        consent.set(isEnabled)
        self.isEnabled = isEnabled
        self.consent = consent
        self.sinks = sinks
        self.userDefaults = userDefaults
        for sink in sinks {
            if isEnabled { sink.start() } else { sink.stop() }
        }
    }

    nonisolated static func storedIsEnabled(in userDefaults: UserDefaults) -> Bool {
        userDefaults.object(forKey: isEnabledKey) as? Bool ?? true
    }

    // MARK: Events

    func capture(_ event: TelemetryEvent) {
        guard isEnabled else { return }
        for sink in sinks { sink.capture(event) }
    }

    /// A handled error at one of the catch sites (D4). Cancellations are
    /// dropped; everything else reaches the sinks as a sanitized report.
    func record(_ error: any Error, context: String) {
        guard isEnabled, let report = Self.report(for: error, context: context) else { return }
        for sink in sinks { sink.record(report) }
    }

    // MARK: Identity (eng E2)

    func identify(_ userID: UUID) {
        currentUserID = userID
        guard isEnabled else { return }
        for sink in sinks { sink.identify(userID) }
    }

    /// Forwarded even while sharing is off: both SDKs reset locally, so the
    /// next event after turning it back on is anonymous.
    func reset() {
        currentUserID = nil
        for sink in sinks { sink.reset() }
    }

    // MARK: The switch

    /// The only writer of the setting and the consent flag (eng E3). Off
    /// (design DS3): the consent flag goes false, then PostHog opts out and
    /// Sentry closes; no final event and no flush. On: the consent flag goes
    /// true, PostHog opts in, Sentry starts, and the signed-in user, if any,
    /// is identified again; nothing is captured.
    func setEnabled(_ isEnabled: Bool) {
        guard isEnabled != self.isEnabled else { return }
        userDefaults.set(isEnabled, forKey: Self.isEnabledKey)
        self.isEnabled = isEnabled
        consent.set(isEnabled)
        if isEnabled {
            for sink in sinks { sink.start() }
            if let currentUserID {
                for sink in sinks { sink.identify(currentUserID) }
            }
        } else {
            for sink in sinks { sink.stop() }
        }
    }

    // MARK: Error reports (eng E5)

    /// `nil` for a cancellation, which is the user's doing, not a fault.
    static func report(for error: any Error, context: String) -> TelemetryErrorReport? {
        guard !isCancellation(error) else { return nil }
        return TelemetryErrorReport(
            context: context,
            errorType: typeName(of: error),
            code: code(of: error)
        )
    }

    /// The Swift type, module-qualified. A `URLError` arrives bridged as an
    /// `NSError`, so it is named explicitly.
    static func typeName(of error: any Error) -> String {
        if error is URLError { return String(reflecting: URLError.self) }
        return String(reflecting: type(of: error))
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let authorizationError = error as? ASAuthorizationError, authorizationError.code == .canceled { return true }
        return false
    }

    /// A machine code only: PostgREST's SQLSTATE, Auth's error code, a
    /// `URLError` code, or the delete-account function's code or status.
    /// Never a message, for any error type.
    static func code(of error: any Error) -> String? {
        switch error {
        case let error as PostgrestError: error.code
        case let error as AuthError: error.errorCode.rawValue
        case let error as URLError: String(error.code.rawValue)
        case let error as AccountService.Error:
            if case .server(let status, let code, _) = error { code ?? String(status) } else { nil }
        default: nil
        }
    }
}

// MARK: - The app's instance

extension Telemetry {
    /// The launch's telemetry: the plan for this build and these launch
    /// arguments, one sink per configured vendor, one log line per skipped
    /// one. In DEBUG with `-TelemetryCrashTest` (and Sentry configured), the
    /// app crashes 2 s after launch so the next launch can upload it.
    static func live(
        bundle: Bundle = .main,
        launchArguments: [String] = CommandLine.arguments,
        userDefaults: UserDefaults = .standard
    ) -> Telemetry {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        let plan = TelemetryPlan.make(
            config: TelemetryConfig(bundle: bundle),
            launchArguments: launchArguments,
            isDebugBuild: isDebugBuild
        )
        for notice in plan.notices {
            logger.notice("\(notice, privacy: .public)")
        }
        let consent = TelemetryConsent(storedIsEnabled(in: userDefaults))
        let release = Self.release(bundle: bundle)
        let sinks: [any TelemetrySink] = plan.vendors.map { vendor in
            switch vendor {
            case .posthog(let apiKey, let host):
                PostHogSink(apiKey: apiKey, host: host, environment: plan.environment, optedOut: !consent.isEnabled)
            case .sentry(let dsn):
                SentrySink(dsn: dsn, environment: plan.environment, release: release, consent: consent)
            }
        }
        let telemetry = Telemetry(sinks: sinks, userDefaults: userDefaults, consent: consent)
        #if DEBUG
        let hasSentry = plan.vendors.contains { if case .sentry = $0 { true } else { false } }
        if hasSentry, launchArguments.contains(TelemetryPlan.crashTestArgument) {
            Task {
                try? await Task.sleep(for: .seconds(2))
                SentrySink.crashForTesting()
            }
        }
        #endif
        return telemetry
    }

    /// Sentry's `releaseName`: "1.0+1".
    nonisolated static func release(bundle: Bundle) -> String {
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version)+\(build)"
    }
}
