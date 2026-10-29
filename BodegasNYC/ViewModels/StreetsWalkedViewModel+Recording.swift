import UIKit

// Recording's presentation (#123 design DS3 to DS7): off, recording or
// paused for one problem, read the same way by the map card, the menu and
// Your Blocks.
extension StreetsWalkedViewModel {
    enum RecordingState: Equatable {
        case off
        case recording
        /// The intent is on, but `problem` keeps recording from happening.
        case paused(RecorderProblem)

        var pausedProblem: RecorderProblem? {
            if case .paused(let problem) = self { return problem }
            return nil
        }
    }

    /// Off without the intent; paused by the first problem that pauses
    /// (a failed save does not: recording keeps going); else recording.
    var recordingState: RecordingState {
        guard recorder.isEnabled else { return .off }
        if let problem = recorder.problems.filter(\.pausesRecording).min() {
            return .paused(problem)
        }
        return .recording
    }

    /// The problem the map's recorder card shows: the top one, unless it
    /// was closed (design DS5).
    var cardProblem: RecorderProblem? {
        guard let problem = recorder.topProblem, problem != dismissedRecorderProblem else { return nil }
        return problem
    }

    /// The card's close: hides it for this problem only.
    func dismissRecorderCard() {
        dismissedRecorderProblem = recorder.topProblem
    }

    /// Start Recording when the answer was not Always (design DS4): no jump
    /// to Settings; the intent is saved and the card says what is needed.
    func saveRecordingIntent() {
        recorder.enable()
        scheduleRefresh()
    }

    /// A change of the recorder's top problem: a closed card comes back
    /// once its problem changes (DS5), and, while a window is active,
    /// VoiceOver hears the new card's title or "Recording again." (DS7).
    func recorderProblemChanged(from old: RecorderProblem?, to new: RecorderProblem?) {
        if new != dismissedRecorderProblem { dismissedRecorderProblem = nil }
        guard isSceneActive else { return }
        if let new {
            announce(new.title.copy.text)
        } else if old?.pausesRecording == true, recorder.isRecording {
            announce(AppCopy.Recorder.resumedAnnouncement.copy.text)
        }
    }

    static func postAnnouncement(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
