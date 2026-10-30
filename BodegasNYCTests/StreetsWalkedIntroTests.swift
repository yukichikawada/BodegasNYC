//
//  StreetsWalkedIntroTests.swift
//  BodegasNYCTests
//
//  The Streets Walked intro's pure decisions (#126): the gate, the
//  already-knows rule, the Start Recording handoff, the bar rule, and the
//  sheet's content table (design D7).
//
//  protects: the intro is offered only when every gate input says the map
//  is quiet (one row per input flips it off); recording, paused or history
//  marks it seen instead; Start Recording runs the menu path only when
//  tapped and still off; presenting marks the flag; the content table's
//  status line, permission paragraph and buttons for the four recording
//  states, the five authorization states and the paused override.
//  fails_when: any single input fails to block, an all-quiet map is not
//  offered, a Not Now dismissal or an already-on recording would start
//  recording, a manual open leaves the flag unset, or a row of the copy
//  table drifts (restricted offering Start Recording, paused losing Open
//  Settings, a missing status line).
//  no_claim: the 1.5 s timing, SwiftUI's `.task(id:)` cancellation and the
//  sheet's rendering (UI test and live QA); `BrowseView`'s foreground
//  composition (live QA).
//

import CoreLocation
import Foundation
import Testing

@testable import BodegasNYC

@MainActor
struct StreetsWalkedIntroTests {
    typealias Inputs = StreetsWalkedIntro.Inputs

    /// The map at its quietest: every input lets the intro through.
    static let quiet = Inputs(
        hasSeenIntro: false,
        isForeground: true,
        isSceneActive: true,
        isPlacingBodega: false,
        isFirstAddInProgress: false,
        isOwnSheetUp: false,
        isAwaitingLocationPrompt: false,
        isCameraMoving: false,
        recordingState: .off,
        hasHistory: false
    )

    /// One input flipped from `quiet`, named for the failure message.
    static let blockers: [(String, (inout Inputs) -> Void)] = [
        ("seen", { $0.hasSeenIntro = true }),
        ("not foreground", { $0.isForeground = false }),
        ("scene inactive", { $0.isSceneActive = false }),
        ("placing", { $0.isPlacingBodega = true }),
        ("first add", { $0.isFirstAddInProgress = true }),
        ("own sheet", { $0.isOwnSheetUp = true }),
        ("location prompt", { $0.isAwaitingLocationPrompt = true }),
        ("camera moving", { $0.isCameraMoving = true }),
        ("recording", { $0.recordingState = .recording }),
        ("paused", { $0.recordingState = .paused(.needsAlways) }),
        ("history", { $0.hasHistory = true })
    ]

    @Test func aQuietMapOffersTheIntro() {
        #expect(StreetsWalkedIntro.shouldOffer(Self.quiet))
        #expect(!StreetsWalkedIntro.alreadyKnowsFeature(Self.quiet))
    }

    @Test(arguments: 0..<11)
    func eachInputAloneBlocksTheIntro(_ index: Int) {
        let (name, flip) = Self.blockers[index]
        var inputs = Self.quiet
        flip(&inputs)
        #expect(!StreetsWalkedIntro.shouldOffer(inputs), "\(name) did not block")
    }

    @Test func recordingPausedOrHistoryMeansAlreadyKnown() {
        for state: StreetsWalkedViewModel.RecordingState in [.recording, .paused(.denied), .paused(.restricted)] {
            var inputs = Self.quiet
            inputs.recordingState = state
            #expect(StreetsWalkedIntro.alreadyKnowsFeature(inputs), "\(state)")
        }
        var withHistory = Self.quiet
        withHistory.hasHistory = true
        #expect(StreetsWalkedIntro.alreadyKnowsFeature(withHistory))
        // The rest of the gate never makes someone "already known".
        var busy = Self.quiet
        busy.isForeground = false
        busy.isCameraMoving = true
        #expect(!StreetsWalkedIntro.alreadyKnowsFeature(busy))
    }

    @Test func startAfterDismissNeedsTheTapAndRecordingOff() {
        #expect(StreetsWalkedIntro.startAfterDismiss(pending: true, recordingState: .off))
        // Not Now, Done, swipe-down.
        #expect(!StreetsWalkedIntro.startAfterDismiss(pending: false, recordingState: .off))
        // Another window started it meanwhile (AC7).
        #expect(!StreetsWalkedIntro.startAfterDismiss(pending: true, recordingState: .recording))
        #expect(!StreetsWalkedIntro.startAfterDismiss(pending: true, recordingState: .paused(.needsAlways)))
    }

    @Test func theDelayIsOneAndAHalfSeconds() {
        #expect(StreetsWalkedIntro.presentationDelay == .milliseconds(1500))
    }

    /// protects=a manual open (the menu row) and the automatic path both set
    /// the flag in the same call that presents, so an armed delay elsewhere
    /// fails its re-check (eng D4); fails_when=the flag stays false or the
    /// sheet flag is not set; no_claim=the menu row's wiring (UI test).
    @Test func presentingMarksTheIntroSeen() throws {
        let suiteName = "StreetsWalkedIntroTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = FirstRunState(userDefaults: defaults)
        var isPresented = false

        StreetsWalkedIntro.present(&isPresented, firstRunState: state)

        #expect(isPresented)
        #expect(state.hasSeenStreetsWalkedIntro)
        #expect(FirstRunState(userDefaults: defaults).hasSeenStreetsWalkedIntro)
        var armed = Self.quiet
        armed.hasSeenIntro = state.hasSeenStreetsWalkedIntro
        #expect(!StreetsWalkedIntro.shouldOffer(armed))
    }

    @Test func theBarPinsUnlessReadingSpaceFallsUnder200() {
        #expect(StreetsWalkedIntro.pinsButtonBar(availableHeight: 700, barHeight: 140))
        #expect(StreetsWalkedIntro.pinsButtonBar(availableHeight: 340, barHeight: 140))
        #expect(!StreetsWalkedIntro.pinsButtonBar(availableHeight: 339, barHeight: 140))
        // AX5 in landscape: the wrapped buttons eat the screen.
        #expect(!StreetsWalkedIntro.pinsButtonBar(availableHeight: 330, barHeight: 260))
    }

    // MARK: Content (design D7)

    private static let statuses: [CLAuthorizationStatus] = [
        .notDetermined, .authorizedWhenInUse, .denied, .restricted, .authorizedAlways
    ]

    @Test func offShowsNoStatusAndStartRecordingUnlessRestricted() {
        for status in Self.statuses {
            let content = StreetsWalkedIntroContent.make(recordingState: .off, authorizationStatus: status)
            #expect(content.status == nil, "\(status)")
            #expect(content.permission == .status(StreetsWalkedIntroContent.permissionCopy(status)))
            let expected: [StreetsWalkedIntroContent.Action] =
                status == .restricted ? [.notNow] : [.startRecording, .notNow]
            #expect(content.actions == expected, "\(status)")
        }
    }

    @Test func thePermissionParagraphFollowsTheAuthorizationStatus() {
        let table: [(CLAuthorizationStatus, String)] = [
            (.notDetermined, "Tap Allow While Using App first. iOS asks about Always later, on its own clock. "
                + "Tap Change to Always Allow then, or recording pauses whenever you leave the app."),
            (.authorizedWhenInUse, "If iOS asks, tap Change to Always Allow. If it doesn't, set location to Always "
                + "in Settings. Until then recording pauses whenever you leave the app."),
            (.denied, "Location is off, for this app or the whole phone. Start Recording saves your choice. "
                + "Set it to Always in Settings and recording starts."),
            (.restricted, "Location is restricted on this phone. Recording can't run while that's the case."),
            (.authorizedAlways, "Location is set to Always. iOS may still ask you to confirm it later.")
        ]
        for (status, text) in table {
            let content = StreetsWalkedIntroContent.make(recordingState: .off, authorizationStatus: status)
            #expect(content.permission.copy.text == text, "\(status)")
        }
    }

    @Test func recordingShowsRecordingIsOnAndNoButtons() {
        for status in Self.statuses {
            let content = StreetsWalkedIntroContent.make(recordingState: .recording, authorizationStatus: status)
            #expect(content.status == .recordingOn)
            #expect(content.status?.copy.text == "Recording is on.")
            #expect(content.actions.isEmpty)
            #expect(content.permission == .status(StreetsWalkedIntroContent.permissionCopy(status)))
        }
    }

    /// Paused: the problem's own recorder line overrides the status
    /// paragraph whatever the authorization says, and Open Settings shows
    /// only when Settings can fix the problem.
    @Test(arguments: RecorderProblem.allCases.filter(\.pausesRecording))
    func pausedUsesTheProblemsLineAndOpenSettingsWhenItHelps(_ problem: RecorderProblem) {
        for status in Self.statuses {
            let content = StreetsWalkedIntroContent.make(recordingState: .paused(problem), authorizationStatus: status)
            #expect(content.status == .recordingPaused)
            #expect(content.status?.copy.text == "Recording is paused. Your blocks stay.")
            #expect(content.permission == .paused(problem.body))
            #expect(content.actions == (problem.opensSettings ? [.openSettings] : []), "\(problem)")
        }
    }

    @Test func pausedRestrictedHasNoButtonAndNeedsAlwaysOpensSettings() {
        let restricted = StreetsWalkedIntroContent.make(
            recordingState: .paused(.restricted), authorizationStatus: .restricted
        )
        #expect(restricted.actions.isEmpty)
        #expect(restricted.permission.copy.text == "Location is restricted on this phone. Your blocks stay.")
        let needsAlways = StreetsWalkedIntroContent.make(
            recordingState: .paused(.needsAlways), authorizationStatus: .authorizedWhenInUse
        )
        #expect(needsAlways.actions == [.openSettings])
        #expect(
            needsAlways.permission.copy.text == "Streets Walked needs location set to Always. Your blocks stay."
        )
    }
}
