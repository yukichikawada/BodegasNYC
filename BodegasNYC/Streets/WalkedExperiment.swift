import Foundation

/// #119 stray-curve experiment (scratch branch, not for merge): how pieces
/// are cut, chosen at launch with `-WalkedPieceVariant <name>`:
/// `current` (500-vertex parts), `split250/100/50/25`, `uturn` (cut at
/// every reversal), `turn60` (cut at every turn over 60 degrees), `trails`
/// (each block drawn once: greedy edge-disjoint trails, no retrace).
/// Rendering switches: `-WalkedPolylineFromCoordinates YES`,
/// `-WalkedMiterJoin YES`.
nonisolated enum WalkedExperiment {
    static let variant = UserDefaults.standard.string(forKey: "WalkedPieceVariant") ?? "current"
    static let fromCoordinates = UserDefaults.standard.bool(forKey: "WalkedPolylineFromCoordinates")
    static let miterJoin = UserDefaults.standard.bool(forKey: "WalkedMiterJoin")

    /// The drawn parts of one tile's blocks for `variant`.
    static func parts(polylines: [[Coordinate]], simplified: [[Coordinate]], variant: String) -> [[[Coordinate]]] {
        switch variant {
        case "trails":
            return trails(polylines: polylines).map { [WalkedOverlay.simplified(WalkedTiles.coordinates(of: $0, polylines: simplified))] }
        default:
            return WalkedTiles.walks(polylines: polylines).map { steps in
                let walk = WalkedOverlay.simplified(WalkedTiles.coordinates(of: steps, polylines: simplified))
                switch variant {
                case "split250": return split(walk, 250)
                case "split100": return split(walk, 100)
                case "split50": return split(walk, 50)
                case "split25": return split(walk, 25)
                case "uturn": return cutAtTurns(walk, degrees: 150).flatMap { split($0, 500) }
                case "turn60": return cutAtTurns(walk, degrees: 60).flatMap { split($0, 500) }
                default: return split(walk, 500)
                }
            }
        }
    }

    static func split(_ walk: [Coordinate], _ limit: Int) -> [[Coordinate]] {
        guard walk.count > limit else { return [walk] }
        var parts: [[Coordinate]] = []
        var start = 0
        while start < walk.count - 1 {
            let end = min(walk.count, start + limit)
            parts.append(Array(walk[start ..< end]))
            start = end - 1
        }
        return parts
    }

    /// Cuts `walk` at every interior vertex where the direction turns by
    /// more than `degrees` (180 is a full reversal), parts sharing the vertex.
    static func cutAtTurns(_ walk: [Coordinate], degrees: Double) -> [[Coordinate]] {
        guard walk.count > 2 else { return [walk] }
        let threshold = cos(degrees * .pi / 180)
        var parts: [[Coordinate]] = []
        var current = [walk[0]]
        for index in 1 ..< walk.count - 1 {
            current.append(walk[index])
            let incoming = direction(walk[index - 1], walk[index]), outgoing = direction(walk[index], walk[index + 1])
            if incoming.0 * outgoing.0 + incoming.1 * outgoing.1 < threshold {
                parts.append(current)
                current = [walk[index]]
            }
        }
        current.append(walk[walk.count - 1])
        parts.append(current)
        return parts
    }

    private static func direction(_ from: Coordinate, _ to: Coordinate) -> (Double, Double) {
        let east = (to.longitude - from.longitude) * cos(from.latitude * .pi / 180)
        let north = to.latitude - from.latitude
        let length = (east * east + north * north).squareRoot()
        return length > 0 ? (east / length, north / length) : (1, 0)
    }

    /// Edge-disjoint trails covering every block once: start at the lowest
    /// node with an odd number of unused blocks (else any unused block), take
    /// the lowest unused block each time, stop when the node has none left.
    static func trails(polylines: [[Coordinate]]) -> [[WalkedTiles.Step]] {
        let graph = EndpointGraph(polylines, tolerance: WalkedOverlay.joinToleranceMeters, sortedInsertion: true)
        var used = [Bool](repeating: false, count: polylines.count)
        var unusedAt = graph.incident.map { $0.count }
        var result: [[WalkedTiles.Step]] = []
        while used.contains(false) {
            let start = (0 ..< graph.nodeCount).first { unusedAt[$0] % 2 == 1 }
                ?? (0 ..< graph.nodeCount).first { unusedAt[$0] > 0 }!
            var node = start
            var trail: [WalkedTiles.Step] = []
            while let block = graph.incident[node].first(where: { !used[$0] }) {
                used[block] = true
                let ends = graph.nodeOf[block]
                let forward = ends[0] == node
                let other = forward ? ends[1] : ends[0]
                unusedAt[ends[0]] -= 1
                unusedAt[ends[1]] -= 1
                trail.append(WalkedTiles.Step(block: block, forward: forward))
                node = other
            }
            result.append(trail)
        }
        return result
    }
}
