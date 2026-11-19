import Foundation
import Observation

/// Where every opened URL goes (#177 PR 2, eng "PR 2, the link"; #180 eng
/// A10): one object, created and owned by `AppDelegate`, with one entry,
/// `receive(_:)`, which dispatches by URL kind, and one output per kind:
/// `pending` for a walk link, `pendingHistoryFile` for a walk history file.
///
/// A file URL ending in `.mybodegas` waits in `pendingHistoryFile` until a
/// map window claims it for its import sheet (`takeHistoryFile()`); a newer
/// one replaces it, and the replaced Inbox copy is deleted (eng A5).
/// Otherwise `receive` decodes a walk link and records `shared_walk_opened`
/// with how it decoded; a URL of neither kind is ignored and records
/// nothing. A newer link replaces the walk already pending, keeping its
/// `id`, so a sheet already showing it changes its content in place and is
/// never dismissed and presented again. The presenter (`RootView`) shows
/// `pending` when nothing else is presented and calls `close()` when the
/// sheet goes.
@Observable
final class SharedWalkInbox {
    /// One walk link to show: how it decoded, and how many links have
    /// landed in this slot (each one refits the map).
    struct Item: Identifiable, Equatable {
        let id: Int
        var result: SharedWalkLink.Decoded
        var revision: Int
    }

    private(set) var pending: Item?
    /// A walk history file opened from outside (#180), not yet claimed.
    private(set) var pendingHistoryFile: HistoryFile?
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private let capture: (TelemetryEvent) -> Void

    /// - Parameter capture: where `shared_walk_opened` goes (the app's
    ///   `Telemetry`, a recording sink in tests).
    init(capture: @escaping (TelemetryEvent) -> Void = { _ in }) {
        self.capture = capture
    }

    /// Every URL the app is handed, universal links and the DEBUG
    /// `-UITestOpenURL` alike.
    func receive(_ url: URL) {
        if WalkHistoryFile.isHistoryFileURL(url) {
            receiveHistoryFile(url)
            return
        }
        guard let result = SharedWalkLink.decode(url) else { return }
        capture(.sharedWalkOpened(result: SharedWalkOpenResult(result)))
        if var item = pending {
            item.result = result
            item.revision += 1
            pending = item
        } else {
            pending = Item(id: nextID, result: result, revision: 0)
            nextID += 1
        }
    }

    /// One walk history file waiting for an import sheet (#180).
    struct HistoryFile: Identifiable, Equatable {
        let id: Int
        let url: URL
    }

    private func receiveHistoryFile(_ url: URL) {
        if let replaced = pendingHistoryFile, replaced.url != url {
            Task.detached { WalkHistoryTransfer.removeInboxCopy(replaced.url) }
        }
        pendingHistoryFile = HistoryFile(id: nextID, url: url)
        nextID += 1
    }

    /// A map window claims the waiting file for its import (#180 design D8).
    func takeHistoryFile() -> HistoryFile? {
        defer { pendingHistoryFile = nil }
        return pendingHistoryFile
    }

    /// The sheet showing `shown` closed: that walk is discarded (nothing is
    /// saved). A link that replaced it after the dismissal began has a
    /// newer revision and survives, to present again through the gate.
    func close(_ shown: Item) {
        guard pending?.id == shown.id, pending?.revision == shown.revision else { return }
        pending = nil
    }
}

/// How an opened walk link decoded (#177 PR 2), `shared_walk_opened`'s one
/// property.
nonisolated enum SharedWalkOpenResult: String, Sendable {
    case opened = "ok"
    case damaged
    case needsUpdate = "needs_update"

    init(_ decoded: SharedWalkLink.Decoded) {
        switch decoded {
        case .walk: self = .opened
        case .damaged: self = .damaged
        case .needsUpdate: self = .needsUpdate
        }
    }
}
