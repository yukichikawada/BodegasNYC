import Foundation

// MARK: - Usage and diagnostics (#147, design DS1)

nonisolated extension AppCopy {
    /// The Account menu's sharing switch. A nested enum (the `Account`
    /// shape), registered in `AppCopyVoiceTests.shippedCopy` by hand, since
    /// `AppCopy.allCases` does not reach it.
    nonisolated enum Telemetry: CaseIterable, Hashable, Sendable {
        /// "and", not "&": the label rule rejects an ampersand (DS1).
        case shareUsage

        var copy: CopyString {
            switch self {
            case .shareUsage: CopyString(kind: .label, text: "Share Usage and Diagnostics")
            }
        }
    }
}
