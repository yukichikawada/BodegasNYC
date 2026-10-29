import Foundation

// MARK: - Streets Walked recorder problems (#123 design DS6, DS7)

/// Why Streets Walked is not recording, or (`saveFailed`) what went wrong
/// while it is (#123 design DS3). In display order: when several hold, the
/// first in this list is the one shown.
nonisolated enum RecorderProblem: Int, CaseIterable, Comparable, Hashable, Sendable {
    case restricted
    case denied
    /// Location Services is off for the whole phone.
    case servicesOff
    case preciseOff
    /// Location is While Using (or not yet decided), not Always.
    case needsAlways
    /// A fix did not save; recording keeps going.
    case saveFailed

    static func < (lhs: RecorderProblem, rhs: RecorderProblem) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Every problem but a failed save pauses recording (design DS3;
    /// Precise off pauses in practice, since reduced-accuracy fixes never
    /// pass the 50 m filter).
    var pausesRecording: Bool { self != .saveFailed }

    /// Whether Settings can fix it, so the card and Your Blocks offer Open
    /// Settings (design DS6).
    var opensSettings: Bool {
        switch self {
        case .needsAlways, .denied, .servicesOff, .preciseOff: true
        case .restricted, .saveFailed: false
        }
    }

    /// The SF Symbol in the card's symbol column (design DS6).
    var symbolName: String {
        switch self {
        case .needsAlways, .denied, .servicesOff, .restricted: "location.slash"
        case .preciseOff: "scope"
        case .saveFailed: "exclamationmark.triangle"
        }
    }

    var title: AppCopy.Recorder {
        switch self {
        case .needsAlways, .preciseOff: .pausedTitle
        case .denied, .servicesOff: .cantSeeYouTitle
        case .restricted: .notAllowedTitle
        case .saveFailed: .saveFailedTitle
        }
    }

    var body: AppCopy.Recorder {
        switch self {
        case .needsAlways: .needsAlwaysBody
        case .denied: .deniedBody
        case .servicesOff: .servicesOffBody
        case .restricted: .restrictedBody
        case .preciseOff: .preciseOffBody
        case .saveFailed: .saveFailedBody
        }
    }
}

nonisolated extension AppCopy {
    /// The recorder card, the menu's paused section and the resume
    /// announcement (#123 design DS6, DS7). A nested enum like `YourBlocks`:
    /// `AppCopy`'s body sits at SwiftLint's type length.
    nonisolated enum Recorder: CaseIterable, Hashable, Sendable {
        case pausedTitle
        case cantSeeYouTitle
        case notAllowedTitle
        case saveFailedTitle
        case needsAlwaysBody
        case deniedBody
        case servicesOffBody
        case restrictedBody
        case preciseOffBody
        case saveFailedBody
        /// The Streets Walked menu's section header while paused.
        case pausedSection
        /// VoiceOver, when recording resumes (design DS7).
        case resumedAnnouncement

        var copy: CopyString {
            switch self {
            case .pausedTitle: CopyString(kind: .title, text: "Recording paused.")
            case .cantSeeYouTitle: CopyString(kind: .title, text: "Recording can't see you.")
            case .notAllowedTitle: CopyString(kind: .title, text: "Recording isn't allowed here.")
            case .saveFailedTitle: CopyString(kind: .title, text: "That stretch didn't save.")
            case .needsAlwaysBody:
                CopyString(kind: .body, text: "Streets Walked needs location set to Always. Your blocks stay.")
            // DS6 has "Location is off for BodegasNYC."; the voice rules
            // never name the app, so "this app" stands in (the builder's one
            // permitted wording change).
            case .deniedBody: CopyString(kind: .body, text: "Location is off for this app. Your blocks stay.")
            case .servicesOffBody: CopyString(kind: .body, text: "Location Services is off for the whole phone.")
            case .restrictedBody:
                CopyString(kind: .body, text: "Location is restricted on this phone. Your blocks stay.")
            case .preciseOffBody: CopyString(kind: .body, text: "Blocks need Precise Location, and it's off.")
            case .saveFailedBody: CopyString(kind: .body, text: "Recording keeps going. Your other blocks are fine.")
            case .pausedSection: CopyString(kind: .label, text: "Recording Paused")
            case .resumedAnnouncement: CopyString(kind: .body, text: "Recording again.")
            }
        }
    }
}
