import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One window's walk history import UI (#180 PR 2): the file picker, the
/// store-unavailable alert and what happens when the import sheet closes.
/// The import itself is app-wide, on the view model (eng A4).
struct HistoryImportPresentation {
    var isPicking = false
    /// A file picked, waiting for the picker to finish going.
    var pickedURL: URL?
    /// A file opened with no Streets Walked store (spec validation table).
    var isShowingUnavailable = false
    /// Start Recording on the done state: the menu's path runs once the
    /// sheet has gone (design DS4).
    var startsRecordingAfterDismiss = false
    /// The import sheet was up: VoiceOver returns to the Streets Walked
    /// item when it closes (design D14).
    var focusesMenuAfterDismiss = false
}

// Import History… (design D11), the picker, and the incoming-file rules
// (design D8, D9, D13): a waiting file is claimed by a map window that is
// frontmost and active, replacing Your Blocks, Your Walks or the intro, and
// waiting behind anything else presented. Kept out of `MapScreenView.swift`,
// which is at its length limit.
extension MapScreenView {
    /// The menu item, under Export History… (D11): no icon, the label with
    /// an ellipsis, available with or without history, disabled while busy.
    func historyImportMenuItem(_ viewModel: StreetsWalkedViewModel) -> some View {
        Button(AppCopy.HistoryImport.menuItem.menuItemWithEllipsis) {
            historyImportUI.isPicking = true
        }
        .accessibilityHint(AppCopy.HistoryImport.menuHint.copy.text)
        .disabled(!viewModel.canImportHistory)
    }

    /// The picker, the claim of a waiting file, the sheet's owner sync and
    /// the unavailable alert, wrapped around `content`.
    func historyImportHooks(_ content: some View) -> some View {
        content
            .fileImporter(
                isPresented: $historyImportUI.isPicking,
                allowedContentTypes: [WalkHistoryFile.contentType]
            ) { result in
                guard case .success(let url) = result else { return }
                historyImportUI.pickedURL = url
                if !historyImportUI.isPicking { openPickedHistoryFile() }
            }
            // Presented once the picker's binding is false, never in the same
            // update as its dismissal (the Export First precedent).
            .onChange(of: historyImportUI.isPicking) { _, isPicking in
                if !isPicking { openPickedHistoryFile() }
            }
            .onChange(of: streetsWalkedViewModel?.historyImport?.owner, initial: true) { syncHistoryImportSheet() }
            .task(id: historyFileClaimKey) { await claimWaitingHistoryFile() }
            .alert(
                AppCopy.HistoryImport.storeUnavailable.copy.text,
                isPresented: $historyImportUI.isShowingUnavailable
            ) {
                Button(AppCopy.doneAction.copy.text, role: .cancel) {}
            }
    }

    /// The import sheet's slot in `StreetsSheet`'s presentation.
    func historyImportSheet(_ viewModel: StreetsWalkedViewModel) -> some View {
        WalkHistoryImportSheet(
            viewModel: viewModel,
            owner: streetsSceneToken,
            onShowYourWalks: { streetsSheet = .yourWalks },
            onStartRecording: {
                historyImportUI.startsRecordingAfterDismiss = true
                streetsSheet = nil
            }
        )
    }

    /// Any Streets Walked sheet closed: Start Recording from the import's
    /// done state runs the menu's path now that nothing covers the system
    /// prompt (DS4); otherwise a closed import returns VoiceOver to the menu.
    func streetsSheetDidDismiss() {
        defer { historyImportUI.focusesMenuAfterDismiss = false }
        if historyImportUI.startsRecordingAfterDismiss {
            historyImportUI.startsRecordingAfterDismiss = false
            if streetsWalkedViewModel?.recordingState == .off {
                Task { await toggleStreetsWalked() }
            }
            return
        }
        if historyImportUI.focusesMenuAfterDismiss, streetsSheet == nil {
            isStreetsWalkedMenuFocused = true
        }
    }

    private func openPickedHistoryFile() {
        guard let url = historyImportUI.pickedURL, let streetsWalkedViewModel else { return }
        historyImportUI.pickedURL = nil
        guard streetsWalkedViewModel.canImportHistory else { return }
        streetsWalkedViewModel.openHistoryFile(.picked(url), owner: streetsSceneToken)
    }

    /// This window shows the import sheet exactly while the app's import is
    /// its own: a takeover by another window closes it without a word (D13).
    private func syncHistoryImportSheet() {
        let isMine = streetsWalkedViewModel?.historyImport?.owner == streetsSceneToken
        if isMine, streetsSheet != .importHistory, streetsWalkedViewModel?.historyImport?.phase.isCancellable == true {
            historyImportUI.focusesMenuAfterDismiss = true
            streetsSheet = .importHistory
        } else if !isMine, streetsSheet == .importHistory {
            streetsSheet = nil
        }
    }

    private struct HistoryFileClaimKey: Hashable {
        let file: Int?
        let scenePhase: ScenePhase
        let isForeground: Bool
        let showsToolbar: Bool
        let canReceive: Bool
    }

    private var historyFileClaimKey: HistoryFileClaimKey {
        HistoryFileClaimKey(
            file: sharedWalkInbox?.pendingHistoryFile?.id,
            scenePhase: scenePhase,
            isForeground: isForeground,
            showsToolbar: showsToolbar,
            canReceive: streetsWalkedViewModel?.canReceiveHistoryFile ?? true
        )
    }

    /// Re-checks every 0.5 s while a file waits (the Shared Walk gate's
    /// cadence) and claims it once this window may show it.
    private func claimWaitingHistoryFile() async {
        while sharedWalkInbox?.pendingHistoryFile != nil, !Task.isCancelled {
            if mayClaimHistoryFile(), let file = sharedWalkInbox?.takeHistoryFile() {
                claim(file)
                return
            }
            guard (try? await Task.sleep(for: SharedWalkPresentation.pollInterval)) != nil else { return }
        }
    }

    /// The map is frontmost and active in this window, nothing of the
    /// export or Clear is up, no shared walk waits, and nothing is presented
    /// but this map's own Your Blocks, Your Walks or import sheet (replaced
    /// in place). The intro is closed first and the claim waits for it to go.
    /// Sheets with input (Add Bodega, photos, a review, Account, sign-in)
    /// are presentations, so the file waits for them (D8).
    private func mayClaimHistoryFile() -> Bool {
        guard scenePhase == .active, isForeground, showsToolbar else { return false }
        guard !historyExport.isPresenting, !showingClearConfirmation, !historyImportUI.isPicking,
              !historyImportUI.isShowingUnavailable, sharedWalkInbox?.pending == nil
        else { return false }
        if let streetsWalkedViewModel, !streetsWalkedViewModel.canReceiveHistoryFile { return false }
        if showingStreetsWalkedIntro {
            showingStreetsWalkedIntro = false
            return false
        }
        let depth = Self.presentationDepth()
        return streetsSheet == nil ? depth == 0 : depth <= 1
    }

    private func claim(_ file: SharedWalkInbox.HistoryFile) {
        guard let streetsWalkedViewModel else {
            // No store (spec): say so, and drop the copy.
            Task.detached { WalkHistoryTransfer.removeInboxCopy(file.url) }
            historyImportUI.isShowingUnavailable = true
            return
        }
        streetsWalkedViewModel.openHistoryFile(.opened(file.url), owner: streetsSceneToken)
    }

    /// How many presentations are stacked on the key window's root view
    /// controller. Read only.
    private static func presentationDepth() -> Int {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow) ?? windows.first
        var presented = window?.rootViewController?.presentedViewController
        var depth = 0
        while let current = presented {
            depth += 1
            presented = current.presentedViewController
        }
        return depth
    }
}

extension WalkHistoryFile {
    /// The exported type, for the picker (declared in `Info.plist`).
    static let contentType = UTType(exportedAs: typeIdentifier, conformingTo: .data)
}
