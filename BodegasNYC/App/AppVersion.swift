import Foundation

/// The installed marketing version and build, read from the bundle (#191):
/// the one place the app formats them, for the Account menu's version row,
/// the walk history export file's `appVersion` and Sentry's release name, so
/// the three cannot drift. A missing key reads as "0", as before.
nonisolated struct AppVersion: Hashable, Sendable {
    /// `CFBundleShortVersionString` (`MARKETING_VERSION`): "1.1.0".
    let version: String
    /// `CFBundleVersion` (`CURRENT_PROJECT_VERSION`): "4".
    let build: String

    init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    init(infoDictionary: [String: Any]?) {
        self.init(
            version: infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            build: infoDictionary?["CFBundleVersion"] as? String ?? "0"
        )
    }

    /// "1.1.0 (4)": the export file's `appVersion` and the version row's value.
    var display: String { "\(version) (\(build))" }

    /// "1.1.0+4": Sentry's `releaseName`.
    var sentryRelease: String { "\(version)+\(build)" }
}

nonisolated extension Bundle {
    /// This bundle's marketing version and build.
    var appVersion: AppVersion { AppVersion(infoDictionary: infoDictionary) }
}
