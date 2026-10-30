import CoreLocation

/// The one-time Streets Walked intro (#126): when the map may offer it, and
/// what the sheet says. Pure, so the gate and the copy table are unit-tested;
/// `MapScreenView` hosts the delay (`.task(id: inputs)`) and the sheet (eng
/// D1). Main-actor like `StreetsWalkedViewModel.RecordingState`, which it
/// reads.
enum StreetsWalkedIntro {
    /// Everything the gate reads. A change of any of them restarts the
    /// presentation delay (it is the `.task` id).
    struct Inputs: Equatable {
        var hasSeenIntro: Bool
        /// The map is the frontmost thing in this window: the Map tab,
        /// nothing pushed or presented by `BrowseView`, no Use Current
        /// Location wait, the onboarding overlay gone.
        var isForeground: Bool
        /// This window's scene is active (eng D2).
        var isSceneActive: Bool
        var isPlacingBodega: Bool
        /// A new pin is pending or dropping, or the first-add card is up
        /// (`MapScreenView.ignoresLocateMe`, eng O1).
        var isFirstAddInProgress: Bool
        /// Your Blocks or the Clear History confirmation is up: the map's
        /// own presentations, which the intro's sheet sits beside.
        var isOwnSheetUp: Bool
        /// A location prompt is up or awaited
        /// (`LocationPermissionClient.hasPendingAuthorizationRequest`).
        var isAwaitingLocationPrompt: Bool
        /// The camera is moving; the delay restarts at the settle (design D9).
        var isCameraMoving: Bool
        var recordingState: StreetsWalkedViewModel.RecordingState
        var hasHistory: Bool
    }

    /// The map is quiet and the person has never met the feature.
    static func shouldOffer(_ inputs: Inputs) -> Bool {
        !inputs.hasSeenIntro && inputs.isForeground && inputs.isSceneActive && !inputs.isPlacingBodega
            && !inputs.isFirstAddInProgress && !inputs.isOwnSheetUp && !inputs.isAwaitingLocationPrompt
            && !inputs.isCameraMoving && inputs.recordingState == .off && !inputs.hasHistory
    }

    /// Recording (or paused) or history: this person already knows the
    /// feature, so the intro is marked seen and never auto-presents, even
    /// after a later Stop Recording or Clear History (spec item 1).
    static func alreadyKnowsFeature(_ inputs: Inputs) -> Bool {
        inputs.recordingState != .off || inputs.hasHistory
    }

    /// Whether the sheet's dismissal runs the menu's Start Recording path:
    /// only after a Start Recording tap, and only if recording is still off
    /// (another window may have started it meanwhile, AC7).
    static func startAfterDismiss(pending: Bool, recordingState: StreetsWalkedViewModel.RecordingState) -> Bool {
        pending && recordingState == .off
    }

    /// From the moment the gate holds to the sheet (design D9).
    static let presentationDelay: Duration = .milliseconds(1500)

    /// Both ways in, the automatic one and the menu row (eng D4): mark the
    /// intro seen, then present. The flag changing makes the gate fail, so a
    /// delay still armed elsewhere presents nothing.
    static func present(_ isPresented: inout Bool, firstRunState: FirstRunState?) {
        firstRunState?.markStreetsWalkedIntroSeen()
        isPresented = true
    }

    /// Below this much reading space the button bar scrolls with the page
    /// instead of pinning (design D8: AX sizes in compact height).
    static let minimumReadingHeight: Double = 200

    /// Whether the button bar pins to the bottom of a container
    /// `availableHeight` tall.
    static func pinsButtonBar(availableHeight: Double, barHeight: Double) -> Bool {
        availableHeight - barHeight >= minimumReadingHeight
    }
}

/// What the intro sheet shows (design D7): the status line under the
/// headline on reopen, the permission paragraph, and the button bar. The
/// headline, `whatItDoes`, the permission heading and `findItLater` are on
/// every state.
struct StreetsWalkedIntroContent: Equatable {
    enum Status: Equatable {
        /// "Recording is on.", `textMuted`.
        case recordingOn
        /// "Recording is paused. Your blocks stay.", `.primary`.
        case recordingPaused

        var copy: CopyString {
            switch self {
            case .recordingOn: AppCopy.StreetsWalkedIntro.recordingOn.copy
            case .recordingPaused: AppCopy.YourBlocks.recordingPaused.copy
            }
        }
    }

    /// The paragraph under the permission heading: by authorization status,
    /// or, while paused, the problem's own recorder line.
    enum Permission: Equatable {
        case status(AppCopy.StreetsWalkedIntro)
        case paused(AppCopy.Recorder)

        var copy: CopyString {
            switch self {
            case .status(let copy): copy.copy
            case .paused(let copy): copy.copy
            }
        }
    }

    enum Action: Equatable {
        /// `.borderedProminent`.
        case startRecording
        /// `.bordered`.
        case notNow
        /// `.borderedProminent`: the one primary action while paused (D6).
        case openSettings
    }

    let status: Status?
    let permission: Permission
    /// In bar order; empty means no bar (Done closes).
    let actions: [Action]

    /// The paused problem is the one in `recordingState`.
    static func make(
        recordingState: StreetsWalkedViewModel.RecordingState,
        authorizationStatus: CLAuthorizationStatus
    ) -> StreetsWalkedIntroContent {
        switch recordingState {
        case .off:
            StreetsWalkedIntroContent(
                status: nil,
                permission: .status(permissionCopy(authorizationStatus)),
                // Restricted can't record, so Start Recording would only
                // save an intent nothing can fulfil.
                actions: authorizationStatus == .restricted ? [.notNow] : [.startRecording, .notNow]
            )
        case .recording:
            StreetsWalkedIntroContent(
                status: .recordingOn,
                permission: .status(permissionCopy(authorizationStatus)),
                actions: []
            )
        case .paused(let problem):
            StreetsWalkedIntroContent(
                status: .recordingPaused,
                permission: .paused(problem.body),
                actions: problem.opensSettings ? [.openSettings] : []
            )
        }
    }

    static func permissionCopy(_ status: CLAuthorizationStatus) -> AppCopy.StreetsWalkedIntro {
        switch status {
        case .notDetermined: .permissionNotDetermined
        case .authorizedWhenInUse: .permissionWhenInUse
        case .denied: .permissionDenied
        case .restricted: .permissionRestricted
        case .authorizedAlways: .permissionAlways
        @unknown default: .permissionNotDetermined
        }
    }
}
