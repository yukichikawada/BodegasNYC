import Foundation

// MARK: - Walk history file (#180, design review)

nonisolated extension AppCopy {
    /// Export and (PR 2) import of walk history as a file: the design
    /// review's copy table. No string names the app (design D4); the file's
    /// own name is `WalkHistoryFile.fileNamePrefix`, outside `AppCopy`.
    nonisolated enum HistoryFile: CaseIterable, Hashable, Sendable {
        /// The Streets Walked menu item, shown through `menuItemWithEllipsis`
        /// (it opens a confirmation, design D11).
        case exportMenuItem
        /// The menu item's VoiceOver hint.
        case exportMenuHint
        /// The export confirmation (design DS2).
        case exportConfirmTitle
        case exportConfirmBody
        case exportAction
        /// Announced from 0.5 s into an export (design D7).
        case exportAnnouncement
        /// The failure alert's title (design D7); Retry and Cancel beside it.
        case exportFailed
        /// Clear History's confirmation (design DS3): opens the export
        /// confirmation instead of deleting.
        case exportFirstAction

        var copy: CopyString {
            switch self {
            case .exportMenuItem: CopyString(kind: .label, text: "Export History")
            case .exportMenuHint: CopyString(kind: .body, text: "Saves your walks to a file.")
            case .exportConfirmTitle: CopyString(kind: .title, text: "Export your walked history?")
            case .exportConfirmBody:
                CopyString(
                    kind: .body,
                    text: "The file holds everywhere you walked and when, to the second. It isn't locked. "
                        + "Anyone who gets it can read it."
                )
            case .exportAction: CopyString(kind: .label, text: "Export History")
            case .exportAnnouncement: CopyString(kind: .body, text: "Making the file.")
            case .exportFailed: CopyString(kind: .title, text: "The file didn't come out.")
            case .exportFirstAction: CopyString(kind: .label, text: "Export First")
            }
        }

        /// The menu text with a trailing "…" (it opens a confirmation).
        var menuItemWithEllipsis: String {
            copy.text + "\u{2026}"
        }
    }

    /// The export dialog's extra line when the history comes as more than
    /// one file (design D12): "It comes as 2 files. Keep them together and
    /// import each one."
    static func historyFileParts(_ count: Int) -> CopyString {
        CopyString(
            kind: .body,
            text: "It comes as \(groupedCount(count)) files. Keep them together and import each one."
        )
    }
}
