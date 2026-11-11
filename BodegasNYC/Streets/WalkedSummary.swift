import Foundation

/// Walked blocks out of a borough's total (#108 spec Implementation 5).
nonisolated struct BoroughProgress: Sendable, Equatable, Identifiable {
    /// How the percentage reads: rounded down to a whole number, except a
    /// nonzero count under 1% (spec Implementation 7).
    nonisolated enum Percent: Sendable, Equatable {
        case lessThanOne
        case whole(Int)
    }

    let borough: Borough
    let walked: Int
    let total: Int

    var id: Borough { borough }

    var percent: Percent {
        Self.percent(walked: walked, total: total)
    }

    static func percent(walked: Int, total: Int) -> Percent {
        guard total > 0, walked > 0 else { return .whole(0) }
        let whole = walked * 100 / total
        return whole == 0 ? .lessThanOne : .whole(whole)
    }
}

/// What a saved match pass hands the view model: the walked blocks, their
/// per-borough counts and the walked layer's pieces and runs (with their
/// spatial indexes), all from the same masks. `piecesVersion` changes
/// exactly when the drawn geometry does (`BlockMatchingActor` reconciles
/// off the main actor), so the view model compares an integer, never the
/// arrays.
nonisolated struct WalkedSummary: Sendable, Equatable {
    var walkedIDs: Set<UInt32>
    /// In `Borough.displayOrder`.
    var progress: [BoroughProgress]
    /// The pieces (#119) and the runs that carry the breadcrumb dots.
    var layer: WalkedLayerIndex
    /// The pieces by tile, kept per tile across passes (#119 eng D6).
    var tiles: [Int64: WalkedTiles.Tile]
    var piecesVersion: Int

    var runs: [WalkedRun] { layer.runs.runs }
    var pieces: [WalkedPiece] { layer.pieces.pieces }

    static let empty = WalkedSummary(walkedIDs: [], progress: [], runs: [], tiles: [:])

    /// Citywide: every borough summed.
    var citywide: (walked: Int, total: Int) {
        progress.reduce((0, 0)) { ($0.0 + $1.walked, $0.1 + $1.total) }
    }

    init(
        walkedIDs: Set<UInt32>,
        progress: [BoroughProgress],
        runs: [WalkedRun],
        tiles: [Int64: WalkedTiles.Tile],
        piecesVersion: Int = 0
    ) {
        self.walkedIDs = walkedIDs
        self.progress = progress
        self.tiles = tiles
        layer = WalkedLayerIndex(pieces: WalkedPieceIndex(tiles: tiles), runs: WalkedRunIndex(runs: runs))
        self.piecesVersion = piecesVersion
    }

    /// The summary of `masks` against `grid`: a block counts once
    /// `BlockMatcher.isWalked`, and totals are the grid's header counts.
    /// The tiles are built against `previous` (#119 eng D6): a tile whose
    /// walked ids did not change keeps its pieces (same `MKPolyline`
    /// objects), so only changed tiles are walked again.
    init(masks: [UInt32: UInt16], grid: StreetGrid, previous: WalkedSummary = .empty) {
        var walked: Set<UInt32> = []
        var perBorough: [Borough: Int] = [:]
        for (physicalID, mask) in masks where BlockMatcher.isWalked(mask: mask) {
            guard let index = grid.index(ofPhysicalID: physicalID) else { continue }
            walked.insert(physicalID)
            perBorough[grid.borough(for: index), default: 0] += 1
        }
        let start = ContinuousClock.now
        let built = WalkedTiles.build(walkedIDs: walked, grid: grid, previous: previous.tiles)
        let elapsed = ContinuousClock.now - start
        self.init(
            walkedIDs: walked,
            progress: Borough.displayOrder.map {
                BoroughProgress(borough: $0, walked: perBorough[$0] ?? 0, total: grid.blockCounts[$0] ?? 0)
            },
            runs: WalkedOverlay.runs(walkedIDs: walked, grid: grid),
            tiles: built.tiles
        )
        WalkedTrace.build(
            blocks: walked.count, tiles: built.tiles.count, rebuiltTiles: built.rebuilt,
            pieces: layer.pieces, elapsed: elapsed
        )
    }

    /// This summary with runs that equal one in `previous` replaced by that
    /// run (same `MKPolyline` object, so MapKit keeps its overlay), the
    /// previous indexes kept when nothing changed, and `piecesVersion`
    /// advanced only if the walked set changed. A changed walked set always
    /// changes both pieces and runs (each covers exactly the walked blocks).
    func reconciled(with previous: WalkedSummary) -> WalkedSummary {
        var result = self
        if walkedIDs == previous.walkedIDs, runs == previous.runs {
            result.layer = previous.layer
            result.tiles = previous.tiles
            result.piecesVersion = previous.piecesVersion
            return result
        }
        let old = Dictionary(previous.runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        result.layer.runs = WalkedRunIndex(runs: runs.map { run in
            if let kept = old[run.id], kept == run { return kept }
            return run
        })
        result.piecesVersion = previous.piecesVersion &+ 1
        return result
    }
}
