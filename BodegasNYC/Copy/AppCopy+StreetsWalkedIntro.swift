import Foundation

// MARK: - Streets Walked intro sheet (#126 design D7)

nonisolated extension AppCopy {
    /// The Streets Walked intro sheet and its menu row. A nested enum like
    /// `YourBlocks`: `AppCopy`'s body sits at SwiftLint's type length. Reused
    /// from elsewhere: `startRecordingAction`, `doneAction`,
    /// `YourBlocks.recordingPaused`, `YourBlocks.openSettings`, and the
    /// paused problem's own `RecorderProblem.body`.
    nonisolated enum StreetsWalkedIntro: CaseIterable, Hashable, Sendable {
        /// The sheet's inline navigation title.
        case title
        /// Display register, header.
        case headline
        case whatItDoes
        /// `.headline` `.primary`, header, over the permission paragraph.
        case permissionHeading
        /// The permission paragraph by authorization status (`.primary`).
        case permissionNotDetermined
        case permissionWhenInUse
        case permissionDenied
        case permissionRestricted
        case permissionAlways
        case findItLater
        /// The status line on reopen while recording (`textMuted`).
        case recordingOn
        case notNowAction
        /// The Streets Walked menu row that reopens the sheet.
        case menuItem

        var copy: CopyString {
            switch self {
            case .title: CopyString(kind: .label, text: "Streets Walked")
            case .headline: CopyString(kind: .title, text: "The blocks you walk, drawn in.")
            case .whatItDoes:
                CopyString(
                    kind: .body,
                    text: "Recording is off by default. Walk most of a block with recording on, "
                        + "and it appears on your map. Your walks stay on this phone."
                )
            case .permissionHeading: CopyString(kind: .title, text: "Recording needs location set to Always.")
            case .permissionNotDetermined:
                CopyString(
                    kind: .body,
                    text: "Tap Allow While Using App first. iOS asks about Always later, on its own clock. "
                        + "Tap Change to Always Allow then, or recording pauses whenever you leave the app."
                )
            case .permissionWhenInUse:
                CopyString(
                    kind: .body,
                    text: "If iOS asks, tap Change to Always Allow. If it doesn't, set location to Always in "
                        + "Settings. Until then recording pauses whenever you leave the app."
                )
            case .permissionDenied:
                CopyString(
                    kind: .body,
                    text: "Location is off, for this app or the whole phone. Start Recording saves your choice. "
                        + "Set it to Always in Settings and recording starts."
                )
            case .permissionRestricted:
                CopyString(
                    kind: .body,
                    text: "Location is restricted on this phone. Recording can't run while that's the case."
                )
            case .permissionAlways:
                CopyString(kind: .body, text: "Location is set to Always. iOS may still ask you to confirm it later.")
            case .findItLater:
                CopyString(
                    kind: .body,
                    text: "It lives under Streets Walked, the walking figure in the map's toolbar."
                )
            case .recordingOn: CopyString(kind: .body, text: "Recording is on.")
            case .notNowAction: CopyString(kind: .label, text: "Not Now")
            case .menuItem: CopyString(kind: .label, text: "How Streets Walked Works")
            }
        }
    }
}
