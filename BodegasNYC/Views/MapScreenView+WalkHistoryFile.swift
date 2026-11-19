import SwiftUI

/// One window's walk history export (#180 PR 1): the confirmation, the
/// share sheet's files and the failure alert. The transfer's own state is
/// app-wide, on the view model (eng A4).
struct HistoryExportPresentation {
    var isConfirming = false
    /// How many files the export writes (design D12), counted when the
    /// dialog opens.
    var partCount = 1
    /// The written files, while the share sheet is up.
    var sharing: WalkHistoryTransfer.Export?
    var isShowingFailure = false
    /// Export First was tapped: the export confirmation opens once Clear
    /// History's dialog has closed (design DS3).
    var opensAfterClearDialog = false

    /// Something of the export is on screen in this window.
    var isPresenting: Bool {
        isConfirming || sharing != nil || isShowingFailure
    }
}

// Walk history files (#180): the Streets Walked menu's Export History,
// its confirmation (design DS2, D12), the pulse and announcement (D7, on
// the view model), the failure alert with Retry (D7), the share sheet, and
// Clear History's confirmation with Export First (DS3). Kept out of
// `MapScreenView.swift`, which is at its length limit.
extension MapScreenView {
    /// The menu's walk history section, directly above Clear History
    /// (design D11): no icons, the labels with an ellipsis. Export History
    /// is disabled with no history and while a transfer or a Clear runs;
    /// Import History (`MapScreenView+WalkHistoryImport.swift`) under it.
    func historyFileSection(_ viewModel: StreetsWalkedViewModel) -> some View {
        Section {
            Button(AppCopy.HistoryFile.exportMenuItem.menuItemWithEllipsis) { requestHistoryExport() }
                .accessibilityHint(AppCopy.HistoryFile.exportMenuHint.copy.text)
                .disabled(!viewModel.canExportHistory)
            historyImportMenuItem(viewModel)
        }
    }

    /// Counts the parts on the transfer, then opens the export
    /// confirmation.
    func requestHistoryExport() {
        guard let streetsWalkedViewModel, streetsWalkedViewModel.canExportHistory else { return }
        Task {
            // Counted now, cut at the confirm tap: fixes recorded in between
            // could only tip a history sitting exactly at the cap into one
            // more part than the dialog said.
            let partCount = await streetsWalkedViewModel.historyExportPartCount()
            historyExport.partCount = partCount
            historyExport.isConfirming = true
        }
    }

    /// The export itself, from the confirm tap or Retry; then the share
    /// sheet, or the failure alert.
    func runHistoryExport(at tapTime: Date) async {
        guard let streetsWalkedViewModel else { return }
        switch await streetsWalkedViewModel.exportHistory(at: tapTime) {
        case .exported(let export): historyExport.sharing = export
        case .failed: historyExport.isShowingFailure = true
        case .unavailable: break
        }
    }

    /// Clear History's confirmation and the export's dialog, alert and share
    /// sheet, wrapped around `content`.
    func historyFileDialogs(_ content: some View) -> some View {
        content
            .confirmationDialog(
                AppCopy.clearHistoryConfirmTitle.copy.text,
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(AppCopy.deleteHistoryAction.copy.text, role: .destructive) {
                    // An export another window started while this dialog was
                    // open wins: Clear waits for it (design D7).
                    guard streetsWalkedViewModel?.canClearHistory == true else { return }
                    // The cutoff is this tap (design D5, eng R9).
                    let tapTime = Date()
                    Task { await clearStreetsWalkedHistory(at: tapTime) }
                }
                // Between Delete History and Cancel; never continues to the
                // delete (DS3). Hidden while a transfer is busy.
                if streetsWalkedViewModel?.canExportHistory == true {
                    Button(AppCopy.HistoryFile.exportFirstAction.copy.text) {
                        historyExport.opensAfterClearDialog = true
                    }
                }
                Button(AppCopy.cancelAction.copy.text, role: .cancel) {}
            } message: {
                Text(AppCopy.clearHistoryConfirmBody.copy.text)
            }
            // Export First's handoff: presented once the Clear dialog's
            // binding is false, never in the same update as its dismissal.
            .onChange(of: showingClearConfirmation) { _, isShown in
                guard !isShown, historyExport.opensAfterClearDialog else { return }
                historyExport.opensAfterClearDialog = false
                requestHistoryExport()
            }
            .confirmationDialog(
                AppCopy.HistoryFile.exportConfirmTitle.copy.text,
                isPresented: $historyExport.isConfirming,
                titleVisibility: .visible
            ) {
                Button(AppCopy.HistoryFile.exportAction.copy.text) {
                    let tapTime = Date()
                    Task { await runHistoryExport(at: tapTime) }
                }
                Button(AppCopy.cancelAction.copy.text, role: .cancel) {}
            } message: {
                Text(exportConfirmMessage)
            }
            .alert(AppCopy.HistoryFile.exportFailed.copy.text, isPresented: $historyExport.isShowingFailure) {
                Button(AppCopy.retryAction.copy.text) {
                    let tapTime = Date()
                    Task { await runHistoryExport(at: tapTime) }
                }
                Button(AppCopy.cancelAction.copy.text, role: .cancel) {}
            }
            .background {
                WalkHistoryFilePresenter(export: $historyExport.sharing) { export, completed in
                    Task { await streetsWalkedViewModel?.historyExportFinished(export, completed: completed) }
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
    }

    /// DS2's body, then D12's parts line when the history comes as more
    /// than one file.
    private var exportConfirmMessage: String {
        let body = AppCopy.HistoryFile.exportConfirmBody.copy.text
        guard historyExport.partCount > 1 else { return body }
        return body + " " + AppCopy.historyFileParts(historyExport.partCount).text
    }

    /// The Streets Walked toolbar glyph: it pulses from 0.5 s into an
    /// export (design D7, the Locate Me precedent), never under Reduce
    /// Motion.
    func streetsWalkedMenuLabel(_ viewModel: StreetsWalkedViewModel) -> some View {
        Label {
            Text(AppCopy.streetsWalkedMenuLabel.copy.text)
        } icon: {
            Image(systemName: "figure.walk")
                .symbolEffect(.pulse, isActive: viewModel.showsHistoryExportProgress && !reduceMotion)
        }
    }
}
