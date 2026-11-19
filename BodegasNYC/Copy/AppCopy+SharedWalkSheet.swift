import Foundation

// MARK: - Shared Walk sheet (#177 PR 2, design DS7)

nonisolated extension AppCopy {
    /// What the person who opens a walk link reads: the design review's
    /// copy table (DS7), PR 2's rows. No string names the app; "the app" is
    /// as close as it gets.
    nonisolated enum ReceivedWalk: CaseIterable, Hashable, Sendable {
        /// The sheet's inline title.
        case title
        /// The map's VoiceOver label.
        case mapLabel
        /// On the map ground while the street data loads, with a trailing
        /// ellipsis (`withTrailingEllipsis`).
        case loadingMap
        /// The street data did not load; Retry beside it.
        case streetMapFailed
        /// Past the run cap.
        case zoomIn
        /// The last footnote: closing discards the walk.
        case notSaved
        /// No block in the link is in this street file.
        case noneDrawable
        /// A link format newer than this version reads.
        case needsUpdate
        /// A link that does not decode.
        case damaged
        /// The row that opens the App Store page.
        case update

        var copy: CopyString {
            switch self {
            case .title: CopyString(kind: .label, text: "Shared Walk")
            case .mapLabel: CopyString(kind: .body, text: "Map of a shared walk.")
            case .loadingMap: CopyString(kind: .value, text: "Loading the map")
            case .streetMapFailed: CopyString(kind: .body, text: "The street map didn't load. Try again.")
            case .zoomIn: CopyString(kind: .title, text: "Zoom in to see the blocks.")
            case .notSaved: CopyString(kind: .body, text: "This walk isn't saved. Open the link to see it again.")
            case .noneDrawable:
                CopyString(
                    kind: .body,
                    text: "None of these blocks can be shown yet. Update the app, then tap the link again."
                )
            case .needsUpdate:
                CopyString(
                    kind: .body,
                    text: "This walk needs a newer version of the app. Update, then tap the link again."
                )
            case .damaged: CopyString(kind: .body, text: "This link couldn't be opened. Ask them to send it again.")
            case .update: CopyString(kind: .label, text: "Update")
            }
        }

        /// The text with a trailing "…" (a status still in progress).
        var withTrailingEllipsis: String {
            copy.text + "\u{2026}"
        }
    }

    /// The sender's new blocks on the sheet (DS7): "6 new to them". The
    /// views omit it at zero.
    static func sharedWalkNewToThem(_ count: Int) -> CopyString {
        CopyString(kind: .value, text: "\(walkDayNew(count).text) to them")
    }

    /// The coverage line (eng E8, DS7): "32 of 38 blocks shown. Update the
    /// app to see the rest.", when this street file knows fewer blocks than
    /// the link holds.
    static func sharedWalkCoverage(shown: Int, of total: Int) -> CopyString {
        CopyString(
            kind: .body,
            text: "\(groupedCount(shown)) of \(walkDayBlocks(total).text) shown. Update the app to see the rest."
        )
    }

    /// The map's VoiceOver value (design Accessibility): "November 3 to
    /// November 9, 2026, 38 blocks, 6 new to them, 2.1 miles.", then
    /// "estimate" and "some blocks not shown" when they apply.
    static func sharedWalkMapValue(_ walk: SharedWalk, someNotShown: Bool) -> CopyString {
        var parts = [sharedWalkSpokenDates(first: walk.firstDay, last: walk.lastDay)]
        parts.append(walkDayBlocks(walk.blockCount).text)
        if walk.newCount > 0 { parts.append(sharedWalkNewToThem(walk.newCount).text) }
        parts.append(walkDayDistance(meters: Double(walk.meters)).text)
        if walk.isEstimate { parts.append("estimate") }
        if someNotShown { parts.append("some blocks not shown") }
        return CopyString(kind: .body, text: parts.joined(separator: ", ") + ".")
    }
}
