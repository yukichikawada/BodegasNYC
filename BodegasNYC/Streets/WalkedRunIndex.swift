import Foundation

/// The walked runs plus a coarse spatial index over their bounding boxes,
/// built once per data change off the main actor (`WalkedSummary`), so a
/// settle's culling reads only the cells under the view: its cost follows
/// what is in view, not the size of the whole history (R3 device check: the
/// 5,000-block seed hitched even zoomed in).
nonisolated struct WalkedRunIndex: Sendable, Equatable {
    /// About 550 m x 560 m at NYC's latitude.
    static let cellLatitudeDegrees = 0.005
    static let cellLongitudeDegrees = 0.0066

    let runs: [WalkedRun]
    private let cells: [Int64: [Int32]]
    private let rowRange: ClosedRange<Int>
    private let columnRange: ClosedRange<Int>

    static let empty = WalkedRunIndex(runs: [])

    init(runs: [WalkedRun]) {
        self.runs = runs
        var cells: [Int64: [Int32]] = [:]
        var minRow = Int.max, maxRow = Int.min, minColumn = Int.max, maxColumn = Int.min
        for (index, run) in runs.enumerated() {
            let rows = Self.row(run.minLatitude) ... Self.row(run.maxLatitude)
            let columns = Self.column(run.minLongitude) ... Self.column(run.maxLongitude)
            minRow = min(minRow, rows.lowerBound)
            maxRow = max(maxRow, rows.upperBound)
            minColumn = min(minColumn, columns.lowerBound)
            maxColumn = max(maxColumn, columns.upperBound)
            for row in rows {
                for column in columns {
                    cells[Self.key(row, column), default: []].append(Int32(index))
                }
            }
        }
        self.cells = cells
        rowRange = runs.isEmpty ? 0 ... 0 : minRow ... maxRow
        columnRange = runs.isEmpty ? 0 ... 0 : minColumn ... maxColumn
    }

    /// What the map draws for `region`: the runs whose bounding box meets
    /// the region expanded by 25% on each side, in run order, or `overCap`
    /// past `WalkedOverlay.maxVisibleRuns`. Same answer as
    /// `WalkedOverlay.visible(_:in:)`, which scans every run.
    func visible(in region: WalkedRegion) -> WalkedOverlay.Visible {
        query(region).visible
    }

    /// `visible(in:)` plus how many index entries it examined (tests: the
    /// cost follows the cells in view, not the total).
    func query(_ region: WalkedRegion) -> (visible: WalkedOverlay.Visible, examined: Int) {
        guard !runs.isEmpty else { return (.runs([]), 0) }
        let bounds = WalkedOverlay.expandedBounds(region)
        let firstRow = max(rowRange.lowerBound, Self.row(bounds.minLatitude))
        let lastRow = min(rowRange.upperBound, Self.row(bounds.maxLatitude))
        let firstColumn = max(columnRange.lowerBound, Self.column(bounds.minLongitude))
        let lastColumn = min(columnRange.upperBound, Self.column(bounds.maxLongitude))
        guard firstRow <= lastRow, firstColumn <= lastColumn else { return (.runs([]), 0) }
        let rows = firstRow ... lastRow
        let columns = firstColumn ... lastColumn
        var kept = Set<Int32>()
        var examined = 0
        for row in rows {
            for column in columns {
                for index in cells[Self.key(row, column)] ?? [] {
                    examined += 1
                    guard !kept.contains(index), WalkedOverlay.meets(runs[Int(index)], bounds) else { continue }
                    kept.insert(index)
                    if kept.count > WalkedOverlay.maxVisibleRuns { return (.overCap, examined) }
                }
            }
        }
        return (.runs(kept.sorted().map { runs[Int($0)] }), examined)
    }

    static func == (lhs: WalkedRunIndex, rhs: WalkedRunIndex) -> Bool {
        lhs.runs == rhs.runs
    }

    private static func row(_ latitude: Double) -> Int {
        Int((latitude / cellLatitudeDegrees).rounded(.down))
    }

    private static func column(_ longitude: Double) -> Int {
        Int((longitude / cellLongitudeDegrees).rounded(.down))
    }

    private static func key(_ row: Int, _ column: Int) -> Int64 {
        Int64(row) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: column)))
    }
}
