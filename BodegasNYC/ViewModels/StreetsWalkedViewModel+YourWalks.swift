import Foundation

// Your Walks (#170 PR 1): the history comes from `BlockMatchingActor`, read
// after every pass while the sheet is open; nothing here fetches from
// SwiftData on the main actor (spec AC 8).
extension StreetsWalkedViewModel {
    /// Your Walks opened: the street data loads even with no history (as
    /// for Your Blocks), and the refresh that follows reads the history.
    /// A previous result stays up meanwhile (DS8.2).
    func yourWalksDidOpen() {
        isYourWalksOpen = true
        scheduleRefresh(evenWithoutHistory: true)
    }

    func yourWalksDidClose() {
        isYourWalksOpen = false
    }

    /// Reads the history after any queued pass. Publishes only when its
    /// `version` moved (eng A3), so a pass that changed no day writes no
    /// state. A read that a Clear History overtook is dropped: the Clear
    /// reads again itself.
    func loadWalksHistory() async {
        let generation = matcher.generation
        let outcome = await matcher.history()
        guard matcher.generation == generation else { return }
        switch outcome {
        case .ready(let history):
            walksHistoryFailed = false
            if history.version != walksHistory?.version || walksHistory == nil { walksHistory = history }
        case .failed:
            walksHistoryFailed = true
        case .unavailable:
            break
        }
    }

    /// One day's runs for its map, built off the main actor (eng A5).
    func walkDayRuns(_ day: WalkedDayKey) async -> [WalkedRun] {
        await matcher.dayRuns(day)
    }

    /// The Progress chart's data (PR 2, DS6), from the history already read,
    /// with Your Blocks' citywide count as the headline once a count has
    /// run; `nil` before the first history read.
    func walkProgress(now: Date = Date()) -> WalkProgress? {
        guard let walksHistory else { return nil }
        let citywide = hasCounted ? boroughProgress.reduce(0) { $0 + $1.walked } : nil
        return WalkProgress(history: walksHistory, citywideWalked: citywide, today: WalkedDayKey(date: now))
    }

    /// What the Your Walks sheet shows (DS2, DS8.2).
    func yourWalks(now: Date = Date()) -> YourWalksContent {
        YourWalksContent(
            countState: countState,
            hasHistory: hasHistory,
            history: walksHistory,
            historyFailed: walksHistoryFailed,
            isRecording: recordingState == .recording,
            pausedProblem: recordingState.pausedProblem,
            now: now,
            layout: YourWalksContent.layoutCalendar
        )
    }
}
