import Foundation

/// What the app's one `WalkHistoryTransfer` is doing (eng A4), published on
/// the shared view model so every window sees it. PR 2 adds previewing and
/// committing an import.
nonisolated enum WalkHistoryTransferState: Equatable, Sendable {
    case idle
    case exporting
}

/// Export of walk history as a file (#180 PR 1). The transfer does the
/// work off the main actor; this extension holds the state every window
/// reads, the 0.5 s progress signal (design D7), errors and telemetry.
extension StreetsWalkedViewModel {
    nonisolated enum HistoryExportOutcome: Equatable, Sendable {
        /// The files are written; the share sheet comes next.
        case exported(WalkHistoryTransfer.Export)
        /// Reading or writing failed: recorded, and the failure alert shows.
        case failed
        /// Nothing to export, or another transfer or a Clear is running.
        case unavailable
    }

    /// How long an export runs before the menu pulses and VoiceOver hears
    /// "Making the file." (design D7: the Locate Me precedent).
    nonisolated static let historyExportProgressDelay: Duration = .milliseconds(500)

    /// Export, Clear History and (PR 2) Import wait while a transfer runs
    /// or a Clear is deleting, in every window (design D7, eng A7).
    var isHistoryFileBusy: Bool {
        historyTransferState != .idle || isClearingHistory
    }

    /// The menu's Export History: disabled with no history (AC 9) and while
    /// busy.
    var canExportHistory: Bool {
        hasHistory && !isHistoryFileBusy
    }

    /// The menu's Clear History: disabled while busy (design D7).
    var canClearHistory: Bool {
        !isHistoryFileBusy
    }

    /// How many files an export now would write (design D12), counted on
    /// the transfer, never on the main actor.
    func historyExportPartCount(at tapTime: Date = Date()) async -> Int {
        let count = (try? await historyTransfer.fixCount(through: tapTime)) ?? 0
        return WalkHistoryFile.partCount(fixCount: count, maxFixCount: historyTransfer.maxFixCount)
    }

    /// Exports every fix up to `tapTime`, the confirm tap. From 0.5 s in,
    /// `showsHistoryExportProgress` is true and "Making the file." is
    /// announced once; both end with the export.
    func exportHistory(at tapTime: Date) async -> HistoryExportOutcome {
        guard canExportHistory else { return .unavailable }
        historyTransferState = .exporting
        let progress = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.historyExportProgressDelay)) != nil,
                  let self, historyTransferState == .exporting
            else { return }
            showsHistoryExportProgress = true
            announce(AppCopy.HistoryFile.exportAnnouncement.copy.text)
        }
        defer {
            progress.cancel()
            showsHistoryExportProgress = false
            historyTransferState = .idle
        }
        do {
            return .exported(try await historyTransfer.export(through: tapTime))
        } catch {
            telemetry.record(error, context: "walk_history.export")
            return .failed
        }
    }

    /// The share sheet closed (AC 11, eng A6). Completed: one
    /// `walk_history_exported`, no properties, and the files stay for the
    /// destination until the next sweep (no longer live, so it may remove
    /// them). Cancelled: the files go now.
    func historyExportFinished(_ export: WalkHistoryTransfer.Export, completed: Bool) async {
        if completed {
            telemetry.capture(.walkHistoryExported)
            await historyTransfer.finish(export)
        } else {
            await historyTransfer.discard(export)
        }
    }
}
