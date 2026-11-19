import Foundation
import Observation

/// Where every opened URL goes (#177 PR 2, eng "PR 2, the link"): one
/// object, created and owned by `AppDelegate`, with one entry,
/// `receive(_:)`, and one output, `pending`.
///
/// `receive` decodes a walk link and records `shared_walk_opened` with how
/// it decoded; a URL that is not a walk link is ignored and records
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
