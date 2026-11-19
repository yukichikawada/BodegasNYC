import Foundation

/// A walk history file on its way into an import (#180 PR 2).
nonisolated struct IncomingHistoryFile: Equatable, Sendable {
    let url: URL
    /// A copy the system made in this app's Inbox (opened from Files,
    /// AirDrop or Mail): deleted once read (eng A5). A file picked with
    /// Import History… is the person's own and is never deleted.
    let isInboxCopy: Bool

    /// Opened from outside (`.onOpenURL`).
    static func opened(_ url: URL) -> IncomingHistoryFile {
        IncomingHistoryFile(url: url, isInboxCopy: WalkHistoryTransfer.isInboxCopy(url))
    }

    /// Picked in the menu's file picker.
    static func picked(_ url: URL) -> IncomingHistoryFile {
        IncomingHistoryFile(url: url, isInboxCopy: false)
    }
}

/// What the import sheet shows (design "States of the import sheet").
nonisolated enum HistoryImportPhase: Equatable, Sendable {
    /// "Reading the file…" from 0.5 s; Cancel.
    case reading
    /// The preview; with `saveFailed`, "Those walks didn't save. Try
    /// again." under the action.
    case preview(WalkHistoryTransfer.ImportPreview, saveFailed: Bool)
    /// "Nothing new in this file." (D6), with the skipped line if any.
    case nothingNew(hasSkipped: Bool)
    /// One `.primary` line and Done: no walks, nothing readable, a refusal,
    /// a read failure, cleared meanwhile, a failed count, the store gone.
    case message(HistoryImportMessage)
    /// "Adding your walks…"; no control, no swipe-down.
    case saving
    /// "Counting your blocks…"; Done (the count goes on).
    case counting
    /// "Your walks are in." (DS4).
    case done

    /// Before the save: Cancel closes and drops the held fixes.
    var isCancellable: Bool {
        switch self {
        case .reading, .preview: true
        default: false
        }
    }
}

/// The single-line outcomes of an import (design copy table).
nonisolated enum HistoryImportMessage: Equatable, Sendable {
    case noWalks
    case nothingReadable
    case wrongFile
    case newerFormat
    case tooLarge
    case readFailure
    case clearedMeanwhile
    case countFailed
    case storeUnavailable

    var copy: CopyString {
        switch self {
        case .noWalks: AppCopy.HistoryImport.noWalks.copy
        case .nothingReadable: AppCopy.HistoryImport.nothingReadable.copy
        case .wrongFile: AppCopy.HistoryImport.wrongFile.copy
        case .newerFormat: AppCopy.HistoryImport.newerFormat.copy
        case .tooLarge: AppCopy.HistoryImport.tooLarge.copy
        case .readFailure: AppCopy.HistoryImport.readFailure.copy
        case .clearedMeanwhile: AppCopy.HistoryImport.clearedMeanwhile.copy
        case .countFailed: AppCopy.YourBlocks.countFailed.copy
        case .storeUnavailable: AppCopy.HistoryImport.storeUnavailable.copy
        }
    }
}

/// The app's one import (eng A4): the window whose sheet shows it, the
/// file's name and the sheet's phase. A second file replaces the request
/// and bumps `replacements` (design D9).
struct HistoryImportSession: Equatable {
    /// The transfer request now on screen; a new file gets a new one.
    var request: Int
    var owner: StreetsWalkedViewModel.SceneToken
    var phase: HistoryImportPhase
    /// How many times a later file replaced this sheet's file (D9's
    /// "Another file opened.").
    var replacements = 0
}

// Import of walk history from a file (#180 PR 2). The transfer reads and
// writes off the main actor; this holds the app-wide session every window
// reads (eng A4, design D13), the commit's generation check (A7), the
// forced recount (A1, D10), errors and telemetry.
extension StreetsWalkedViewModel {
    /// A file may start (or replace) an import now: not while an import
    /// saves (design D8: it waits and is presented after), an export runs
    /// or a Clear deletes.
    var canReceiveHistoryFile: Bool {
        historyTransferState != .committing && historyTransferState != .exporting && !isClearingHistory
    }

    /// Starts reading `file` in `owner`'s sheet. With an import already on
    /// screen before its save, the new file replaces it (design D9): the
    /// sheet returns to reading, and another window takes the sheet over
    /// (D13). Does nothing while `canReceiveHistoryFile` is false.
    func openHistoryFile(_ file: IncomingHistoryFile, owner: SceneToken, now: Date = Date()) {
        guard canReceiveHistoryFile else { return }
        historyImportRequests += 1
        let request = historyImportRequests
        var replacements = 0
        if let current = historyImport {
            let transfer = historyTransfer
            let old = current.request
            Task { await transfer.cancelImport(old) }
            if current.owner == owner, current.phase.isCancellable { replacements = current.replacements + 1 }
        }
        historyImportTask?.cancel()
        historyImport = HistoryImportSession(
            request: request,
            owner: owner,
            phase: .reading,
            replacements: replacements
        )
        historyTransferState = .reading
        historyImportTask = Task { [weak self] in
            guard let self else { return }
            let phase: HistoryImportPhase
            do {
                let preview = try await historyTransfer.inspect(
                    file.url,
                    request: request,
                    removingAfterRead: file.isInboxCopy,
                    now: now
                )
                phase = Self.phase(for: preview)
            } catch let error as WalkHistoryTransfer.ImportError {
                // A refusal is the file's; a read failure is worth knowing about.
                if error == .unreadable { telemetry.record(error, context: "walk_history.import") }
                phase = .message(Self.message(for: error))
            } catch {
                telemetry.record(error, context: "walk_history.import")
                phase = .message(.readFailure)
            }
            guard historyImport?.request == request else { return }
            historyImport?.phase = phase
            if case .preview = phase {
                historyTransferState = .previewing(request)
            } else {
                historyTransferState = .idle
                await historyTransfer.cancelImport(request)
            }
        }
    }

    /// Add Walks: saves the preview's new fixes, then counts. The matcher's
    /// generation at this tap is checked again right before the save (eng
    /// A7); no pass runs during the save, and one that was running is
    /// waited for, so none holds the match state the commit deletes (A1).
    func commitHistoryImport() async {
        guard let session = historyImport, case .preview(let preview, _) = session.phase,
              historyTransferState == .previewing(session.request), !isClearingHistory
        else { return }
        let request = session.request
        let generation = matcher.generation
        historyTransferState = .committing
        historyImport?.phase = .saving
        await waitForRunningRefresh()
        let matcher = matcher
        let outcome: WalkHistoryTransfer.CommitOutcome
        do {
            outcome = try await historyTransfer.commit(request) { matcher.generation == generation }
        } catch {
            telemetry.record(error, context: "walk_history.import")
            historyTransferState = .previewing(request)
            if historyImport?.request == request { historyImport?.phase = .preview(preview, saveFailed: true) }
            return
        }
        historyTransferState = .idle
        switch outcome {
        case .committed(let inserted, _):
            if inserted > 0 { telemetry.capture(.walkHistoryImported) }
            importDidSave()
            setImportPhase(.counting, for: request)
            await refreshWalkedBlocks()
            let countFailed = !hasCounted && (countState == .failed || countState == .unavailable)
            setImportPhase(countFailed ? .message(.countFailed) : .done, for: request)
        case .cleared:
            setImportPhase(.message(.clearedMeanwhile), for: request)
        case .stale:
            setImportPhase(.message(.readFailure), for: request)
        }
    }

    /// `owner`'s import sheet closed (Cancel, Done, a swipe, Show Your
    /// Walks, or another window took it over). Before a save the held fixes
    /// go; a count already running goes on. Another window's import is left
    /// alone.
    func endHistoryImport(owner: SceneToken) {
        guard let session = historyImport, session.owner == owner else { return }
        guard session.phase != .saving else { return }
        if session.phase.isCancellable {
            historyImportTask?.cancel()
            let transfer = historyTransfer
            Task { await transfer.cancelImport(session.request) }
            historyTransferState = .idle
        }
        historyImport = nil
    }

    private func setImportPhase(_ phase: HistoryImportPhase, for request: Int) {
        guard historyImport?.request == request else { return }
        historyImport?.phase = phase
    }

    /// The preview, or the nothing-to-add cases (design D6).
    nonisolated static func phase(for preview: WalkHistoryTransfer.ImportPreview) -> HistoryImportPhase {
        if preview.fileFixCount == 0 {
            return .message(preview.skippedFixCount > 0 ? .nothingReadable : .noWalks)
        }
        if preview.newFixCount == 0 { return .nothingNew(hasSkipped: preview.skippedFixCount > 0) }
        return .preview(preview, saveFailed: false)
    }

    nonisolated static func message(for error: WalkHistoryTransfer.ImportError) -> HistoryImportMessage {
        switch error {
        case .notWalkHistory: .wrongFile
        case .newerVersion: .newerFormat
        case .tooLarge: .tooLarge
        case .unreadable: .readFailure
        }
    }
}
