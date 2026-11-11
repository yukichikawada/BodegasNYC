//
//  WalkedTilesTests.swift
//  BodegasNYCTests
//
//  The per-tile merge of #119 (Phase 0 probe): tile assignment, the DFS
//  out-and-back walk (eng D7) over the endpoint graph (eng D8), the pieces
//  it draws, and the per-tile reuse (eng D6).
//

import Foundation
import MapKit
import Testing

@testable import BodegasNYC

struct WalkedTilesTests {
    private typealias F = StreetFixtures

    // MARK: Tiles

    /// protects=a tile key is (floor(lat / 0.009), floor(lon / 0.012)) with
    /// the column's bit pattern in the low 32 bits, so NYC's negative
    /// columns keep distinct keys; the half-length point of an L-shaped
    /// block is on its long leg;
    /// fails_when=a negative column is truncated toward zero or sign-extends
    /// into the row, or the half-length point is the vertex midpoint;
    /// no_claim=that 0.009 x 0.012 degrees is about 1 km (spec arithmetic).
    @Test func tileKeyAndHalfLengthPoint() {
        let point = Coordinate(latitude: 40.75, longitude: -73.99)
        let expected = Int64(4_527) << 32 | Int64(UInt32(bitPattern: Int32(-6_166)))
        #expect(WalkedTiles.tileKey(for: point) == expected)
        #expect(WalkedTiles.tileKey(row: 4_527, column: -6_166) != WalkedTiles.tileKey(row: 4_527, column: -6_165))
        #expect(WalkedTiles.tileKey(row: 4_527, column: -1) != WalkedTiles.tileKey(row: 4_526, column: -1))

        // 300 m east, then 100 m north: the half-length point (200 m in) is
        // on the east leg at x = 200.
        let line = [F.coordinate(x: 0, y: 0), F.coordinate(x: 300, y: 0), F.coordinate(x: 300, y: 100)]
        let half = WalkedTiles.halfLengthPoint(line)
        #expect(BlockMatcher.distance(half, F.coordinate(x: 200, y: 0)) < 0.01)
    }

    /// protects=a block crossing a tile edge belongs to exactly one tile,
    /// the one holding its half-length point, and is drawn there whole;
    /// fails_when=the block is drawn in both tiles, in neither, or clipped;
    /// no_claim=how seams look on the map (Phase 0 is the cost probe).
    @Test func aBlockOnATileEdgeIsInExactlyOneTile() {
        // The tile row edge north of the origin: latitude 4,528 x 0.009.
        let edgeY = (4_528 * WalkedTiles.tileLatitudeDegrees - F.originLatitude) * StreetGrid.metersPerDegreeLatitude
        let grid = StreetGrid(segments: [
            F.segment(1, [(0, edgeY - 30), (0, edgeY + 70)]), // half-length point north of the edge
            F.segment(2, [(500, edgeY - 70), (500, edgeY + 30)]) // south of it
        ])
        let tiles = WalkedTiles.build(walkedIDs: [1, 2], grid: grid).tiles
        #expect(tiles.count == 2)
        let north = WalkedTiles.tileKey(for: F.coordinate(x: 0, y: edgeY + 1))
        let south = WalkedTiles.tileKey(for: F.coordinate(x: 500, y: edgeY - 1))
        #expect(tiles[north]?.physicalIDs == [1])
        #expect(tiles[south]?.physicalIDs == [2])
        #expect(tiles[north]?.pieces.first?.coordinates.count == 2)
        #expect(tiles.values.flatMap(\.physicalIDs).sorted() == [1, 2])
    }

    // MARK: Walk

    /// protects=AC3/AC4 for the walk (eng D7): for a tree, a grid, a cycle,
    /// a single block, a T junction, disconnected parts, a self-loop and
    /// parallel blocks, every block is traversed, consecutive steps meet at
    /// a node, blocks of one walk are one component and no two walks share
    /// a node, and a walk is at most twice its component's length;
    /// fails_when=a block is missing or repeated across walks, the walk
    /// jumps between blocks that share no node, two parts merge into one
    /// walk, or the walk retraces more than out-and-back;
    /// no_claim=that the walk is the shortest covering walk (it is not:
    /// D7 trades length for simplicity) or the drawn look.
    @Test(arguments: WalkCase.allCases)
    func walkCoversEveryBlockOnce(_ walkCase: WalkCase) {
        let polylines = walkCase.polylines
        let walks = WalkedTiles.walks(polylines: polylines)
        #expect(walks.count == walkCase.components, "\(walkCase)")
        Self.expectCoveringWalks(walks, polylines: polylines, note: "\(walkCase)")
    }

    /// protects=AC3/AC4 on random subsets of a 6 x 6 block lattice (50
    /// seeded draws): same properties as the fixed cases;
    /// fails_when=any draw has a missing block, a jump, a merged or split
    /// component, or a walk over twice its length;
    /// no_claim=coverage of geometries other than a lattice (the seed test).
    @Test func walkCoversRandomLatticeSubsets() {
        var random = SplitMix(seed: 119)
        let lattice = Self.lattice(columns: 6, rows: 6)
        for draw in 0 ..< 50 {
            let kept = lattice.filter { _ in random.next() % 100 < 45 }
            guard !kept.isEmpty else { continue }
            let polylines = kept.sorted { $0.physicalID < $1.physicalID }.map(\.coordinates)
            Self.expectCoveringWalks(WalkedTiles.walks(polylines: polylines), polylines: polylines, note: "draw \(draw)")
        }
    }

    /// protects=determinism (spec testing plan): the same walked blocks in
    /// another grid order give identical pieces, ids and coordinates;
    /// fails_when=the node merge or the walk depends on the grid's index or
    /// the set's iteration order;
    /// no_claim=determinism across dataset versions.
    @Test func samePiecesInAnyOrder() {
        let lattice = Self.lattice(columns: 5, rows: 5)
        let walked = Set(lattice.map(\.physicalID).filter { $0 % 3 != 0 })
        let forward = WalkedTiles.build(walkedIDs: walked, grid: StreetGrid(segments: lattice)).tiles
        let backward = WalkedTiles.build(walkedIDs: walked, grid: StreetGrid(segments: lattice.reversed())).tiles
        #expect(forward.keys.sorted() == backward.keys.sorted())
        for key in forward.keys {
            #expect(forward[key]?.pieces.map(\.id) == backward[key]?.pieces.map(\.id))
            #expect(forward[key]?.pieces.map(\.coordinates) == backward[key]?.pieces.map(\.coordinates))
        }
    }

    // MARK: Pieces

    /// protects=AC3 on the drawn geometry: every vertex of every walked
    /// block lies on a piece (within the 0.5 m simplification), every drawn
    /// segment lies along walked blocks, and an unwalked block between
    /// walked ones is not drawn;
    /// fails_when=simplification or the join drops a walked block's
    /// stretch, or a piece draws across an unwalked block;
    /// no_claim=pixel equality with the run-based layer (AC7, after Go).
    @Test func piecesDrawEveryWalkedBlockAndNothingElse() {
        let lattice = Self.lattice(columns: 5, rows: 5)
        let unwalked: Set<UInt32> = [1_101, 2_202, 1_303, 2_000]
        let walked = Set(lattice.map(\.physicalID)).subtracting(unwalked)
        let grid = StreetGrid(segments: lattice)
        let pieces = WalkedTiles.build(walkedIDs: walked, grid: grid).tiles.values.flatMap(\.pieces)
        #expect(!pieces.isEmpty)
        for segment in lattice where walked.contains(segment.physicalID) {
            for vertex in segment.coordinates {
                #expect(pieces.contains { Self.distance(vertex, toLine: $0.coordinates) <= 0.6 }, "\(segment.physicalID)")
            }
        }
        let walkedLines = lattice.filter { walked.contains($0.physicalID) }.map(\.coordinates)
        for piece in pieces {
            for (start, end) in zip(piece.coordinates, piece.coordinates.dropFirst()) {
                let middle = Coordinate(
                    latitude: (start.latitude + end.latitude) / 2, longitude: (start.longitude + end.longitude) / 2
                )
                #expect(walkedLines.contains { Self.distance(middle, toLine: $0) <= 1.1 })
            }
        }
        for segment in lattice where unwalked.contains(segment.physicalID) {
            let middle = WalkedTiles.halfLengthPoint(segment.coordinates)
            #expect(!pieces.contains { Self.distance(middle, toLine: $0.coordinates) <= 1 }, "\(segment.physicalID)")
        }
    }

    /// protects=AC5 (eng D6): after a pass, only tiles whose walked ids
    /// changed are walked again; every other tile keeps its pieces'
    /// `MKPolyline` objects; a tile left with no walked block is dropped;
    /// fails_when=an unrelated tile gets new polylines (MapKit would swap
    /// its overlay), a changed tile keeps stale pieces, or an emptied tile
    /// lingers;
    /// no_claim=the store's reconcile path (covered through `WalkedSummary`
    /// in the next test) or MapKit's diffing on device.
    @Test func onlyChangedTilesAreRebuilt() {
        let tileWidthMeters = WalkedTiles.tileLongitudeDegrees * 84_400
        let near = Self.lattice(columns: 3, rows: 3, x: 50, y: 50)
        let far = Self.lattice(columns: 3, rows: 3, x: 50 + 3 * tileWidthMeters, y: 50, firstID: 10_000)
        let grid = StreetGrid(segments: near + far)
        let nearIDs = Set(near.map(\.physicalID)), farIDs = Set(far.map(\.physicalID))
        let first = WalkedTiles.build(walkedIDs: nearIDs.union(farIDs), grid: grid)
        let farTiles = Set(far.map { WalkedTiles.tileKey(for: WalkedTiles.halfLengthPoint($0.coordinates)) })
        let nearTiles = Set(near.map { WalkedTiles.tileKey(for: WalkedTiles.halfLengthPoint($0.coordinates)) })
        #expect(farTiles.isDisjoint(with: nearTiles))

        let dropped = nearIDs.sorted()[0]
        let second = WalkedTiles.build(walkedIDs: nearIDs.union(farIDs).subtracting([dropped]), grid: grid, previous: first.tiles)
        let droppedTile = WalkedTiles.tileKey(for: WalkedTiles.halfLengthPoint(near[0].coordinates))
        #expect(second.rebuilt == 1)
        for key in first.tiles.keys where key != droppedTile {
            let before = first.tiles[key]?.pieces ?? [], after = second.tiles[key]?.pieces ?? []
            #expect(before.count == after.count)
            #expect(zip(before, after).allSatisfy { $0.polyline === $1.polyline })
        }
        #expect(second.tiles[droppedTile]?.physicalIDs.contains(dropped) == false)

        let cleared = WalkedTiles.build(walkedIDs: nearIDs, grid: grid, previous: second.tiles)
        #expect(cleared.tiles.keys.allSatisfy { !farTiles.contains($0) })
        let empty = WalkedTiles.build(walkedIDs: [], grid: grid, previous: cleared.tiles)
        #expect(empty.tiles.isEmpty)
    }

    /// protects=the summary path the store uses: building against the last
    /// summary keeps unchanged tiles' polylines, and `reconciled(with:)` of
    /// an unchanged walked set keeps the previous piece index and version;
    /// fails_when=a pass that found nothing new hands the map new pieces;
    /// no_claim=the matching actor's threading.
    @Test func summaryReusesTilesAcrossPasses() {
        let lattice = Self.lattice(columns: 3, rows: 3)
        let grid = StreetGrid(segments: lattice)
        let masks = Dictionary(uniqueKeysWithValues: lattice.map { ($0.physicalID, UInt16(0x3FF)) })
        let first = WalkedSummary(masks: masks, grid: grid, previous: .empty).reconciled(with: .empty)
        #expect(!first.pieceIndex.pieces.isEmpty)
        let again = WalkedSummary(masks: masks, grid: grid, previous: first).reconciled(with: first)
        #expect(again.runsVersion == first.runsVersion)
        #expect(zip(first.pieceIndex.pieces, again.pieceIndex.pieces).allSatisfy { $0.polyline === $1.polyline })
    }

    /// protects=culling over pieces' own bounds (eng D5): the pieces meeting
    /// the region + 25% are returned in id order and nothing else, uncapped;
    /// fails_when=a piece far outside is drawn, a piece whose bounds meet the
    /// margin is missed, or the order depends on the cells' iteration;
    /// no_claim=the after-Go dual cap (eng D9).
    @Test func pieceCullingByOwnBounds() {
        let tileWidthMeters = WalkedTiles.tileLongitudeDegrees * 84_400
        let near = Self.lattice(columns: 2, rows: 2, x: 0, y: 0)
        let far = Self.lattice(columns: 2, rows: 2, x: 20 * tileWidthMeters, y: 0, firstID: 10_000)
        let grid = StreetGrid(segments: near + far)
        let tiles = WalkedTiles.build(walkedIDs: Set((near + far).map(\.physicalID)), grid: grid).tiles
        let index = WalkedPieceIndex(tiles: tiles)
        let center = F.coordinate(x: 100, y: 100)
        let region = WalkedRegion(
            centerLatitude: center.latitude, centerLongitude: center.longitude,
            latitudeDelta: 0.004, longitudeDelta: 0.004
        )
        let visible = index.visible(in: region)
        #expect(!visible.isEmpty)
        #expect(visible.map(\.id) == visible.map(\.id).sorted())
        let nearTiles = Set(near.map { WalkedTiles.tileKey(for: WalkedTiles.halfLengthPoint($0.coordinates)) })
        #expect(visible.allSatisfy { nearTiles.contains($0.id.tile) })
        #expect(visible.count == nearTiles.reduce(0) { $0 + (tiles[$1]?.pieces.count ?? 0) })
    }

    /// protects=the probe's numbers on real geometry: the first 5,006
    /// Manhattan blocks of the bundle (the order the #108 seed walk takes)
    /// as pieces against runs, logged; every walked block's vertices lie on
    /// a piece of its tile;
    /// fails_when=a real block (curved, odd endpoints) is not drawn, or the
    /// build throws;
    /// no_claim=the device seed's exact counts (it is matched from fixes),
    /// any timing, or a cap (Phase 0 measures it on device).
    @Test func seedSanityOnTheBundledGrid() throws {
        let grid = try StreetGrid.loadBundled()
        let walked = Set((0 ..< grid.segmentCount).lazy.filter { grid.borough(for: $0) == .manhattan }
            .prefix(5_006).map { grid.physicalIDs[$0] })
        let tiles = WalkedTiles.build(walkedIDs: walked, grid: grid).tiles
        let index = WalkedPieceIndex(tiles: tiles)
        let runs = WalkedOverlay.runs(walkedIDs: walked, grid: grid)
        let runVertices = runs.reduce(0) { $0 + $1.polyline.pointCount }
        let report = "seed \(walked.count) blocks: \(tiles.count) tiles, \(index.pieces.count) pieces, "
            + "\(index.vertexCount) piece vertices; \(runs.count) runs, \(runVertices) run vertices"
        print(report)
        #expect(tiles.values.reduce(0) { $0 + $1.physicalIDs.count } == walked.count)
        #expect(index.pieces.count <= runs.count)
        var missing = 0
        for tile in tiles.values {
            for physicalID in tile.physicalIDs {
                guard let block = grid.index(ofPhysicalID: physicalID) else { continue }
                for vertex in grid.polyline(for: block)
                where !tile.pieces.contains(where: { Self.distance(vertex, toLine: $0.coordinates) <= 1.1 }) {
                    missing += 1
                }
            }
        }
        #expect(missing == 0, "\(report)")
    }

    // MARK: Helpers

    enum WalkCase: CaseIterable, CustomStringConvertible {
        case single, tJunction, tree, cycle, grid, disconnected, selfLoop, parallel

        var description: String { "\(self.self)" }

        var components: Int { self == .disconnected ? 2 : 1 }

        /// The blocks in ascending `physicalid` order, as `walks` takes them.
        var polylines: [[Coordinate]] {
            let lines: [[(Double, Double)]]
            switch self {
            case .grid:
                return WalkedTilesTests.lattice(columns: 3, rows: 3)
                    .sorted { $0.physicalID < $1.physicalID }.map(\.coordinates)
            case .single: lines = [[(0, 0), (100, 0)]]
            case .tJunction: lines = [[(0, 0), (100, 0)], [(100, 0), (200, 0)], [(100, 0), (100, 80)]]
            case .tree:
                lines = [[(0, 0), (100, 0)], [(100, 0), (200, 0)], [(100, 0), (100, 80)], [(100, 80), (100, 160)],
                         [(100, 80), (180, 80)], [(200, 0), (200, -80)]]
            case .cycle: lines = [[(0, 0), (100, 0)], [(100, 0), (100, 80)], [(100, 80), (0, 80)], [(0, 80), (0, 0)]]
            case .disconnected: lines = [[(0, 0), (100, 0)], [(100, 0), (100, 80)], [(400, 0), (500, 0)]]
            case .selfLoop: lines = [[(0, 0), (100, 0)], [(100, 0), (150, 50), (100, 100), (50, 50), (100, 0.5)]]
            case .parallel: lines = [[(0, 0), (100, 0)], [(0, 0), (50, 20), (100, 0)], [(100, 0), (200, 0)]]
            }
            return lines.map { $0.map { F.coordinate(x: $0.0, y: $0.1) } }
        }
    }

    /// Blocks of a `columns` x `rows` lattice of 100 m squares from (x, y):
    /// east-going blocks from `firstID + 1_000`, north-going from
    /// `firstID + 2_000`, by row and column.
    static func lattice(
        columns: Int, rows: Int, x originX: Double = 0, y originY: Double = 0, firstID: UInt32 = 0
    ) -> [StreetGrid.Segment] {
        var segments: [StreetGrid.Segment] = []
        for row in 0 ... rows {
            for column in 0 ... columns {
                let px = originX + Double(column) * 100, py = originY + Double(row) * 100
                if column < columns {
                    segments.append(F.segment(firstID + 1_000 + UInt32(row * 100 + column), [(px, py), (px + 100, py)]))
                }
                if row < rows {
                    segments.append(F.segment(firstID + 2_000 + UInt32(row * 100 + column), [(px, py), (px, py + 100)]))
                }
            }
        }
        return segments
    }

    /// The covering-walk properties shared by the walk tests.
    private static func expectCoveringWalks(_ walks: [[WalkedTiles.Step]], polylines: [[Coordinate]], note: String) {
        let blocks = walks.flatMap { $0.map(\.block) }
        #expect(Set(blocks) == Set(polylines.indices), "\(note): every block traversed")
        func start(_ step: WalkedTiles.Step) -> Coordinate {
            step.forward ? polylines[step.block][0] : polylines[step.block][polylines[step.block].count - 1]
        }
        func end(_ step: WalkedTiles.Step) -> Coordinate {
            step.forward ? polylines[step.block][polylines[step.block].count - 1] : polylines[step.block][0]
        }
        var endpointsByWalk: [[Coordinate]] = []
        for walk in walks {
            for (step, next) in zip(walk, walk.dropFirst()) {
                #expect(BlockMatcher.distance(end(step), start(next)) <= 1, "\(note): consecutive steps meet")
            }
            let length = walk.reduce(0.0) { $0 + Self.length(polylines[$1.block]) }
            let component = Set(walk.map(\.block)).reduce(0.0) { $0 + Self.length(polylines[$1]) }
            #expect(length <= 2 * component + 0.001, "\(note): at most out and back")
            endpointsByWalk.append(walk.flatMap { [start($0), end($0)] })
        }
        for first in endpointsByWalk.indices {
            for second in endpointsByWalk.indices where second > first {
                let touching = endpointsByWalk[first].contains { point in
                    endpointsByWalk[second].contains { BlockMatcher.distance($0, point) <= 1 }
                }
                #expect(!touching, "\(note): walks are separate components")
            }
        }
        var owner: [Int: Int] = [:]
        for (walkIndex, walk) in walks.enumerated() {
            for step in walk {
                #expect(owner[step.block, default: walkIndex] == walkIndex, "\(note): a block in one walk only")
                owner[step.block] = walkIndex
            }
        }
    }

    private static func length(_ line: [Coordinate]) -> Double {
        zip(line, line.dropFirst()).reduce(0) { $0 + BlockMatcher.distance($1.0, $1.1) }
    }

    /// Metres from `point` to the nearest segment of `line`, in the local plane.
    static func distance(_ point: Coordinate, toLine line: [Coordinate]) -> Double {
        let scaleX = cos(point.latitude * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator
        let scaleY = StreetGrid.metersPerDegreeLatitude
        func plane(_ coordinate: Coordinate) -> (Double, Double) {
            ((coordinate.longitude - point.longitude) * scaleX, (coordinate.latitude - point.latitude) * scaleY)
        }
        guard line.count > 1 else { return line.first.map { BlockMatcher.distance($0, point) } ?? .infinity }
        var best = Double.infinity
        for (start, end) in zip(line, line.dropFirst()) {
            let (ax, ay) = plane(start), (bx, by) = plane(end)
            let dx = bx - ax, dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            let along = lengthSquared > 0 ? min(1, max(0, -(ax * dx + ay * dy) / lengthSquared)) : 0
            let nx = ax + along * dx, ny = ay + along * dy
            best = min(best, (nx * nx + ny * ny).squareRoot())
        }
        return best
    }
}

/// A seeded generator, so the random lattice draws repeat.
private struct SplitMix {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
