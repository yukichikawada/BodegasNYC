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

/// What the walked layer draws: the visible runs (or over the cap) and the
/// stroke width. It changes only when the camera is at rest (design D10), so
/// nothing the Map's content reads changes during a pan or pinch (the R3
/// device trace showed a graph update on every mid-gesture region change).
nonisolated struct WalkedOverlayDisplay: Sendable, Equatable {
    var visible = WalkedOverlay.Visible.runs([])
    var lineWidth = WalkedOverlay.widestBeyond

    /// Recomputes for the current data and settled camera. While the camera
    /// moves it does nothing; the settle that ends the gesture calls it
    /// again. Culling reads the spatial index, so the cost follows the cells
    /// in view. Returns whether anything the map draws changed; when nothing
    /// did, the caller writes no state and the Map's content is not touched.
    @discardableResult
    mutating func refresh(
        index: WalkedRunIndex,
        showsOverlay: Bool,
        region: WalkedRegion?,
        visibleHeightMeters: Double?,
        isCameraMoving: Bool
    ) -> Bool {
        guard !isCameraMoving else { return false }
        let before = self
        if let visibleHeightMeters {
            lineWidth = WalkedOverlay.lineWidth(visibleHeightMeters: visibleHeightMeters, current: lineWidth)
        }
        if showsOverlay, let region {
            // Hysteresis (#113): lines already drawn stay while they meet
            // the retain margin, so a small pan swaps fewer overlays.
            visible = index.visible(in: region, keeping: visible)
        } else {
            visible = .runs([])
        }
        return self != before
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
    ///
    /// 1,000, lowered from the spec's 2,000 after the R3 device check (eng R3
    /// allows lowering on a measurement): views holding 1,087 to 2,000 runs
    /// hitched up to 1.7 s on an iPhone 17 Pro Max. With runs now chained
    /// straight through junctions, the 5,000-block QA seed is 581 runs in
    /// all and at most 381 in a 4 km view, and all of Manhattan walked holds
    /// at most 675 in an 8 km view, so 1,000 draws every Manhattan view and
    /// hides only near-citywide views of far larger histories (D3's card).
    static let maxVisibleRuns = 1_000
    /// The region is expanded by this fraction of its span on each side.
    static let regionMargin = 0.25
    /// Culling hysteresis (#113): a run already drawn stays while its box
    /// meets the region expanded by this fraction on each side; a new run
    /// enters only inside `regionMargin`. The cap is still decided on the
    /// `regionMargin` set alone, and retained runs only fill the room left
    /// under `maxVisibleRuns`, nearest first, so at most 1,000 runs are ever
    /// drawn (the R3 device ceiling).
    static let retainMargin = 0.75
    static let joinToleranceMeters = 1.0
    /// An interior vertex within this of the line through its neighbours is
    /// dropped from the drawn polyline: well under a point at the 8pt zoom.
    static let simplifyToleranceMeters = 0.5

    /// `coordinates` without collinear interior vertices: a vertex is kept
    /// only if it sits more than `simplifyToleranceMeters` off the segment
    /// from the last kept vertex to the next one. Ends are always kept. A
    /// run along a straight avenue draws as two points.
    static func simplified(_ coordinates: [Coordinate]) -> [Coordinate] {
        guard coordinates.count > 2 else { return coordinates }
        var kept = [coordinates[0]]
        for index in 1 ..< (coordinates.count - 1) {
            let anchor = kept[kept.count - 1]
            if offset(of: coordinates[index], fromSegment: anchor, coordinates[index + 1]) > simplifyToleranceMeters {
                kept.append(coordinates[index])
            }
        }
        kept.append(coordinates[coordinates.count - 1])
        return kept
    }

    /// Metres from `point` to the segment `start`-`end`, in the local plane.
    private static func offset(of point: Coordinate, fromSegment start: Coordinate, _ end: Coordinate) -> Double {
        let scaleX = cos(point.latitude * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator
        let scaleY = StreetGrid.metersPerDegreeLatitude
        let startX = (start.longitude - point.longitude) * scaleX
        let startY = (start.latitude - point.latitude) * scaleY
        let edgeX = (end.longitude - point.longitude) * scaleX - startX
        let edgeY = (end.latitude - point.latitude) * scaleY - startY
        let lengthSquared = edgeX * edgeX + edgeY * edgeY
        let along = lengthSquared > 0 ? min(1, max(0, -(startX * edgeX + startY * edgeY) / lengthSquared)) : 0
        let nearestX = startX + along * edgeX
        let nearestY = startY + along * edgeY
        return (nearestX * nearestX + nearestY * nearestY).squareRoot()
    }

    /// What the map draws at a settled camera.
    nonisolated enum Visible: Sendable, Equatable {
        case runs([WalkedRun])
        /// Over the cap: draw nothing and say "Zoom in to see your blocks."
        case overCap
    }

    // MARK: Runs

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

    // MARK: Culling

    /// The runs whose bounding box meets the region expanded by 25% of its
    /// span on each side, or `overCap` past `maxVisibleRuns` (never a partial
    /// subset). Scans every run: the reference for `WalkedRunIndex`, which
    /// the map uses.
    static func visible(_ runs: [WalkedRun], in region: WalkedRegion) -> Visible {
        let bounds = expandedBounds(region)
        var kept: [WalkedRun] = []
        for run in runs where meets(run, bounds) {
            kept.append(run)
            if kept.count > maxVisibleRuns { return .overCap }
        }
        return .runs(kept)
    }

    struct Bounds {
        var minLatitude: Double
        var maxLatitude: Double
        var minLongitude: Double
        var maxLongitude: Double
    }

    /// The region expanded by `margin` of its span on each side.
    static func expandedBounds(_ region: WalkedRegion, margin: Double = regionMargin) -> Bounds {
        let halfLatitude = region.latitudeDelta * (0.5 + margin)
        let halfLongitude = region.longitudeDelta * (0.5 + margin)
        return Bounds(
            minLatitude: region.centerLatitude - halfLatitude,
            maxLatitude: region.centerLatitude + halfLatitude,
            minLongitude: region.centerLongitude - halfLongitude,
            maxLongitude: region.centerLongitude + halfLongitude
        )
    }

    static func meets(_ run: WalkedRun, _ bounds: Bounds) -> Bool {
        run.maxLatitude >= bounds.minLatitude && run.minLatitude <= bounds.maxLatitude
            && run.maxLongitude >= bounds.minLongitude && run.minLongitude <= bounds.maxLongitude
    }

    /// How far `run`'s box lies from the region's centre, in region spans
    /// (the larger of the two axes; 0 when the box covers the centre): the
    /// order in which retained runs give way to the cap, farthest first.
    static func distance(of run: WalkedRun, from region: WalkedRegion) -> Double {
        let latitudeGap = max(0, run.minLatitude - region.centerLatitude, region.centerLatitude - run.maxLatitude)
        let longitudeGap = max(0, run.minLongitude - region.centerLongitude, region.centerLongitude - run.maxLongitude)
        return max(
            region.latitudeDelta > 0 ? latitudeGap / region.latitudeDelta : 0,
            region.longitudeDelta > 0 ? longitudeGap / region.longitudeDelta : 0
        )
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
