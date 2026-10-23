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
/// per-borough counts and the overlay's runs (with their spatial index), all
/// from the same masks. `runsVersion` changes exactly when the runs do
/// (`BlockMatchingActor` reconciles them off the main actor), so the view
/// model compares an integer, never the run arrays.
nonisolated struct WalkedSummary: Sendable, Equatable {
    var walkedIDs: Set<UInt32>
    /// In `Borough.displayOrder`.
    var progress: [BoroughProgress]
    var runIndex: WalkedRunIndex
    var runsVersion: Int

    var runs: [WalkedRun] { runIndex.runs }

    static let empty = WalkedSummary(walkedIDs: [], progress: [], runs: [])

    /// Citywide: every borough summed.
    var citywide: (walked: Int, total: Int) {
        progress.reduce((0, 0)) { ($0.0 + $1.walked, $0.1 + $1.total) }
    }

    init(walkedIDs: Set<UInt32>, progress: [BoroughProgress], runs: [WalkedRun], runsVersion: Int = 0) {
        self.walkedIDs = walkedIDs
        self.progress = progress
        runIndex = WalkedRunIndex(runs: runs)
        self.runsVersion = runsVersion
    }

    /// The summary of `masks` against `grid`: a block counts once
    /// `BlockMatcher.isWalked`, and totals are the grid's header counts.
    init(masks: [UInt32: UInt16], grid: StreetGrid) {
        var walked: Set<UInt32> = []
        var perBorough: [Borough: Int] = [:]
        for (physicalID, mask) in masks where BlockMatcher.isWalked(mask: mask) {
            guard let index = grid.index(ofPhysicalID: physicalID) else { continue }
            walked.insert(physicalID)
            perBorough[grid.borough(for: index), default: 0] += 1
        }
        self.init(
            walkedIDs: walked,
            progress: Borough.displayOrder.map {
                BoroughProgress(borough: $0, walked: perBorough[$0] ?? 0, total: grid.blockCounts[$0] ?? 0)
            },
            runs: WalkedOverlay.runs(walkedIDs: walked, grid: grid)
        )
    }

    /// This summary with runs that equal one in `previous` replaced by that
    /// run (same `MKPolyline` object, so MapKit keeps its overlay), and
    /// `runsVersion` advanced only if the runs changed.
    func reconciled(with previous: WalkedSummary) -> WalkedSummary {
        var result = self
        if runs == previous.runs {
            result.runIndex = previous.runIndex
            result.runsVersion = previous.runsVersion
            return result
        }
        let old = Dictionary(previous.runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        result.runIndex = WalkedRunIndex(runs: runs.map { run in
            if let kept = old[run.id], kept == run { return kept }
            return run
        })
        result.runsVersion = previous.runsVersion &+ 1
        return result
    }
}
