import Foundation

/// What a shared walk's map can draw (#177 PR 2, eng E8), from the bundled
/// street grid alone: no Streets Walked store, no location, nothing
/// written. Ids this street file does not know are skipped and counted, so
/// the sheet can say "32 of 38 blocks shown." while keeping the sender's
/// counts.
nonisolated enum SharedWalkDrawing: Equatable, Sendable {
    /// The street data is loading; the counts show at once.
    case loading
    /// The street data did not load: "The street map didn't load. Try again."
    case failed
    /// The runs of the blocks this street file knows, and how many it knows.
    case ready(runs: [WalkedRun], known: Int)

    /// The runs and the known count for `ids` on `grid`.
    static func make(ids: Set<UInt32>, grid: StreetGrid) -> SharedWalkDrawing {
        let known = ids.filter { grid.index(ofPhysicalID: $0) != nil }
        return .ready(runs: WalkedOverlay.runs(walkedIDs: known, grid: grid), known: known.count)
    }

    /// Loads the grid through `loader` and draws `walk`, off the main actor.
    @concurrent
    static func load(_ walk: SharedWalk, loader: StreetGridLoader = .shared) async -> SharedWalkDrawing {
        guard let grid = try? loader.grid() else { return .failed }
        return make(ids: walk.blockIDs, grid: grid)
    }
}
