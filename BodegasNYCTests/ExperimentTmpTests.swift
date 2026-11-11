// Scratch (experiment branch): counts per piece variant.
import Foundation
import MapKit
import Testing

@testable import BodegasNYC

struct ExperimentTmpTests {
    @Test func variantCounts() throws {
        let grid = try StreetGrid.loadBundled()
        let center = Coordinate(latitude: 40.7308, longitude: -73.9973)
        let capture = Set((0 ..< grid.segmentCount)
            .filter { grid.borough(for: $0) == .manhattan }
            .map { ($0, BlockMatcher.distance(WalkedTiles.halfLengthPoint(grid.polyline(for: $0)), center)) }
            .sorted { $0.1 < $1.1 }.prefix(1_500).map { grid.physicalIDs[$0.0] })
        let seed = Set(WalkedSeedFixture.physicalIDs)
        let panRegion = WalkedRegion(
            centerLatitude: 40.7128, centerLongitude: -74.0060,
            latitudeDelta: 5_200 / StreetGrid.metersPerDegreeLatitude,
            longitudeDelta: 5_200 * 402 / 874 / (cos(40.7128 * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator)
        )
        let allRegion = WalkedRegion(centerLatitude: 40.72, centerLongitude: -73.99, latitudeDelta: 0.3, longitudeDelta: 0.3)
        for variant in ["current", "split250", "split100", "split50", "split25", "uturn", "turn60", "trails"] {
            var line = "VARIANT \(variant)"
            for (name, ids) in [("capture", capture), ("seed", seed)] {
                let index = WalkedPieceIndex(tiles: WalkedTiles.build(walkedIDs: ids, grid: grid, variant: variant).tiles)
                line += " | \(name): \(index.pieces.count) pieces, \(index.vertexCount) vertices"
                if name == "seed" {
                    let pan = index.visible(in: panRegion), all = index.visible(in: allRegion)
                    line += "; pan 5.2 km \(pan.count) pieces / \(pan.reduce(0) { $0 + $1.vertexCount }) v"
                    line += "; all \(all.count) / \(all.reduce(0) { $0 + $1.vertexCount }) v"
                }
            }
            print(line)
        }
        // Lower bound for edge-disjoint trails per tile: per component,
        // max(1, odd nodes / 2).
        var bound = 0
        var byTile: [Int64: [UInt32]] = [:]
        for id in seed {
            guard let index = grid.index(ofPhysicalID: id) else { continue }
            byTile[WalkedTiles.tileKey(for: WalkedTiles.halfLengthPoint(grid.polyline(for: index))), default: []].append(id)
        }
        for (_, ids) in byTile {
            let lines = ids.sorted().compactMap { grid.index(ofPhysicalID: $0).map(grid.polyline(for:)) }
            let graph = EndpointGraph(lines, tolerance: 1, sortedInsertion: true)
            for steps in WalkedTiles.walks(polylines: lines) {
                var nodes = Set<Int>()
                for step in steps { nodes.formUnion(graph.nodeOf[step.block]) }
                let odd = nodes.filter { graph.incident[$0].count % 2 == 1 }.count
                bound += max(1, odd / 2)
            }
        }
        print("VARIANT trails lower bound on seed: \(bound)")
        let runs = WalkedRunIndex(runs: WalkedOverlay.runs(walkedIDs: seed, grid: grid))
        let panRuns = runs.visible(in: panRegion, cap: .max) ?? []
        print("VARIANT runs seed pan 5.2 km \(panRuns.count) runs / \(panRuns.reduce(0) { $0 + $1.polyline.pointCount }) v; capture runs \(WalkedOverlay.runs(walkedIDs: capture, grid: grid).count)")
    }
}
