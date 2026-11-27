import Foundation

// MARK: - Walk history import (#180 PR 2, design review)

nonisolated extension AppCopy {
    /// Import of walk history from a file: the design review's copy table
    /// (D1 to D6, D9, D11, DS1, DS4). Its own enum beside `HistoryFile`
    /// (PR 1's export strings, whose table test pins its case count). No
    /// string names the app (design D4). In-progress strings are `.value`
    /// stored without the ellipsis (`withTrailingEllipsis`), each with a
    /// `.body` announcement twin (D14).
    nonisolated enum HistoryImport: CaseIterable, Hashable, Sendable {
        /// The Streets Walked menu item, shown through `menuItemWithEllipsis`
        /// (D11), and the sheet's inline title (D1).
        case menuItem
        case menuHint
        /// The preview's heading.
        case heading
        case partlyHere
        case skippedEntries
        /// D3: when a new fix carries no ride evidence.
        case estimates
        /// #203: always on the preview, above the consequence.
        case ownWalks
        /// D2: always on the preview.
        case consequence
        /// A11's known limit, as the preview's footer.
        case footer
        case addAction
        case reading
        case readingAnnouncement
        case saving
        case savingAnnouncement
        case countingAnnouncement
        /// DS4.
        case done
        case showYourWalks
        case recordingOff
        case nothingNewTitle
        case nothingNewBody
        case noWalks
        case nothingReadable
        case wrongFile
        case newerFormat
        case tooLarge
        case readFailure
        case saveFailure
        case clearedMeanwhile
        case storeUnavailable
        /// D9: a second file replaced the one on screen.
        case replaced

        var copy: CopyString {
            switch self {
            case .menuItem: CopyString(kind: .label, text: "Import History")
            case .menuHint: CopyString(kind: .body, text: "Adds walks from a file.")
            case .heading: CopyString(kind: .title, text: "Add walks from this file?")
            case .partlyHere:
                CopyString(kind: .body, text: "Some of it is already on this phone. Only the rest is added.")
            case .skippedEntries:
                CopyString(kind: .body, text: "Part of the file couldn't be read. The rest comes in.")
            case .estimates:
                CopyString(
                    kind: .body,
                    text: "Days from a file show as estimates. This phone can't check them for rides."
                )
            case .ownWalks: CopyString(kind: .body, text: "Only add a file of your own walks.")
            case .consequence:
                CopyString(
                    kind: .body,
                    text: "They mix into your blocks, days and counts. Taking them out again means clearing everything."
                )
            case .footer: CopyString(kind: .body, text: "Walks recorded on two phones can count distance twice.")
            case .addAction: CopyString(kind: .label, text: "Add Walks")
            case .reading: CopyString(kind: .value, text: "Reading the file")
            case .readingAnnouncement: CopyString(kind: .body, text: "Reading the file.")
            case .saving: CopyString(kind: .value, text: "Adding your walks")
            case .savingAnnouncement: CopyString(kind: .body, text: "Adding your walks.")
            case .countingAnnouncement: CopyString(kind: .body, text: "Counting your blocks.")
            case .done: CopyString(kind: .body, text: "Your walks are in.")
            case .showYourWalks: CopyString(kind: .label, text: "Show Your Walks")
            case .recordingOff: CopyString(kind: .body, text: "Recording is off on this phone.")
            case .nothingNewTitle: CopyString(kind: .title, text: "Nothing new in this file.")
            case .nothingNewBody: CopyString(kind: .body, text: "Every walk in it is already on this phone.")
            case .noWalks: CopyString(kind: .body, text: "This file has no walks in it.")
            case .nothingReadable:
                CopyString(kind: .body, text: "Nothing in this file could be read. Nothing was added.")
            case .wrongFile: CopyString(kind: .body, text: "This isn't a walk history file.")
            case .newerFormat:
                CopyString(kind: .body, text: "This file is from a newer version of this app. Update, then import it.")
            case .tooLarge: CopyString(kind: .body, text: "This file is too large to import.")
            case .readFailure: CopyString(kind: .body, text: "The file couldn't be read. Open it again.")
            case .saveFailure: CopyString(kind: .body, text: "Those walks didn't save. Try again.")
            case .clearedMeanwhile: CopyString(kind: .body, text: "History was cleared, so nothing was added.")
            case .storeUnavailable: CopyString(kind: .body, text: "Streets Walked isn't available right now.")
            case .replaced: CopyString(kind: .body, text: "Another file opened.")
            }
        }

        /// The menu text with a trailing "…" (it opens a picker, D11).
        var menuItemWithEllipsis: String {
            copy.text + "\u{2026}"
        }

        /// A status still in progress, with "…". The voice rules check it
        /// without.
        var withTrailingEllipsis: String {
            copy.text + "\u{2026}"
        }
    }

    /// The preview's days line (design DS1): "84 days of recording", "1 day
    /// of recording". Days, never points.
    static func historyImportDays(_ count: Int) -> CopyString {
        CopyString(
            kind: .value,
            text: count == 1 ? "1 day of recording" : "\(groupedCount(count)) days of recording"
        )
    }
}
