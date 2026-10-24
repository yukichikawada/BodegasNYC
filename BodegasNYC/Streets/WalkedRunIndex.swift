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
    /// A run's position in `runs` by its id (the retained runs of a settle
    /// are looked up in the current data, never drawn from a stale copy).
    private let positions: [UInt32: Int32]
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
        positions = Dictionary(
            runs.enumerated().map { ($0.element.id, Int32($0.offset)) },
            uniquingKeysWith: { first, _ in first }
        )
        rowRange = runs.isEmpty ? 0 ... 0 : minRow ... maxRow
        columnRange = runs.isEmpty ? 0 ... 0 : minColumn ... maxColumn
    }

    /// The runs whose bounding box meets the region expanded by 25% on each
    /// side, in run order, or `overCap` past `WalkedOverlay.maxVisibleRuns`:
    /// what a first settle draws, and the set every later settle must draw
    /// (`visible(in:keeping:)`). Same answer as `WalkedOverlay.visible(_:in:)`,
    /// which scans every run.
    func visible(in region: WalkedRegion) -> WalkedOverlay.Visible {
        query(region).visible
    }

    /// `visible(in:)` plus how many index entries it examined (tests: the
    /// cost follows the cells in view, not the total).
    func query(_ region: WalkedRegion) -> (visible: WalkedOverlay.Visible, examined: Int) {
        let (kept, examined) = innerPositions(for: region)
        guard let kept else { return (.overCap, examined) }
        return (.runs(kept.sorted().map { runs[Int($0)] }), examined)
    }

    /// What the map draws for `region` after drawing `previous`, with
    /// culling hysteresis (#113): every run `visible(in:)` draws, plus the
    /// runs of `previous` that still exist and whose box meets the region
    /// expanded by `retainMargin`, so lines just past the 25% margin are
    /// not removed and re-added on every small pan.
    ///
    /// The over-cap decision is `visible(in:)`'s alone (design D3 is never
    /// hit more often than without hysteresis), and the whole of that set is
    /// always drawn. Retained runs only fill the room left under
    /// `WalkedOverlay.maxVisibleRuns`, nearest the centre first, so at most
    /// 1,000 runs are drawn. Pure: previous set + region + index in, next
    /// set out, in run order.
    func visible(
        in region: WalkedRegion,
        keeping previous: WalkedOverlay.Visible,
        retainMargin: Double = WalkedOverlay.retainMargin
    ) -> WalkedOverlay.Visible {
        guard let inner = innerPositions(for: region).kept else { return .overCap }
        guard case .runs(let drawn) = previous, !drawn.isEmpty, retainMargin > WalkedOverlay.regionMargin else {
            return .runs(inner.sorted().map { runs[Int($0)] })
        }
        let outer = WalkedOverlay.expandedBounds(region, margin: retainMargin)
        var retained: [Int32] = []
        for run in drawn {
            guard let position = positions[run.id], !inner.contains(position),
                  WalkedOverlay.meets(runs[Int(position)], outer) else { continue }
            retained.append(position)
        }
        let room = WalkedOverlay.maxVisibleRuns - inner.count
        if retained.count > room {
            retained = retained
                .map { (position: $0, distance: WalkedOverlay.distance(of: runs[Int($0)], from: region)) }
                .sorted { ($0.distance, $0.position) < ($1.distance, $1.position) }
                .prefix(room)
                .map(\.position)
        }
        return .runs((Array(inner) + retained).sorted().map { runs[Int($0)] })
    }

    /// The positions of the runs whose box meets `region` plus
    /// `WalkedOverlay.regionMargin`, or nil past the cap.
    private func innerPositions(for region: WalkedRegion) -> (kept: Set<Int32>?, examined: Int) {
        guard !runs.isEmpty else { return ([], 0) }
        let bounds = WalkedOverlay.expandedBounds(region)
        let firstRow = max(rowRange.lowerBound, Self.row(bounds.minLatitude))
        let lastRow = min(rowRange.upperBound, Self.row(bounds.maxLatitude))
        let firstColumn = max(columnRange.lowerBound, Self.column(bounds.minLongitude))
        let lastColumn = min(columnRange.upperBound, Self.column(bounds.maxLongitude))
        guard firstRow <= lastRow, firstColumn <= lastColumn else { return ([], 0) }
        var kept = Set<Int32>()
        var examined = 0
        for row in firstRow ... lastRow {
            for column in firstColumn ... lastColumn {
                for index in cells[Self.key(row, column)] ?? [] {
                    examined += 1
                    guard !kept.contains(index), WalkedOverlay.meets(runs[Int(index)], bounds) else { continue }
                    kept.insert(index)
                    if kept.count > WalkedOverlay.maxVisibleRuns { return (nil, examined) }
                }
            }
        }
        return (kept, examined)
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
