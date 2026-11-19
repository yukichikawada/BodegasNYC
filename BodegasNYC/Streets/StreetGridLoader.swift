import Foundation
import Synchronization

/// The bundled street grid, parsed once per process and shared (#177 PR 2,
/// eng Architecture 3). `BlockMatchingActor` and the Shared Walk sheet both
/// load through `shared`, so the file is parsed once, and neither needs the
/// Streets Walked store: a shared walk opens even when the store's
/// container failed and `AppDelegate` has no view model.
///
/// A success is kept for the life of the process; a failure is not, so the
/// sheet's Retry loads again. Call it off the main actor: the first load
/// parses the whole file.
nonisolated final class StreetGridLoader: Sendable {
    static let shared = StreetGridLoader()

    private let load: @Sendable () throws -> StreetGrid
    private let state = Mutex<StreetGrid?>(nil)
    private let loadCount = Mutex(0)

    init(load: @escaping @Sendable () throws -> StreetGrid = { try StreetGrid.loadBundled() }) {
        self.load = load
    }

    /// The grid, parsing it on the first call (callers wait on one parse).
    func grid() throws -> StreetGrid {
        try state.withLock { slot in
            if let cached = slot { return cached }
            loadCount.withLock { $0 += 1 }
            let grid = try load()
            slot = grid
            return grid
        }
    }

    /// Parses attempted so far (tests).
    var loads: Int { loadCount.withLock { $0 } }
}
