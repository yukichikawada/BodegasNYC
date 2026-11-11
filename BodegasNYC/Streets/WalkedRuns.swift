import Foundation
import MapKit

/// A chain of walked blocks drawn as one `MapPolyline` (#108 eng R3): blocks
/// that share an endpoint (within 1 m) join, and the run is keyed by its
/// first block's `physicalid`, so its identity does not depend on position
/// in a list.
///
/// The run builds its `MKPolyline` once, from its coordinates with collinear
/// interior vertices dropped (`simplified`), and the map draws
/// `MapPolyline(run.polyline)`. The map's content list then holds one
/// reference per run instead of a coordinate array that SwiftUI copied and
/// diffed on every graph update during a gesture (the R3 device trace: 41
/// hitches up to 1.7 s, mostly memmove and value-witness copies in
/// `updateGraph`). A run whose geometry did not change keeps its polyline
/// object, so MapKit keeps its overlay across settles.
///
/// `@unchecked Sendable`: `MKPolyline` is never mutated after `init`.
nonisolated struct WalkedRun: Identifiable, @unchecked Sendable, Equatable {
    let id: UInt32
    let coordinates: [Coordinate]
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double
    let polyline: MKPolyline

    init(id: UInt32, coordinates: [Coordinate]) {
        self.id = id
        self.coordinates = coordinates
        minLatitude = coordinates.map(\.latitude).min() ?? 0
        maxLatitude = coordinates.map(\.latitude).max() ?? 0
        minLongitude = coordinates.map(\.longitude).min() ?? 0
        maxLongitude = coordinates.map(\.longitude).max() ?? 0
        let drawn = WalkedOverlay.simplified(coordinates).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        polyline = MKPolyline(coordinates: drawn, count: drawn.count)
    }

    static func == (lhs: WalkedRun, rhs: WalkedRun) -> Bool {
        lhs.polyline === rhs.polyline || (lhs.id == rhs.id && lhs.coordinates == rhs.coordinates)
    }
}

// Runs (#108 eng R3). Since #119 they carry only the breadcrumb dots at the 8
// and 5pt bands (owner decision 2026-11-10: the dots keep their per-run
// geometry, so the #154 look is unchanged); pieces draw everything else.
nonisolated extension WalkedOverlay {
    /// Chains the walked blocks into runs. Two blocks continue each other
    /// at a shared endpoint when they are the only two walked blocks there,
    /// or, at a junction, when each is the other's straightest continuation
    /// within `straightThroughDegrees` (an avenue walked across its cross
    /// streets is one run, not one per block). Deterministic: runs start at
    /// ends with no continuation, visiting blocks in `physicalid` order, then
    /// closed loops from their lowest id.
    static func runs(walkedIDs: Set<UInt32>, grid: StreetGrid) -> [WalkedRun] {
        let indices = walkedIDs.sorted().compactMap { grid.index(ofPhysicalID: $0) }
        guard !indices.isEmpty else { return [] }
        let chainer = RunChainer(polylines: indices.map { grid.polyline(for: $0) }, tolerance: joinToleranceMeters)
        return chainer.chains().map { chain in
            WalkedRun(id: grid.physicalIDs[indices[chain.first]], coordinates: chain.coordinates)
        }
    }

    /// The largest turn a run takes straight through a junction.
    static let straightThroughDegrees = 30.0

    /// The runs whose bounding box meets the region expanded by 25% of its
    /// span on each side, or nil past `cap` (never a partial subset). Scans
    /// every run: the reference for `WalkedRunIndex`, which the map uses.
    static func visibleRuns(_ runs: [WalkedRun], in region: WalkedRegion, cap: Int) -> [WalkedRun]? {
        let bounds = expandedBounds(region)
        var kept: [WalkedRun] = []
        for run in runs where meets(run, bounds) {
            kept.append(run)
            if kept.count > cap { return nil }
        }
        return kept
    }
}

/// Block endpoints as shared nodes: endpoints within the tolerance are one
/// node. `nodeOf[block]` is the block's start and end node, `incident[node]`
/// the blocks that end there.
///
/// `sortedInsertion` (#119 eng D8, `WalkedTiles`): endpoints are inserted in
/// (latitude, longitude, block) order rather than block order, and an
/// endpoint within the tolerance of several nodes joins the lowest-index
/// one, so the merge does not depend on scan order. `incident[node]` is then
/// in ascending block order. The runs keep the original insertion.
nonisolated struct EndpointGraph {
    private(set) var nodeOf: [[Int]] = []
    private(set) var incident: [[Int]] = []
    private var nodePoints: [Coordinate] = []
    private var buckets: [Int64: [Int]] = [:]
    private let tolerance: Double
    private let lowestWins: Bool

    var nodeCount: Int { nodePoints.count }

    init(_ polylines: [[Coordinate]], tolerance: Double, sortedInsertion: Bool = false) {
        self.tolerance = tolerance
        lowestWins = sortedInsertion
        guard sortedInsertion else {
            for (block, line) in polylines.enumerated() {
                let ends = [node(for: line[0]), node(for: line[line.count - 1])]
                nodeOf.append(ends)
                for end in ends {
                    while incident.count <= end { incident.append([]) }
                    incident[end].append(block)
                }
            }
            return
        }
        var endpoints: [Endpoint] = []
        endpoints.reserveCapacity(polylines.count * 2)
        for (block, line) in polylines.enumerated() {
            endpoints.append(Endpoint(point: line[0], block: block, end: 0))
            endpoints.append(Endpoint(point: line[line.count - 1], block: block, end: 1))
        }
        endpoints.sort {
            ($0.point.latitude, $0.point.longitude, $0.block, $0.end)
                < ($1.point.latitude, $1.point.longitude, $1.block, $1.end)
        }
        nodeOf = [[Int]](repeating: [0, 0], count: polylines.count)
        for endpoint in endpoints {
            nodeOf[endpoint.block][endpoint.end] = node(for: endpoint.point)
        }
        incident = [[Int]](repeating: [], count: nodePoints.count)
        for block in polylines.indices {
            for end in nodeOf[block] { incident[end].append(block) }
        }
    }

    private mutating func node(for point: Coordinate) -> Int {
        // Cells as wide as the tolerance, so a match is in the 3x3 around.
        let row = Int((point.latitude * StreetGrid.metersPerDegreeLatitude / tolerance).rounded(.down))
        let column = Int((point.longitude * 84_400 / tolerance).rounded(.down))
        var lowest: Int?
        for rowOffset in -1 ... 1 {
            for columnOffset in -1 ... 1 {
                for candidate in buckets[Self.key(row + rowOffset, column + columnOffset)] ?? []
                where BlockMatcher.distance(nodePoints[candidate], point) <= tolerance {
                    guard lowestWins else { return candidate }
                    lowest = min(lowest ?? candidate, candidate)
                }
            }
        }
        if let lowest { return lowest }
        nodePoints.append(point)
        buckets[Self.key(row, column), default: []].append(nodePoints.count - 1)
        return nodePoints.count - 1
    }

    private static func key(_ row: Int, _ column: Int) -> Int64 {
        Int64(row) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: column)))
    }

    private struct Endpoint {
        let point: Coordinate
        let block: Int
        let end: Int
    }
}

/// Pairs walked blocks at shared endpoints and walks the pairs into chains
/// (`WalkedOverlay.runs`).
nonisolated private struct RunChainer {
    let polylines: [[Coordinate]]
    let graph: EndpointGraph

    init(polylines: [[Coordinate]], tolerance: Double) {
        self.polylines = polylines
        graph = EndpointGraph(polylines, tolerance: tolerance)
    }

    func chains() -> [(first: Int, coordinates: [Coordinate])] {
        var visited = [Bool](repeating: false, count: polylines.count)
        var result: [(first: Int, coordinates: [Coordinate])] = []
        func walk(from first: Int, startNode: Int) {
            var coordinates: [Coordinate] = []
            var block = first
            var entry = startNode
            while true {
                visited[block] = true
                let forward = graph.nodeOf[block][0] == entry
                let line = forward ? polylines[block] : polylines[block].reversed()
                coordinates.append(contentsOf: coordinates.isEmpty ? line[...] : line.dropFirst())
                let exit = forward ? graph.nodeOf[block][1] : graph.nodeOf[block][0]
                guard let next = partner(of: block, at: exit), !visited[next] else { break }
                block = next
                entry = exit
            }
            result.append((first, coordinates))
        }
        for block in polylines.indices where !visited[block] {
            for end in 0 ... 1 where !visited[block] && partner(of: block, at: graph.nodeOf[block][end]) == nil {
                walk(from: block, startNode: graph.nodeOf[block][end])
            }
        }
        for block in polylines.indices where !visited[block] {
            walk(from: block, startNode: graph.nodeOf[block][0])
        }
        return result
    }

    /// The block that continues `block` through `node`, if any: the other one
    /// when exactly two meet there, else the mutual straightest continuation.
    func partner(of block: Int, at node: Int) -> Int? {
        let others = graph.incident[node].filter { $0 != block }
        if graph.incident[node].count == 2 { return others.first }
        guard let best = straightest(from: block, at: node, among: others) else { return nil }
        let back = straightest(from: best, at: node, among: graph.incident[node].filter { $0 != best })
        return back == block ? best : nil
    }

    private func straightest(from block: Int, at node: Int, among candidates: [Int]) -> Int? {
        let arriving = direction(of: block, at: node, leaving: false)
        var best: (block: Int, cosine: Double)?
        let threshold = cos(WalkedOverlay.straightThroughDegrees * .pi / 180)
        for candidate in candidates {
            let leaving = direction(of: candidate, at: node, leaving: true)
            let cosine = arriving.0 * leaving.0 + arriving.1 * leaving.1
            if cosine >= threshold, cosine > (best?.cosine ?? -2) { best = (candidate, cosine) }
        }
        return best?.block
    }

    /// A unit vector along `block` at `node`: pointing into the node when
    /// arriving, away from it when leaving.
    private func direction(of block: Int, at node: Int, leaving: Bool) -> (Double, Double) {
        let line = polylines[block]
        let atStart = graph.nodeOf[block][0] == node
        let end = atStart ? line[0] : line[line.count - 1]
        let inner = atStart ? line[min(1, line.count - 1)] : line[max(0, line.count - 2)]
        let scaleX = cos(end.latitude * .pi / 180)
        var deltaX = (inner.longitude - end.longitude) * scaleX
        var deltaY = inner.latitude - end.latitude
        if !leaving {
            deltaX = -deltaX
            deltaY = -deltaY
        }
        let length = (deltaX * deltaX + deltaY * deltaY).squareRoot()
        return length > 0 ? (deltaX / length, deltaY / length) : (0, 0)
    }
}
