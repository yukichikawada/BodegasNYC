import SwiftUI

// The one-time Streets Walked intro (#126, eng D1): the map hosts the gate
// and the sheet. The delay is a `.task` keyed by the gate's inputs, so any
// change cancels it and the next hold starts it again; there is no presenter
// object or clock.
extension MapScreenView {
    /// The gate's inputs, or `nil` when the feature is unavailable (no view
    /// model) or there is no first-run state (previews): then nothing is
    /// offered.
    var streetsWalkedIntroInputs: StreetsWalkedIntro.Inputs? {
        guard let firstRunState, let streetsWalkedViewModel else { return nil }
        return StreetsWalkedIntro.Inputs(
            hasSeenIntro: firstRunState.hasSeenStreetsWalkedIntro,
            isForeground: isForeground,
            isSceneActive: scenePhase == .active,
            isPlacingBodega: isPlacingBodega,
            isFirstAddInProgress: Self.ignoresLocateMe(
                dropState: addCompletion?.dropState ?? .none,
                hasFirstAddCard: addCompletion?.firstAddCard != nil
            ),
            isOwnSheetUp: showingYourBlocks || showingClearConfirmation,
            isAwaitingLocationPrompt: locationPermissionClient.hasPendingAuthorizationRequest,
            isCameraMoving: isCameraMoving,
            recordingState: streetsWalkedViewModel.recordingState,
            hasHistory: streetsWalkedViewModel.hasHistory
        )
    }

    /// The delay task and the sheet, wrapped around `content`.
    func streetsWalkedIntro(_ content: some View) -> some View {
        content
            .task(id: streetsWalkedIntroInputs) { await offerStreetsWalkedIntro() }
            .sheet(isPresented: $showingStreetsWalkedIntro, onDismiss: streetsWalkedIntroDidDismiss) {
                if let streetsWalkedViewModel {
                    StreetsWalkedIntroSheet(
                        viewModel: streetsWalkedViewModel,
                        locationPermissionClient: locationPermissionClient,
                        onStartRecording: { introStartsRecording = true }
                    )
                }
            }
    }

    /// Someone who already knows the feature is marked seen and never sees
    /// it; otherwise, if the gate holds, wait 1.5 s and present only if it
    /// still holds (design D9).
    private func offerStreetsWalkedIntro() async {
        guard let inputs = streetsWalkedIntroInputs, !inputs.hasSeenIntro else { return }
        if StreetsWalkedIntro.alreadyKnowsFeature(inputs) {
            firstRunState?.markStreetsWalkedIntroSeen()
            return
        }
        guard StreetsWalkedIntro.shouldOffer(inputs) else { return }
        guard (try? await Task.sleep(for: StreetsWalkedIntro.presentationDelay)) != nil else { return }
        guard let latest = streetsWalkedIntroInputs, StreetsWalkedIntro.shouldOffer(latest) else { return }
        presentStreetsWalkedIntro()
    }

    /// Both ways in, automatic and the menu row: marks the intro seen, then
    /// presents (eng D4).
    func presentStreetsWalkedIntro() {
        StreetsWalkedIntro.present(&showingStreetsWalkedIntro, firstRunState: firstRunState)
    }

    /// Not Now, Done, swipe-down and Start Recording all end here. Only a
    /// Start Recording tap, with recording still off, runs the menu's exact
    /// path, after the sheet is gone so the system prompt never stacks on
    /// it (AC6, AC7). A manual close returns VoiceOver to the Streets Walked
    /// control (design D8); after Start Recording the system alert takes it.
    private func streetsWalkedIntroDidDismiss() {
        let starts = StreetsWalkedIntro.startAfterDismiss(
            pending: introStartsRecording,
            recordingState: streetsWalkedViewModel?.recordingState ?? .off
        )
        introStartsRecording = false
        if starts {
            Task { await toggleStreetsWalked() }
        } else {
            isStreetsWalkedMenuFocused = true
        }
    }
}
