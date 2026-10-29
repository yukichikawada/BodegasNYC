import Foundation

// Motion & Fitness asks and Your Blocks (#108, design D6 to D8, eng R2).
extension StreetsWalkedViewModel {
    /// Where the block counts stand (design D8).
    enum CountState: Equatable {
        /// Nothing asked yet (no history, recording off: the street data
        /// never loads).
        case idle
        /// A pass is running; the last overlay and counts stay up.
        case counting
        case ready
        /// The first count and its one retry failed (#113); the next refresh
        /// tries again.
        case failed
        /// The bundled street data did not load (eng R5).
        case unavailable
    }

    /// Asks for Motion & Fitness once, ever (design D6): right after Start
    /// Recording succeeds and the location dialogs have closed. Never on map
    /// open, rebuild or resume; the matcher's queries never prompt.
    func requestMotionAccessIfNeeded() async {
        guard motion.authorization == .notDetermined,
              !userDefaults.bool(forKey: Self.motionAskedDefaultsKey)
        else { return }
        userDefaults.set(true, forKey: Self.motionAskedDefaultsKey)
        await motion.requestAuthorization()
        refreshMotionAuthorization()
    }

    /// Your Blocks' Allow Motion Access row (design D6): for someone already
    /// recording who was never asked. An explicit tap, so it asks even if
    /// the one-time ask after Start Recording was already spent.
    func requestMotionAccess() async {
        guard motion.authorization == .notDetermined else {
            refreshMotionAuthorization()
            return
        }
        userDefaults.set(true, forKey: Self.motionAskedDefaultsKey)
        await motion.requestAuthorization()
        refreshMotionAuthorization()
    }

    /// Your Blocks opened (eng R2): counts are brought up to date, and the
    /// street data loads for the totals even with no history and recording
    /// off, since the person asked to see them. Motion & Fitness is re-read
    /// for the Allow Motion Access row.
    func yourBlocksDidOpen() {
        refreshMotionAuthorization()
        scheduleRefresh(evenWithoutHistory: true)
    }

    /// What the Your Blocks sheet shows (design D7, D8, D6).
    var yourBlocks: YourBlocksContent {
        YourBlocksContent(
            countState: countState,
            hasCounted: hasCounted,
            progress: boroughProgress,
            isRecording: recordingState == .recording,
            pausedProblem: recordingState.pausedProblem,
            motion: motionAuthorization
        )
    }
}
