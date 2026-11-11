//
//  WalkedPieceCapTests.swift
//  BodegasNYCTests
//
//  The #119 walked-layer cap and what it must never hide: the dual cap
//  (eng D9), its hysteresis (design DS2), the named states (DS6), the
//  visibility floor against main's run caps (DS1), and the close-zoom
//  guarantee (eng D10, design DS10), on fixtures and on the device seed
//  (`WalkedSeedFixture`).
//

import Foundation
import MapKit
import Testing

@testable import BodegasNYC

struct WalkedPieceCapTests {
    private typealias F = StreetFixtures

    // MARK: Dual cap and hysteresis

    /// protects=eng D9 and design DS2 as numbers: the layer hides when
    /// pieces OR vertices pass their cap by 10% while drawing, and draws
    /// again only when both are 10% under while hidden; the caps are 1,000
    /// pieces and 9,000 vertices (Phase 0: 9,616 vertices measured, rounded
    /// down to a multiple of 1,000);
    /// fails_when=only one count is capped, the hysteresis is missing or
    /// reversed, or a cap drifts from the recorded measurement;
    /// no_claim=the device cost at 9,900 vertices (Phase 0 measured up to
    /// 9,616; the PR's device re-run, eng D4).
    @Test func dualCapWithTenPercentHysteresis() {
        #expect(WalkedOverlay.maxDrawnVertices == 9_000)
        #expect(WalkedOverlay.maxDrawnPieces == 1_000)
        // Drawing: hides only past 9,900 vertices or 1,100 pieces.
        #expect(!WalkedOverlay.isOverCap(pieces: 10, vertices: 9_900, wasHidden: false))
        #expect(WalkedOverlay.isOverCap(pieces: 10, vertices: 9_901, wasHidden: false))
        #expect(!WalkedOverlay.isOverCap(pieces: 1_100, vertices: 100, wasHidden: false))
        #expect(WalkedOverlay.isOverCap(pieces: 1_101, vertices: 100, wasHidden: false))
        // Hidden: draws again only at or under 8,100 vertices and 900 pieces.
        #expect(WalkedOverlay.isOverCap(pieces: 10, vertices: 8_101, wasHidden: true))
        #expect(!WalkedOverlay.isOverCap(pieces: 10, vertices: 8_100, wasHidden: true))
        #expect(WalkedOverlay.isOverCap(pieces: 901, vertices: 100, wasHidden: true))
        #expect(!WalkedOverlay.isOverCap(pieces: 900, vertices: 8_100, wasHidden: true))
    }

    /// protects=design DS2 on the display: panning back and forth across
    /// the threshold does not flicker. A view holding 9,500 vertices draws
    /// when arrived at from a drawing view and stays hidden when arrived at
    /// from a hidden one; only a view under 8,100 brings the layer back; the
    /// hidden state draws nothing at all, never a subset;
    /// fails_when=the layer flips at every crossing, a hidden layer returns
    /// above 8,100, or over the cap a subset is drawn;
    /// no_claim=how the card reads (MapBottomCard tests, DS7/DS8 QA).
    @Test func panningAcrossTheThresholdDoesNotFlicker() {
        let index = WalkedLayerIndex(
            pieces: WalkedPieceIndex(pieces: [
                Self.piece(tile: 1, x: 0, vertices: 8_000),
                Self.piece(tile: 2, x: 3_000, vertices: 1_500),
                Self.piece(tile: 3, x: 6_000, vertices: 500)
            ]),
            runs: .empty
        )
        let closeOnFirst = Self.region(x: 0, width: 1_000) // 8,000
        let firstTwo = Self.region(x: 1_500, width: 4_000) // 9,500
        let allThree = Self.region(x: 3_000, width: 8_000) // 10,000
        var display = WalkedOverlayDisplay()
        func settle(_ region: WalkedRegion) -> WalkedOverlay.Visible {
            display.refresh(index: index, showsOverlay: true, region: region, visibleHeightMeters: 5_000, isCameraMoving: false)
            return display.visible
        }
        #expect(Self.vertices(settle(firstTwo)) == 9_500)
        #expect(settle(allThree) == .overCap)
        #expect(settle(firstTwo) == .overCap)
        #expect(settle(allThree) == .overCap)
        #expect(Self.vertices(settle(closeOnFirst)) == 8_000)
        #expect(Self.vertices(settle(firstTwo)) == 9_500)
        #expect(settle(allThree) == .overCap)
    }

    /// protects=design DS6's named states: an empty index (the first build,
    /// a Clear, a rebuild in progress) is nothing to draw and never over the
    /// cap, even from a hidden layer; Show on Map off draws nothing and
    /// resets the cap, so turning it back on over a view the drawing layer
    /// may hold draws with no card flash;
    /// fails_when=an empty index reads as over the cap, or Show on Map off
    /// and on keeps a stale hidden state;
    /// no_claim=the announcement on Clear (StreetsWalkedViewModel tests) or
    /// the card's precedence (MapBottomCard tests).
    @Test func emptyOrOffIsNeverOverTheCap() {
        let full = WalkedLayerIndex(
            pieces: WalkedPieceIndex(pieces: [
                Self.piece(tile: 1, x: 0, vertices: 8_000), Self.piece(tile: 2, x: 3_000, vertices: 1_500),
                Self.piece(tile: 3, x: 6_000, vertices: 500)
            ]),
            runs: .empty
        )
        var display = WalkedOverlayDisplay()
        display.refresh(index: full, showsOverlay: true, region: Self.region(x: 3_000, width: 8_000), visibleHeightMeters: 5_000, isCameraMoving: false)
        #expect(display.visible == .overCap)
        display.refresh(index: .empty, showsOverlay: true, region: Self.region(x: 3_000, width: 8_000), visibleHeightMeters: 5_000, isCameraMoving: false)
        #expect(display.visible == .empty)

        display.refresh(index: full, showsOverlay: true, region: Self.region(x: 3_000, width: 8_000), visibleHeightMeters: 5_000, isCameraMoving: false)
        #expect(display.visible == .overCap)
        display.refresh(index: full, showsOverlay: false, region: Self.region(x: 3_000, width: 8_000), visibleHeightMeters: 5_000, isCameraMoving: false)
        #expect(display.visible == .empty)
        display.refresh(index: full, showsOverlay: true, region: Self.region(x: 1_500, width: 4_000), visibleHeightMeters: 5_000, isCameraMoving: false)
        #expect(Self.vertices(display.visible) == 9_500)
    }

    /// protects=design DS1's second floor: 1,000 isolated walked blocks in
    /// one view draw as 1,000 pieces (with the dots at 5pt, and as a line at
    /// 3pt), never the card;
    /// fails_when=the piece cap or the dots' run cap hides 1,000 isolated
    /// blocks;
    /// no_claim=the frame rate at 1,000 pieces (the PR's device re-run).
    @Test func aThousandIsolatedPiecesDraw() {
        let segments: [StreetGrid.Segment] = (0 ..< 1_000).map { (index: Int) -> StreetGrid.Segment in
            let x = Double(index % 40) * 60
            let y = Double(index / 40) * 60
            return F.segment(UInt32(index + 1), [(x, y), (x + 30, y)])
        }
        let grid = StreetGrid(segments: segments)
        let ids = Set(segments.map(\.physicalID))
        let index = WalkedLayerIndex(
            pieces: WalkedPieceIndex(tiles: WalkedTiles.build(walkedIDs: ids, grid: grid).tiles),
            runs: WalkedRunIndex(runs: WalkedOverlay.runs(walkedIDs: ids, grid: grid))
        )
        let center = F.coordinate(x: 1_200, y: 750)
        let region = WalkedRegion(centerLatitude: center.latitude, centerLongitude: center.longitude, latitudeDelta: 0.03, longitudeDelta: 0.04)
        let line = WalkedOverlay.visible(index: index, in: region, style: .line(width: 3), wasHidden: false)
        guard case .pieces(let pieces, _) = line else {
            Issue.record("1,000 isolated pieces hid at 3pt")
            return
        }
        #expect(pieces.count == 1_000)
        // Breadcrumbs: 1,000 dot runs are over the dots' 500-run cap, which
        // is #154's rule and hid the same view on main; the floor is held at
        // the line bands, where main drew them.
        let crumbs = WalkedOverlay.visible(index: index, in: region, style: WalkedOverlay.trailStyle(width: 5), wasHidden: false)
        #expect(crumbs == .overCap)
    }

    // MARK: Device seed

    /// The device seed's walked layer, built once.
    private static let seed: (grid: StreetGrid, layer: WalkedLayerIndex, tiles: [Int64: WalkedTiles.Tile])? = {
        guard let grid = try? StreetGrid.loadBundled() else { return nil }
        let ids = Set(WalkedSeedFixture.physicalIDs)
        let tiles = WalkedTiles.build(walkedIDs: ids, grid: grid).tiles
        let layer = WalkedLayerIndex(
            pieces: WalkedPieceIndex(tiles: tiles),
            runs: WalkedRunIndex(runs: WalkedOverlay.runs(walkedIDs: ids, grid: grid))
        )
        return (grid, layer, tiles)
    }()

    /// protects=the AC3 seed test (eng D11): on the device seed the pieces
    /// number fewer than a fifth of its runs, each piece holds at most
    /// `maxPieceVertices`, and the totals are logged for the DESIGN.md
    /// record;
    /// fails_when=the merge leaves the seed fragmented (pieces at least a
    /// fifth of runs), or a piece exceeds the split bound;
    /// no_claim=device cost (Phase 0 and the PR's re-run).
    @Test func seedPiecesAreUnderAFifthOfItsRuns() throws {
        let seed = try #require(Self.seed)
        let pieces = seed.layer.pieces.pieces
        let runs = seed.layer.runs.runs
        print("SEED \(WalkedSeedFixture.physicalIDs.count) blocks: \(seed.tiles.count) tiles, \(pieces.count) pieces, "
            + "\(seed.layer.pieces.vertexCount) piece vertices, largest \(pieces.map(\.vertexCount).max() ?? 0); "
            + "\(runs.count) runs, \(runs.reduce(0) { $0 + $1.polyline.pointCount }) run vertices")
        #expect(pieces.count * 5 < runs.count)
        #expect(pieces.allSatisfy { $0.vertexCount <= WalkedTiles.maxPieceVertices })
    }

    /// protects=design DS1, the visibility floor, on the device seed: at
    /// every camera of a grid over the seed (visible heights from 300 m to
    /// 29 km, portrait and landscape, centres across the seed and its
    /// edges), wherever main's run caps (1,000 runs, 500 at breadcrumbs)
    /// drew, the #119 layer draws too, starting from a drawing layer;
    /// fails_when=the 9,000-vertex cap (or the piece cap) hides a camera
    /// that draws on main;
    /// no_claim=cameras arrived at from a hidden layer, where DS2's 10%
    /// hysteresis delays the redraw by design, or histories other than the
    /// seed.
    @Test func everySeedCameraThatDrawsOnMainStillDraws() throws {
        let seed = try #require(Self.seed)
        let bounds = Self.bounds(seed.layer.pieces.pieces)
        var checked = 0, mostVertices = 0
        for height in [300.0, 440, 1_000, 2_000, 2_200, 4_000, 8_000, 16_000, 28_800] {
            for aspect in [402.0 / 874, 874.0 / 402] {
                for latFraction in stride(from: -0.1, through: 1.1, by: 0.2) {
                    for lonFraction in stride(from: -0.1, through: 1.1, by: 0.2) {
                        let region = Self.region(
                            latitude: bounds.minLatitude + (bounds.maxLatitude - bounds.minLatitude) * latFraction,
                            longitude: bounds.minLongitude + (bounds.maxLongitude - bounds.minLongitude) * lonFraction,
                            height: height, aspect: aspect
                        )
                        let style = WalkedOverlay.trailStyle(width: WalkedOverlay.lineWidth(visibleHeightMeters: height, current: nil))
                        let mainCap: Int = if case .breadcrumbs = style { 500 } else { 1_000 }
                        let mainDraws = seed.layer.runs.visible(in: region, cap: mainCap) != nil
                        let visible = WalkedOverlay.visible(index: seed.layer, in: region, style: style, wasHidden: false)
                        mostVertices = max(mostVertices, Self.vertices(visible) ?? 0)
                        checked += 1
                        if mainDraws {
                            #expect(visible != .overCap, "hidden at \(height) m, aspect \(aspect), \(latFraction), \(lonFraction)")
                        }
                    }
                }
            }
        }
        print("DS1 floor: \(checked) cameras, most piece vertices drawn \(mostVertices)")
    }

    /// protects=eng D10 and design DS10: at a visible height of 440 m or
    /// less, just below, at and just above it, over the densest seed tile's
    /// interior, a tile edge and a tile corner, portrait and landscape, and
    /// over fragmented history and all of Manhattan walked, the drawn set
    /// stays inside the caps themselves (no hysteresis slack), so the card
    /// never shows at close zoom; the guarantee comes from splitting long
    /// walks, not from switching the cap off;
    /// fails_when=a close view draws over 1,000 pieces or 9,000 vertices,
    /// or the split stops bounding a piece;
    /// no_claim=histories denser than every Manhattan block walked.
    @Test(arguments: CloseZoomHistory.allCases)
    func closeZoomNeverTripsTheCap(_ history: CloseZoomHistory) throws {
        let grid = try StreetGrid.loadBundled()
        let ids = history.walkedIDs(grid: grid)
        let tiles = WalkedTiles.build(walkedIDs: ids, grid: grid).tiles
        let index = WalkedPieceIndex(tiles: tiles)
        let densest = try #require(tiles.max { lhs, rhs in
            lhs.value.pieces.reduce(0) { $0 + $1.vertexCount } < rhs.value.pieces.reduce(0) { $0 + $1.vertexCount }
        })
        let row = Double(densest.key >> 32)
        let column = Double(Int32(truncatingIfNeeded: densest.key))
        let south = row * WalkedTiles.tileLatitudeDegrees, west = column * WalkedTiles.tileLongitudeDegrees
        let spots = [
            ("interior", south + WalkedTiles.tileLatitudeDegrees / 2, west + WalkedTiles.tileLongitudeDegrees / 2),
            ("edge", south + WalkedTiles.tileLatitudeDegrees / 2, west),
            ("corner", south, west)
        ]
        var most = (pieces: 0, vertices: 0)
        for (name, latitude, longitude) in spots {
            for height in [400.0, 439, 440, 441, 480] {
                for aspect in [402.0 / 874, 874.0 / 402] {
                    let drawn = index.visible(in: Self.region(latitude: latitude, longitude: longitude, height: height, aspect: aspect))
                    let vertices = drawn.reduce(0) { $0 + $1.vertexCount }
                    most = (max(most.pieces, drawn.count), max(most.vertices, vertices))
                    if height <= 440 {
                        #expect(drawn.count <= WalkedOverlay.maxDrawnPieces, "\(history) \(name) \(height) m")
                        #expect(vertices <= WalkedOverlay.maxDrawnVertices, "\(history) \(name) \(height) m: \(vertices)")
                    }
                }
            }
        }
        print("close zoom, \(history): \(ids.count) blocks, densest tile \(densest.value.pieces.reduce(0) { $0 + $1.vertexCount }) vertices; "
            + "most drawn at 400-480 m: \(most.pieces) pieces, \(most.vertices) vertices")
    }

    /// protects=design DS3, the cap in user terms: zooming out over the
    /// middle of the history from 300 m to 40 km (portrait phone), the
    /// visible height where the card first appears, logged for DESIGN.md:
    /// never on the device seed, and above the breadcrumb bands (over 2 km)
    /// with every Manhattan block walked;
    /// fails_when=the seed shows the card at any height, or the card can
    /// appear at a breadcrumb height;
    /// no_claim=the simulator check of the same heights (QA), landscape, or
    /// other cities' histories.
    @Test func cardHeightsForTheSeedAndAllOfManhattan() throws {
        let grid = try StreetGrid.loadBundled()
        var heights: [String] = []
        for history in [CloseZoomHistory.seed, .allOfManhattan] {
            let ids = history.walkedIDs(grid: grid)
            let index = WalkedLayerIndex(
                pieces: WalkedPieceIndex(tiles: WalkedTiles.build(walkedIDs: ids, grid: grid).tiles),
                runs: WalkedRunIndex(runs: WalkedOverlay.runs(walkedIDs: ids, grid: grid))
            )
            let bounds = Self.bounds(index.pieces.pieces)
            let latitude = (bounds.minLatitude + bounds.maxLatitude) / 2
            let longitude = (bounds.minLongitude + bounds.maxLongitude) / 2
            var display = WalkedOverlayDisplay()
            var firstCard: Double?
            for height in stride(from: 300.0, through: 40_000, by: 100) {
                let region = Self.region(latitude: latitude, longitude: longitude, height: height, aspect: 402.0 / 874)
                display.refresh(index: index, showsOverlay: true, region: region, visibleHeightMeters: height, isCameraMoving: false)
                if display.visible == .overCap, firstCard == nil { firstCard = height }
            }
            heights.append("\(history): \(firstCard.map { "\(Int($0)) m" } ?? "never")")
            switch history {
            case .seed: #expect(firstCard == nil)
            default: #expect((firstCard ?? .infinity) > 2_200)
            }
        }
        print("CARD HEIGHTS zooming out from 300 m: \(heights)")
    }

    enum CloseZoomHistory: String, CaseIterable, CustomStringConvertible {
        /// The device seed.
        case seed
        /// Every other seed block: many short, isolated pieces.
        case fragmented
        /// Every Manhattan block walked: the densest history possible.
        case allOfManhattan

        var description: String { rawValue }

        func walkedIDs(grid: StreetGrid) -> Set<UInt32> {
            switch self {
            case .seed: Set(WalkedSeedFixture.physicalIDs)
            case .fragmented: Set(WalkedSeedFixture.physicalIDs.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
            case .allOfManhattan:
                Set((0 ..< grid.segmentCount).filter { grid.borough(for: $0) == .manhattan }.map { grid.physicalIDs[$0] })
            }
        }
    }

    /// protects=eng D10's split: a walk longer than `maxPieceVertices` is
    /// cut into consecutive parts that share their joining vertex, so the
    /// parts together draw exactly the walk; a short walk is one part;
    /// fails_when=a part exceeds the bound, a joining vertex is lost (a gap
    /// in the line) or doubled, or a short walk is split;
    /// no_claim=which part a view culls (the close-zoom test).
    @Test func longWalksSplitIntoJoinedParts() {
        let limit = WalkedTiles.maxPieceVertices
        let walk = (0 ..< (limit * 2 + 7)).map { F.coordinate(x: Double($0), y: Double($0 % 2)) }
        let parts = WalkedTiles.split(walk)
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { $0.count <= limit })
        for (first, second) in zip(parts, parts.dropFirst()) {
            #expect(first.last == second.first)
        }
        let joined = parts.enumerated().flatMap { $0.offset == 0 ? $0.element : Array($0.element.dropFirst()) }
        #expect(joined == walk)
        #expect(WalkedTiles.split(Array(walk.prefix(limit))) == [Array(walk.prefix(limit))])
    }

    // MARK: Helpers

    /// A piece of `vertices` vertices zigzagging inside a 10 m box `x`
    /// metres east of the fixture origin.
    private static func piece(tile: Int64, x: Double, vertices: Int) -> WalkedPiece {
        WalkedPiece(
            id: WalkedPieceID(tile: tile, lowestPhysicalID: UInt32(tile)),
            coordinates: (0 ..< vertices).map { F.coordinate(x: x + Double($0 % 10), y: Double($0 % 7)) }
        )
    }

    /// A region `width` metres wide and tall centred `x` metres east of
    /// the fixture origin.
    private static func region(x: Double, width: Double) -> WalkedRegion {
        let center = F.coordinate(x: x, y: 0)
        return WalkedRegion(
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            latitudeDelta: width / StreetGrid.metersPerDegreeLatitude,
            longitudeDelta: width / (cos(F.originLatitude * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator)
        )
    }

    /// A region `height` metres tall, `height * aspect` wide.
    private static func region(latitude: Double, longitude: Double, height: Double, aspect: Double) -> WalkedRegion {
        WalkedRegion(
            centerLatitude: latitude,
            centerLongitude: longitude,
            latitudeDelta: height / StreetGrid.metersPerDegreeLatitude,
            longitudeDelta: height * aspect / (cos(latitude * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator)
        )
    }

    private static func vertices(_ visible: WalkedOverlay.Visible) -> Int? {
        guard case .pieces(let pieces, _) = visible else { return nil }
        return pieces.reduce(0) { $0 + $1.vertexCount }
    }

    private static func bounds(_ pieces: [WalkedPiece]) -> WalkedOverlay.Bounds {
        WalkedOverlay.Bounds(
            minLatitude: pieces.map(\.minLatitude).min() ?? 0,
            maxLatitude: pieces.map(\.maxLatitude).max() ?? 0,
            minLongitude: pieces.map(\.minLongitude).min() ?? 0,
            maxLongitude: pieces.map(\.maxLongitude).max() ?? 0
        )
    }
}
