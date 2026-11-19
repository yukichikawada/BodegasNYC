import Foundation

/// What the Shared Walk sheet shows (#177 design "Shared Walk sheet (PR 2)"
/// state table), pure so each state is unit-tested without the view.
///
/// A decoded walk shows its map and the sender's counts at once, whatever
/// the street data is doing (loading, failed, ready). A walk none of whose
/// blocks this street file knows, a newer format and a damaged link show no
/// map: one line, and for the two update states an Update row.
nonisolated enum SharedWalkScreen: Equatable {
    case walk(SharedWalk, SharedWalkDrawing)
    case message(AppCopy.ReceivedWalk, offersUpdate: Bool)

    static func make(_ result: SharedWalkLink.Decoded, drawing: SharedWalkDrawing) -> SharedWalkScreen {
        switch result {
        case .damaged:
            return .message(.damaged, offersUpdate: false)
        case .needsUpdate:
            return .message(.needsUpdate, offersUpdate: true)
        case .walk(let walk):
            if case .ready(_, let known) = drawing, known == 0 {
                return .message(.noneDrawable, offersUpdate: true)
            }
            return .walk(walk, drawing)
        }
    }

    /// The decoded walk, when there is one (the dates in the subtitle).
    static func walk(in result: SharedWalkLink.Decoded) -> SharedWalk? {
        if case .walk(let walk) = result { return walk }
        return nil
    }

    /// Fewer of the link's blocks are known to this street file than it
    /// holds, so some are not drawn.
    static func someNotShown(_ walk: SharedWalk, _ drawing: SharedWalkDrawing) -> Bool {
        guard case .ready(_, let known) = drawing else { return false }
        return known < walk.blockCount
    }

    /// The footnotes under the counts, in order (design): the estimate
    /// line, the coverage line, then "This walk isn't saved.".
    static func footnotes(_ walk: SharedWalk, _ drawing: SharedWalkDrawing) -> [CopyString] {
        var lines: [CopyString] = []
        if walk.isEstimate { lines.append(AppCopy.ShareWalk.estimate.copy) }
        if case .ready(_, let known) = drawing, known < walk.blockCount {
            lines.append(AppCopy.sharedWalkCoverage(shown: known, of: walk.blockCount))
        }
        lines.append(AppCopy.ReceivedWalk.notSaved.copy)
        return lines
    }

    /// The app's App Store page (`docs/APP_STORE.md`, app id 6830464647):
    /// where Update goes.
    static let appStoreURL = URL(string: "https://apps.apple.com/app/id6830464647")!
}
