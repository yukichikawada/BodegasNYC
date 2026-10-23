import Foundation

/// A chain of walked blocks drawn as one `MapPolyline` (#108 eng R3): blocks
/// that share an endpoint (within 1 m) join, and the run is keyed by its
/// first block's `physicalid`, so its identity does not depend on position
/// in a list.
nonisolated struct WalkedRun: Identifiable, Sendable, Equatable {
    let id: UInt32
    let coordinates: [Coordinate]
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    init(id: UInt32, coordinates: [Coordinate]) {
        self.id = id
        self.coordinates = coordinates
        minLatitude = coordinates.map(\.latitude).min() ?? 0
        maxLatitude = coordinates.map(\.latitude).max() ?? 0
        minLongitude = coordinates.map(\.longitude).min() ?? 0
        maxLongitude = coordinates.map(\.longitude).max() ?? 0
    }
}

/// A settled camera's visible region as plain numbers, so the overlay's
/// culling stays a pure function.
nonisolated struct WalkedRegion: Sendable, Equatable {
    var centerLatitude: Double
    var centerLongitude: Double
    var latitudeDelta: Double
    var longitudeDelta: Double
}

/// The overlay's pure rules (#108 spec Implementation 6, eng R3, design D2/D3).
nonisolated enum WalkedOverlay {
    /// More visible runs than this and the whole layer hides (design D3).
    static let maxVisibleRuns = 2_000
    /// The region is expanded by this fraction of its span on each side.
    static let regionMargin = 0.25
    static let joinToleranceMeters = 1.0

    /// What the map draws at a settled camera.
    nonisolated enum Visible: Sendable, Equatable {
        case runs([WalkedRun])
        /// Over the cap: draw nothing and say "Zoom in to see your blocks."
        case overCap
    }

    // MARK: Runs

    /// Chains the walked blocks into runs. Deterministic: blocks are visited
    /// in `physicalid` order, a run starts at a dead end or a junction (an
    /// endpoint shared by other than two walked blocks) before any cycle, and
    /// it continues only through endpoints shared by exactly two.
    static func runs(walkedIDs: Set<UInt32>, grid: StreetGrid) -> [WalkedRun] {
        let indices = walkedIDs.sorted().compactMap { grid.index(ofPhysicalID: $0) }
        guard !indices.isEmpty else { return [] }
        let polylines = indices.map { grid.polyline(for: $0) }

        let graph = EndpointGraph(polylines, tolerance: joinToleranceMeters)
        let nodeOf = graph.nodeOf
        let incident = graph.incident

        var visited = [Bool](repeating: false, count: polylines.count)
        var result: [WalkedRun] = []
        func walk(from first: Int, startNode: Int) {
            var coordinates: [Coordinate] = []
            var block = first
            var entry = startNode
            while true {
                visited[block] = true
                let forward = nodeOf[block][0] == entry
                let line = forward ? polylines[block] : polylines[block].reversed()
                coordinates.append(contentsOf: coordinates.isEmpty ? line[...] : line.dropFirst())
                let exit = forward ? nodeOf[block][1] : nodeOf[block][0]
                guard incident[exit].count == 2,
                      let next = incident[exit].first(where: { $0 != block }),
                      !visited[next]
                else { break }
                block = next
                entry = exit
            }
            result.append(WalkedRun(id: grid.physicalIDs[indices[first]], coordinates: coordinates))
        }
        // Runs start at dead ends and junctions first, then whatever is left
        // (closed loops) from its lowest id.
        for block in polylines.indices where !visited[block] {
            for end in 0 ... 1 where !visited[block] && incident[nodeOf[block][end]].count != 2 {
                walk(from: block, startNode: nodeOf[block][end])
            }
        }
        for block in polylines.indices where !visited[block] {
            walk(from: block, startNode: nodeOf[block][0])
        }
        return result
    }

    // MARK: Culling

    /// The runs whose bounding box meets the region expanded by 25% of its
    /// span on each side, or `overCap` past 2,000 (never a partial subset).
    static func visible(_ runs: [WalkedRun], in region: WalkedRegion) -> Visible {
        let halfLatitude = region.latitudeDelta * (0.5 + regionMargin)
        let halfLongitude = region.longitudeDelta * (0.5 + regionMargin)
        let minLatitude = region.centerLatitude - halfLatitude
        let maxLatitude = region.centerLatitude + halfLatitude
        let minLongitude = region.centerLongitude - halfLongitude
        let maxLongitude = region.centerLongitude + halfLongitude
        var kept: [WalkedRun] = []
        for run in runs
        where run.maxLatitude >= minLatitude && run.minLatitude <= maxLatitude
            && run.maxLongitude >= minLongitude && run.minLongitude <= maxLongitude {
            kept.append(run)
            if kept.count > maxVisibleRuns { return .overCap }
        }
        return .runs(kept)
    }

    // MARK: Stroke width (design D2)

    /// Up to 400 m of visible height 8pt, up to 2 km 5pt, up to 8 km 3pt,
    /// above that 2pt. Leaving a band takes 10% more height than entering it.
    static let widthBands: [(maxHeight: Double, width: Double)] = [(400, 8), (2_000, 5), (8_000, 3)]
    static let widestBeyond = 2.0
    static let hysteresis = 0.10

    static func lineWidth(visibleHeightMeters height: Double, current: Double?) -> Double {
        let entered = widthBands.first { height <= $0.maxHeight }?.width ?? widestBeyond
        guard let current, current > entered,
              let band = widthBands.first(where: { $0.width == current })
        else { return entered }
        // Zooming out from a thicker band: stay until 10% past its edge.
        return height <= band.maxHeight * (1 + hysteresis) ? current : entered
    }
}

/// Block endpoints as shared nodes: endpoints within the tolerance are one
/// node. `nodeOf[block]` is the block's start and end node, `incident[node]`
/// the blocks that end there.
nonisolated private struct EndpointGraph {
    private(set) var nodeOf: [[Int]] = []
    private(set) var incident: [[Int]] = []
    private var nodePoints: [Coordinate] = []
    private var buckets: [Int64: [Int]] = [:]
    private let tolerance: Double

    init(_ polylines: [[Coordinate]], tolerance: Double) {
        self.tolerance = tolerance
        for (block, line) in polylines.enumerated() {
            let ends = [node(for: line[0]), node(for: line[line.count - 1])]
            nodeOf.append(ends)
            for end in ends {
                while incident.count <= end { incident.append([]) }
                incident[end].append(block)
            }
        }
    }

    private mutating func node(for point: Coordinate) -> Int {
        // Cells as wide as the tolerance, so a match is in the 3x3 around.
        let row = Int((point.latitude * StreetGrid.metersPerDegreeLatitude / tolerance).rounded(.down))
        let column = Int((point.longitude * 84_400 / tolerance).rounded(.down))
        for rowOffset in -1 ... 1 {
            for columnOffset in -1 ... 1 {
                for candidate in buckets[Self.key(row + rowOffset, column + columnOffset)] ?? []
                where BlockMatcher.distance(nodePoints[candidate], point) <= tolerance {
                    return candidate
                }
            }
        }
        nodePoints.append(point)
        buckets[Self.key(row, column), default: []].append(nodePoints.count - 1)
        return nodePoints.count - 1
    }

    private static func key(_ row: Int, _ column: Int) -> Int64 {
        Int64(row) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: column)))
    }
}
