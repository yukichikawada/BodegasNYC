import Foundation
import MapKit

/// A piece's identity (#119): its tile and the lowest `physicalid` among its
/// blocks. Unique because each block is in exactly one tile and the
/// components within a tile are disjoint. Ordered by (tile, lowest id), the
/// stable draw order.
nonisolated struct WalkedPieceID: Hashable, Comparable, Sendable {
    let tile: Int64
    let lowestPhysicalID: UInt32

    static func < (lhs: WalkedPieceID, rhs: WalkedPieceID) -> Bool {
        (lhs.tile, lhs.lowestPhysicalID) < (rhs.tile, rhs.lowestPhysicalID)
    }
}

/// One connected patch of walked blocks inside one ~1 km tile, drawn as one
/// `MapPolyline` (#119): a walk over every block of the patch that retraces
/// where it turns back. `coordinates` are the drawn (simplified) vertices,
/// and the bounds are the piece's own, which may cross its tile's edge.
///
/// `@unchecked Sendable`: `MKPolyline` is never mutated after `init`.
nonisolated struct WalkedPiece: Identifiable, @unchecked Sendable, Equatable {
    let id: WalkedPieceID
    let coordinates: [Coordinate]
    let polyline: MKPolyline
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    var vertexCount: Int { coordinates.count }

    init(id: WalkedPieceID, walk: [Coordinate]) {
        self.id = id
        coordinates = WalkedOverlay.simplified(walk)
        minLatitude = coordinates.map(\.latitude).min() ?? 0
        maxLatitude = coordinates.map(\.latitude).max() ?? 0
        minLongitude = coordinates.map(\.longitude).min() ?? 0
        maxLongitude = coordinates.map(\.longitude).max() ?? 0
        let drawn = coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        polyline = MKPolyline(coordinates: drawn, count: drawn.count)
    }

    static func == (lhs: WalkedPiece, rhs: WalkedPiece) -> Bool {
        lhs.polyline === rhs.polyline || (lhs.id == rhs.id && lhs.coordinates == rhs.coordinates)
    }
}

/// The per-tile merge of #119 (spec Implementation 1 with eng D6-D8): tiles,
/// the block graph per tile, the covering walk per component, and pieces.
/// Pure and deterministic: the same walked set gives the same pieces in any
/// insertion order.
nonisolated enum WalkedTiles {
    /// About 1.0 x 1.0 km at NYC's latitude.
    static let tileLatitudeDegrees = 0.009
    static let tileLongitudeDegrees = 0.012

    /// One tile's walked blocks (ascending `physicalid`) and their pieces
    /// (ascending id). Kept by value across passes while the ids are equal,
    /// so its polylines keep their identity (eng D6).
    nonisolated struct Tile: Sendable, Equatable {
        let physicalIDs: [UInt32]
        let pieces: [WalkedPiece]
    }

    /// One step of a walk: a block (an index into the polylines handed to
    /// `walks`) traversed from its first vertex to its last, or back.
    nonisolated struct Step: Equatable, Sendable {
        let block: Int
        let forward: Bool
    }

    // MARK: Tiles

    static func tileKey(row: Int32, column: Int32) -> Int64 {
        Int64(row) << 32 | Int64(UInt32(bitPattern: column))
    }

    static func tileKey(for point: Coordinate) -> Int64 {
        tileKey(
            row: Int32((point.latitude / tileLatitudeDegrees).rounded(.down)),
            column: Int32((point.longitude / tileLongitudeDegrees).rounded(.down))
        )
    }

    /// The point at half the polyline's length: it decides the block's tile,
    /// so a block never changes tile and is in exactly one.
    static func halfLengthPoint(_ line: [Coordinate]) -> Coordinate {
        guard line.count > 1 else { return line.first ?? Coordinate(latitude: 0, longitude: 0) }
        let lengths = zip(line, line.dropFirst()).map { BlockMatcher.distance($0, $1) }
        var remaining = lengths.reduce(0, +) / 2
        for (offset, length) in lengths.enumerated() {
            if remaining <= length {
                let fraction = length > 0 ? remaining / length : 0
                let start = line[offset], end = line[offset + 1]
                return Coordinate(
                    latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                    longitude: start.longitude + (end.longitude - start.longitude) * fraction
                )
            }
            remaining -= length
        }
        return line[line.count - 1]
    }

    // MARK: Build

    /// Every walked block's tile, then each tile's pieces. A tile whose
    /// walked ids equal its entry in `previous` keeps that entry (same
    /// `MKPolyline` objects); every other tile is walked again, and a tile
    /// with no walked block is dropped (eng D6).
    static func build(
        walkedIDs: Set<UInt32>,
        grid: StreetGrid,
        previous: [Int64: Tile] = [:]
    ) -> (tiles: [Int64: Tile], rebuilt: Int) {
        var byTile: [Int64: [UInt32]] = [:]
        for physicalID in walkedIDs {
            guard let index = grid.index(ofPhysicalID: physicalID) else { continue }
            byTile[tileKey(for: halfLengthPoint(grid.polyline(for: index))), default: []].append(physicalID)
        }
        var tiles: [Int64: Tile] = [:]
        var rebuilt = 0
        for (key, unsorted) in byTile {
            let ids = unsorted.sorted()
            if let kept = previous[key], kept.physicalIDs == ids {
                tiles[key] = kept
            } else {
                tiles[key] = Tile(physicalIDs: ids, pieces: pieces(tile: key, physicalIDs: ids, grid: grid))
                rebuilt += 1
            }
        }
        return (tiles, rebuilt)
    }

    /// The pieces of one tile, ascending by lowest `physicalid`.
    /// `physicalIDs` must be ascending.
    static func pieces(tile: Int64, physicalIDs: [UInt32], grid: StreetGrid) -> [WalkedPiece] {
        let polylines = physicalIDs.compactMap { grid.index(ofPhysicalID: $0).map(grid.polyline(for:)) }
        guard polylines.count == physicalIDs.count else { return [] }
        return walks(polylines: polylines).map { steps in
            let lowest = steps.map { physicalIDs[$0.block] }.min() ?? 0
            return WalkedPiece(
                id: WalkedPieceID(tile: tile, lowestPhysicalID: lowest),
                walk: coordinates(of: steps, polylines: polylines)
            )
        }
        .sorted { $0.id < $1.id }
    }

    /// The walk's vertices: each step's block in its direction, joined at
    /// the shared node (the next block's first vertex is dropped, as runs
    /// do: the two ends are the same node, within the 1 m merge).
    static func coordinates(of steps: [Step], polylines: [[Coordinate]]) -> [Coordinate] {
        var result: [Coordinate] = []
        for step in steps {
            let line = polylines[step.block]
            let oriented = step.forward ? line : line.reversed()
            result.append(contentsOf: result.isEmpty ? oriented[...] : oriented.dropFirst())
        }
        return result
    }

    // MARK: Walk (eng D7, D8)

    /// One walk per connected component of the blocks' endpoint graph
    /// (endpoints within 1 m are one node, lowest-index node winning, eng
    /// D8), components in order of their lowest node. Each walk is a DFS
    /// out-and-back (eng D7): start at the component's lowest node, take
    /// untraversed blocks in ascending index (`physicalid`) order, walk each
    /// out and back (into a new node, the DFS continues there first), and
    /// drop the trailing return legs. Every block is traversed, never a
    /// street that is not walked, and the walk is at most twice the
    /// component's length. A self-loop is walked once.
    ///
    /// `polylines` are in ascending `physicalid` order.
    static func walks(polylines: [[Coordinate]]) -> [[Step]] {
        guard !polylines.isEmpty else { return [] }
        let graph = EndpointGraph(polylines, tolerance: WalkedOverlay.joinToleranceMeters, sortedInsertion: true)
        var blockDone = [Bool](repeating: false, count: polylines.count)
        var nodeSeen = [Bool](repeating: false, count: graph.nodeCount)
        var result: [[Step]] = []
        for start in 0 ..< graph.nodeCount where !nodeSeen[start] && !graph.incident[start].isEmpty {
            result.append(walk(from: start, graph: graph, blockDone: &blockDone, nodeSeen: &nodeSeen))
        }
        return result
    }

    private static func walk(
        from start: Int,
        graph: EndpointGraph,
        blockDone: inout [Bool],
        nodeSeen: inout [Bool]
    ) -> [Step] {
        var steps: [Step] = []
        var lastNew = -1
        // (node, next incident position, the step back to the parent)
        var stack: [(node: Int, next: Int, back: Step?)] = [(start, 0, nil)]
        nodeSeen[start] = true
        while let top = stack.last {
            let incident = graph.incident[top.node]
            guard top.next < incident.count else {
                stack.removeLast()
                if let back = top.back { steps.append(back) }
                continue
            }
            stack[stack.count - 1].next += 1
            let block = incident[top.next]
            guard !blockDone[block] else { continue }
            blockDone[block] = true
            let ends = graph.nodeOf[block]
            let forward = ends[0] == top.node
            let other = forward ? ends[1] : ends[0]
            steps.append(Step(block: block, forward: forward))
            lastNew = steps.count - 1
            if other == top.node { continue } // a self-loop ends where it began
            let back = Step(block: block, forward: !forward)
            if nodeSeen[other] {
                steps.append(back) // closes a cycle: out and straight back
            } else {
                nodeSeen[other] = true
                stack.append((other, 0, back))
            }
        }
        return Array(steps.prefix(lastNew + 1))
    }
}

/// The pieces plus the coarse spatial index over their own bounds (#119
/// Implementation 2, eng D5), built off the main actor with the summary.
/// Same cells as `WalkedRunIndex`. The probe draws every piece meeting the
/// region + 25%, uncapped (Phase 0 step 4).
nonisolated struct WalkedPieceIndex: Sendable, Equatable {
    let pieces: [WalkedPiece]
    let vertexCount: Int
    private let cells: [Int64: [Int32]]
    private let rowRange: ClosedRange<Int>
    private let columnRange: ClosedRange<Int>

    static let empty = WalkedPieceIndex(pieces: [])

    /// `pieces` in any order; the index keeps them in id order.
    init(pieces: [WalkedPiece]) {
        let sorted = pieces.sorted { $0.id < $1.id }
        self.pieces = sorted
        vertexCount = sorted.reduce(0) { $0 + $1.vertexCount }
        var cells: [Int64: [Int32]] = [:]
        var rows = (min: Int.max, max: Int.min), columns = (min: Int.max, max: Int.min)
        for (index, piece) in sorted.enumerated() {
            let pieceRows = Self.row(piece.minLatitude) ... Self.row(piece.maxLatitude)
            let pieceColumns = Self.column(piece.minLongitude) ... Self.column(piece.maxLongitude)
            rows = (min(rows.min, pieceRows.lowerBound), max(rows.max, pieceRows.upperBound))
            columns = (min(columns.min, pieceColumns.lowerBound), max(columns.max, pieceColumns.upperBound))
            for row in pieceRows {
                for column in pieceColumns {
                    cells[Self.key(row, column), default: []].append(Int32(index))
                }
            }
        }
        self.cells = cells
        rowRange = sorted.isEmpty ? 0 ... 0 : rows.min ... rows.max
        columnRange = sorted.isEmpty ? 0 ... 0 : columns.min ... columns.max
    }

    init(tiles: [Int64: WalkedTiles.Tile]) {
        self.init(pieces: tiles.values.flatMap(\.pieces))
    }

    /// Every piece whose own bounds meet the region expanded by 25% on each
    /// side, in id order.
    func visible(in region: WalkedRegion) -> [WalkedPiece] {
        guard !pieces.isEmpty else { return [] }
        let bounds = WalkedOverlay.expandedBounds(region)
        let firstRow = max(rowRange.lowerBound, Self.row(bounds.minLatitude))
        let lastRow = min(rowRange.upperBound, Self.row(bounds.maxLatitude))
        let firstColumn = max(columnRange.lowerBound, Self.column(bounds.minLongitude))
        let lastColumn = min(columnRange.upperBound, Self.column(bounds.maxLongitude))
        guard firstRow <= lastRow, firstColumn <= lastColumn else { return [] }
        var kept = Set<Int32>()
        for row in firstRow ... lastRow {
            for column in firstColumn ... lastColumn {
                for index in cells[Self.key(row, column)] ?? [] where !kept.contains(index) {
                    let piece = pieces[Int(index)]
                    if piece.maxLatitude >= bounds.minLatitude, piece.minLatitude <= bounds.maxLatitude,
                       piece.maxLongitude >= bounds.minLongitude, piece.minLongitude <= bounds.maxLongitude {
                        kept.insert(index)
                    }
                }
            }
        }
        return kept.sorted().map { pieces[Int($0)] }
    }

    static func == (lhs: WalkedPieceIndex, rhs: WalkedPieceIndex) -> Bool {
        lhs.pieces == rhs.pieces
    }

    private static func row(_ latitude: Double) -> Int {
        Int((latitude / WalkedRunIndex.cellLatitudeDegrees).rounded(.down))
    }

    private static func column(_ longitude: Double) -> Int {
        Int((longitude / WalkedRunIndex.cellLongitudeDegrees).rounded(.down))
    }

    private static func key(_ row: Int, _ column: Int) -> Int64 {
        Int64(row) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: column)))
    }
}
