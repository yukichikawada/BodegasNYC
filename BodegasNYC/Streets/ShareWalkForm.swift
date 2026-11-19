import Foundation

/// The Share a Walk form's state (#177 design DS4's state table), pure so
/// it is tested without a view: the dates, the walk they hold, and whether
/// the picture on show is the one for them.
///
/// Dates are New York walk days from the first walked day through today;
/// moving From past To drags To along. A picture is made for one request
/// (the dates and the history's version) and freezes its `SharedWalk`;
/// Share is enabled only while the picture shown is for the current
/// request, so a date or history change disables it until the new picture
/// is ready, and what is sent is what was shown.
struct ShareWalkForm {
    /// What a picture is made for.
    struct Request: Hashable {
        let first: WalkedDayKey
        let last: WalkedDayKey
        let historyVersion: Int
    }

    enum Phase: Equatable {
        /// The picture for the current dates is being made (first open,
        /// each date change, a history change): the last picture at 40%,
        /// Share disabled.
        case making
        /// The picture is the current dates'; Share enabled.
        case ready
        /// The snapshot failed or took over 5 s: Retry, Share disabled.
        case failed
        /// No walked block in range: no picture, Share disabled.
        case noBlocks
        /// Over `maxBlocks`: no picture, Share disabled.
        case tooManyBlocks
    }

    /// The most blocks one share holds (#177 eng E5): the largest set
    /// measured on a phone (DESIGN.md decisions log, 2026-10-23).
    static let maxBlocks = 5_000

    private(set) var history: WalkedHistory
    let today: WalkedDayKey
    private(set) var start: WalkedDayKey
    private(set) var end: WalkedDayKey
    /// The current dates' walk, recomputed on every change.
    private(set) var walk: SharedWalk
    /// The last picture made and what it was made for; kept, dimmed, while
    /// the next one is made.
    private(set) var picture: SharedWalkPicture?
    private var pictureRequest: Request?
    private var failedRequest: Request?
    /// Bumped by Retry, so the view asks again for the same request.
    private(set) var attempt = 0

    /// Preset to `day` (a walked day, or Your Walks' most recent one),
    /// clamped into the allowed days. `nil` when the history has no walked
    /// day, so there is nothing to share.
    init?(history: WalkedHistory, preset day: WalkedDayKey, today: WalkedDayKey) {
        guard let first = history.walkedDays.first?.day else { return nil }
        self.history = history
        self.today = max(today, first)
        let preset = min(max(day, first), self.today)
        start = preset
        end = preset
        walk = history.shareSummary(from: preset, to: preset)
    }

    /// The first walked day: the earliest either date can be.
    var firstDay: WalkedDayKey { history.walkedDays.first?.day ?? today }

    var request: Request {
        Request(first: start, last: end, historyVersion: history.version)
    }

    var phase: Phase {
        if walk.blockIDs.isEmpty { return .noBlocks }
        if walk.blockCount > Self.maxBlocks { return .tooManyBlocks }
        if pictureRequest == request, picture != nil { return .ready }
        if failedRequest == request { return .failed }
        return .making
    }

    var canShare: Bool { phase == .ready }

    /// What Share sends: the picture on show, only while it is current.
    var shareablePicture: SharedWalkPicture? { canShare ? picture : nil }

    /// The line above a disabled Share, also its VoiceOver hint.
    var disabledReason: AppCopy.ShareWalk? {
        switch phase {
        case .noBlocks: .noBlocks
        case .tooManyBlocks: .tooManyBlocks
        case .failed: .pictureFailed
        case .making, .ready: nil
        }
    }

    /// From moves anywhere in the allowed days; past To, To follows.
    mutating func setFrom(_ day: WalkedDayKey) {
        start = clamp(day, lower: firstDay)
        if end < start { end = start }
        recompute()
    }

    /// To moves from From through today.
    mutating func setTo(_ day: WalkedDayKey) {
        end = clamp(day, lower: start)
        recompute()
    }

    /// A newer history (a pass while the form is open): the walk is
    /// recomputed and the picture remade. Returns `false` when the history
    /// has no walked day left (Clear History), so the form closes.
    mutating func historyChanged(_ newHistory: WalkedHistory) -> Bool {
        guard !newHistory.walkedDays.isEmpty else { return false }
        history = newHistory
        start = clamp(start, lower: firstDay)
        end = clamp(end, lower: start)
        recompute()
        return true
    }

    /// The picture for `request` is in; dropped when the dates or history
    /// have moved on since it was asked for.
    mutating func pictureMade(_ result: SharedWalkCard.Result, for made: Request) {
        guard made == request else { return }
        switch result {
        case .picture(let new):
            picture = new
            pictureRequest = made
            failedRequest = nil
        case .failed:
            failedRequest = made
        }
    }

    /// Retry after a failure: making again.
    mutating func retry() {
        failedRequest = nil
        attempt += 1
    }

    private func clamp(_ day: WalkedDayKey, lower: WalkedDayKey) -> WalkedDayKey {
        min(max(day, lower), today)
    }

    private mutating func recompute() {
        walk = history.shareSummary(from: start, to: end)
    }
}
