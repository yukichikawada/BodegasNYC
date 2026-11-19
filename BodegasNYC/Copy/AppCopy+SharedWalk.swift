import Foundation

// MARK: - Share a Walk (#177 PR 1, design DS4 to DS7)

nonisolated extension AppCopy {
    /// The Share a Walk strings (`ShareWalk`, apart from the `SharedWalk`
    /// value), nested like `YourWalks`: one case per
    /// string, an exhaustive `copy`, and `allCases` in `AppCopyVoiceTests`.
    /// Wording is the design review's copy table (DS7), PR 1's consequence
    /// line. No string names the app: "My Bodegas" is drawn into the picture
    /// only (`SharedWalkCard.appName`), outside `AppCopy`.
    nonisolated enum ShareWalk: CaseIterable, Hashable, Sendable {
        /// The form's title and the entry buttons' VoiceOver label.
        case title
        /// The entry buttons' VoiceOver hint.
        case entryHint
        /// The form's date rows and its button.
        case fromLabel
        case toLabel
        case shareAction
        /// Under the dates (`.footnote` `textMuted`).
        case definition
        /// The three consequence lines (`.subheadline` `.primary`).
        case consequenceWhatGoes
        case consequenceStartAndEnd
        case consequencePassedOn
        /// Why Share is disabled, directly above it and its VoiceOver hint.
        case noBlocks
        case tooManyBlocks
        /// While the picture is made, with a trailing ellipsis
        /// (`withTrailingEllipsis`).
        case makingPicture
        /// The snapshot failed or took over 5 s.
        case pictureFailed
        /// On the form and in the picture when a day in range is an estimate.
        case estimate
        /// The picture's one VoiceOver element.
        case pictureLabel
        /// The walk maps' VoiceOver actions (DS6).
        case zoomIn
        case zoomOut
        case showWholeWalk

        var copy: CopyString {
            switch self {
            case .title: CopyString(kind: .label, text: "Share a Walk")
            case .entryHint: CopyString(kind: .body, text: "Picks days to send.")
            case .fromLabel: CopyString(kind: .label, text: "From")
            case .toLabel: CopyString(kind: .label, text: "To")
            case .shareAction: CopyString(kind: .label, text: "Share")
            case .definition:
                CopyString(kind: .body, text: "Blocks count once across these days. Miles include repeats.")
            case .consequenceWhatGoes:
                CopyString(
                    kind: .body,
                    text: "This sends a picture of the blocks you walked on these days, "
                        + "with the dates, counts and distance. No times of day."
                )
            case .consequenceStartAndEnd:
                CopyString(kind: .body, text: "The map can show where your walks start and end.")
            case .consequencePassedOn:
                CopyString(kind: .body, text: "Anyone who gets it can pass it on. It can't be taken back.")
            case .noBlocks: CopyString(kind: .body, text: "No blocks counted on these days.")
            case .tooManyBlocks:
                CopyString(kind: .body, text: "Too many blocks to share at once. Pick fewer days.")
            case .makingPicture: CopyString(kind: .value, text: "Making the picture")
            case .pictureFailed: CopyString(kind: .body, text: "The picture didn't come out. Try again.")
            case .estimate: CopyString(kind: .body, text: "Some of this is an estimate. Rides may be counted.")
            case .pictureLabel: CopyString(kind: .body, text: "Map of the walk you're sharing.")
            case .zoomIn: CopyString(kind: .label, text: "Zoom In")
            case .zoomOut: CopyString(kind: .label, text: "Zoom Out")
            case .showWholeWalk: CopyString(kind: .label, text: "Show Whole Walk")
            }
        }

        /// The text with a trailing "…" (a status still in progress).
        var withTrailingEllipsis: String {
            copy.text + "\u{2026}"
        }
    }
}

/// A shared walk's dates and counts are data, so these are templates; the
/// voice test runs them over every range shape. Dates are New York walk
/// days in a fixed `en_US` locale, as Your Walks' are.
nonisolated extension AppCopy {
    /// The en dash between a range's two ends, unspaced (DS7).
    static let dateRangeDash = "\u{2013}"

    /// A range of walk days as a `.value` (DS7): "Nov 3, 2026" for one day,
    /// "Nov 3–9, 2026", "Nov 28–Dec 2, 2026", "Dec 30, 2026–Jan 2, 2027".
    /// The cross-month and cross-year shapes run past a value's four words;
    /// `AppCopyVoiceTests.sharedWalkDateCopy` holds them to every other rule.
    static func sharedWalkDates(first: WalkedDayKey, last: WalkedDayKey) -> CopyString {
        let text: String
        if first == last {
            text = walkDayTitle(first).text
        } else if first.year != last.year {
            text = walkDayTitle(first).text + dateRangeDash + walkDayTitle(last).text
        } else if first.month != last.month {
            text = "\(shortMonth(first)) \(first.day)\(dateRangeDash)\(shortMonth(last)) \(last.day), \(last.year)"
        } else {
            text = "\(shortMonth(first)) \(first.day)\(dateRangeDash)\(last.day), \(last.year)"
        }
        return CopyString(kind: .value, text: text)
    }

    /// The same range as VoiceOver reads it (DS7): "November 3, 2026",
    /// "November 3 to November 9, 2026", "December 30, 2026 to January 2,
    /// 2027". A fragment, spoken inside `sharedWalkPictureValue`.
    static func sharedWalkSpokenDates(first: WalkedDayKey, last: WalkedDayKey) -> String {
        guard first != last else { return "\(longMonth(first)) \(first.day), \(first.year)" }
        if first.year != last.year {
            return "\(longMonth(first)) \(first.day), \(first.year) to \(longMonth(last)) \(last.day), \(last.year)"
        }
        return "\(longMonth(first)) \(first.day) to \(longMonth(last)) \(last.day), \(last.year)"
    }

    /// The picture's VoiceOver value (design Accessibility): "November 3 to
    /// November 9, 2026, 38 blocks, 6 new, 2.1 miles.", with "estimate" at
    /// the end when a day in range is one.
    static func sharedWalkPictureValue(_ walk: SharedWalk) -> CopyString {
        var parts = [sharedWalkSpokenDates(first: walk.firstDay, last: walk.lastDay)]
        parts += sharedWalkCountParts(walk)
        if walk.isEstimate { parts.append("estimate") }
        return CopyString(kind: .body, text: parts.joined(separator: ", ") + ".")
    }

    /// The share sheet's text item (DS5): "38 blocks, 6 new, 2.1 miles.
    /// Nov 3–9, 2026.", with "new" left out at zero.
    static func sharedWalkText(_ walk: SharedWalk) -> CopyString {
        let counts = sharedWalkCountParts(walk).joined(separator: ", ")
        let dates = sharedWalkDates(first: walk.firstDay, last: walk.lastDay).text
        return CopyString(kind: .body, text: "\(counts). \(dates).")
    }

    /// The picture's title in the share sheet's header (DS5): "Walk, Nov
    /// 3–9, 2026", so it does not read "PNG Image".
    static func sharedWalkLinkTitle(_ walk: SharedWalk) -> CopyString {
        CopyString(kind: .value, text: "Walk, " + sharedWalkDates(first: walk.firstDay, last: walk.lastDay).text)
    }

    /// The picture's second line (DS2): "6 new · 2.1 miles", or "2.1 miles"
    /// with no new block. Two values joined by the Your Walks separator.
    static func sharedWalkPictureCounts(_ walk: SharedWalk) -> String {
        var parts: [String] = []
        if walk.newCount > 0 { parts.append(walkDayNew(walk.newCount).text) }
        parts.append(walkDayDistance(meters: Double(walk.meters)).text)
        return parts.joined(separator: walksSeparator)
    }

    /// "38 blocks", "6 new" (omitted at zero), "2.1 miles".
    private static func sharedWalkCountParts(_ walk: SharedWalk) -> [String] {
        var parts = [walkDayBlocks(walk.blockCount).text]
        if walk.newCount > 0 { parts.append(walkDayNew(walk.newCount).text) }
        parts.append(walkDayDistance(meters: Double(walk.meters)).text)
        return parts
    }

    private static func shortMonth(_ day: WalkedDayKey) -> String {
        day.noon.formatted(sharedWalkDateStyle.month(.abbreviated))
    }

    private static func longMonth(_ day: WalkedDayKey) -> String {
        day.noon.formatted(sharedWalkDateStyle.month(.wide))
    }

    private static var sharedWalkDateStyle: Date.FormatStyle {
        Date.FormatStyle(
            locale: Locale(identifier: "en_US"),
            calendar: WalkedDayKey.calendar,
            timeZone: WalkedDayKey.timeZone
        )
    }
}
