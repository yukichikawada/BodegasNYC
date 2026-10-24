import Foundation

// MARK: - Your Blocks (#108 PR 2, design D5 to D8, D11)

nonisolated extension AppCopy {
    /// The Your Blocks strings. A nested enum rather than more `AppCopy`
    /// cases because `AppCopy`'s body sits at SwiftLint's type length; it
    /// keeps the same contract: one case per string, an exhaustive `copy`,
    /// and `allCases` in `AppCopyVoiceTests`.
    nonisolated enum YourBlocks: CaseIterable, Hashable, Sendable {
        /// The menu item and the sheet's title.
        case title
        /// The menu item's VoiceOver hint (design D11).
        case menuHint
        case newYorkCity, manhattan, brooklyn, queens, bronx, statenIsland
        case footer
        /// Shown with a trailing ellipsis (`withTrailingEllipsis`), 0.5s into
        /// a first count (design D8).
        case countingStatus
        case recordingOff
        /// The street data did not load (eng R5, design D8); `.primary`.
        case streetMapUnavailable
        /// The first count failed twice (#113 item 5); `.primary`, in the
        /// street-map failure's place.
        case countFailed
        case motionDenied
        /// The Motion & Fitness row for people already recording (design D6).
        case allowMotionAccess
        case openSettings

        var copy: CopyString {
            switch self {
            case .title: CopyString(kind: .label, text: "Your Blocks")
            case .menuHint: CopyString(kind: .body, text: "Shows blocks walked in each borough.")
            case .newYorkCity: CopyString(kind: .value, text: "New York City")
            case .manhattan: CopyString(kind: .value, text: "Manhattan")
            case .brooklyn: CopyString(kind: .value, text: "Brooklyn")
            case .queens: CopyString(kind: .value, text: "Queens")
            case .bronx: CopyString(kind: .value, text: "Bronx")
            case .statenIsland: CopyString(kind: .value, text: "Staten Island")
            case .footer:
                CopyString(
                    kind: .body,
                    text: "A block counts once you've walked most of it. Your walks stay on this phone."
                )
            case .countingStatus: CopyString(kind: .value, text: "Counting your blocks")
            case .recordingOff: CopyString(kind: .body, text: "Recording is off. Your blocks stay.")
            case .streetMapUnavailable:
                CopyString(kind: .body, text: "The street map didn't load. Your walks are still saved.")
            case .countFailed:
                CopyString(kind: .body, text: "Your blocks couldn't be counted. Your walks are still saved.")
            case .motionDenied:
                CopyString(kind: .body, text: "Without Motion & Fitness, rides are filtered by speed only.")
            case .allowMotionAccess: CopyString(kind: .label, text: "Allow Motion Access")
            case .openSettings: CopyString(kind: .label, text: "Open Settings")
            }
        }

        /// The text with a trailing "…" (a status still in progress). The
        /// voice rules check it without.
        var withTrailingEllipsis: String {
            copy.text + "\u{2026}"
        }

        /// A place's name in the sheet: the city (`nil`), then the boroughs.
        static func place(_ borough: Borough?) -> YourBlocks {
            switch borough {
            case nil: .newYorkCity
            case .manhattan: .manhattan
            case .brooklyn: .brooklyn
            case .queens: .queens
            case .bronx: .bronx
            case .statenIsland: .statenIsland
            }
        }
    }
}

/// Counts are data, so these are templates; the voice test runs them over
/// fixtures covering zero, one, the "<1%" band and a full borough.
nonisolated extension AppCopy {
    /// A borough row's count (design D7): "412 of 9,300 blocks",
    /// "0 of 9,300 blocks".
    static func boroughBlockCount(walked: Int, total: Int) -> CopyString {
        CopyString(kind: .value, text: "\(grouped(walked)) of \(grouped(total)) blocks")
    }

    /// The citywide row's count (design D7) in two parts, the walked count
    /// and the total, which the sheet sets in `textMuted`: ("412 blocks",
    /// "of 99,360"), ("1 block", "of 99,360").
    static func citywideBlockCountParts(walked: Int, total: Int) -> (walked: String, total: String) {
        (walked == 1 ? "1 block" : "\(grouped(walked)) blocks", "of \(grouped(total))")
    }

    /// Both parts as one string, the form the voice test checks:
    /// "412 blocks of 99,360".
    static func citywideBlockCount(walked: Int, total: Int) -> CopyString {
        let parts = citywideBlockCountParts(walked: walked, total: total)
        return CopyString(kind: .value, text: "\(parts.walked) \(parts.total)")
    }

    /// A row's one VoiceOver element (design D11): "Manhattan, 412 of 9,300
    /// blocks, 4 percent.", "Queens, 3 of 37,882 blocks, less than 1
    /// percent.", or, while the first count runs, "Manhattan, counting.".
    static func yourBlocksRowLabel(_ borough: Borough?, walked: Int?, total: Int?) -> CopyString {
        let name = YourBlocks.place(borough).copy.text
        guard let walked, let total else {
            return CopyString(kind: .body, text: "\(name), counting.")
        }
        let percent = switch BoroughProgress.percent(walked: walked, total: total) {
        case .lessThanOne: "less than 1 percent"
        case .whole(let whole): "\(whole) percent"
        }
        return CopyString(kind: .body, text: "\(name), \(grouped(walked)) of \(grouped(total)) blocks, \(percent).")
    }

    /// The trailing percent: rounded down, "<1%" for any nonzero count under
    /// 1% (spec Implementation 7). A numeral with its sign, not voice: the
    /// spoken form is in `yourBlocksRowLabel`.
    static func percentText(_ percent: BoroughProgress.Percent) -> String {
        switch percent {
        case .lessThanOne: "<1%"
        case .whole(let whole): "\(whole)%"
        }
    }

    /// What a value shows while the first count runs (design D8). A glyph,
    /// not voice: VoiceOver hears "counting" (`yourBlocksRowLabel`).
    static let countingPlaceholder = "\u{2014}"

    /// Grouped in a fixed `en_US` locale (the app is English-only): "9,300".
    private static func grouped(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}
