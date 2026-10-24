//
//  WalkedPanReplay.swift
//  BodegasNYCTests
//
//  A scripted pan over the 5,000-block QA seed, for measuring the walked
//  layer's overlay churn per settle (#113 item 1): how many lines MapKit is
//  asked to add and remove each time the camera comes to rest.
//
//  The seed mirrors `qa/108-seed108.py` (the store swapped onto the device
//  for the R3 check): the 5,000 Manhattan blocks with the southernmost
//  vertices, walked end to end, here taken straight from the bundled grid
//  instead of being map-matched from fixes.
//

import Foundation

@testable import BodegasNYC

enum WalkedPanReplay {
    /// The runs of the 5,000 southernmost Manhattan blocks, built once.
    static let seedIndex: WalkedRunIndex = {
        guard let grid = try? StreetGrid.loadBundled() else { return .empty }
        let manhattan = (0 ..< grid.segmentCount).filter { grid.borough(for: $0) == .manhattan }
        let southernmost = manhattan
            .map { (index: $0, latitude: grid.polyline(for: $0).map(\.latitude).min() ?? 0) }
            .sorted { ($0.latitude, $0.index) < ($1.latitude, $1.index) }
            .prefix(5_000)
        let walked = Set(southernmost.map { grid.physicalIDs[$0.index] })
        return WalkedRunIndex(runs: WalkedOverlay.runs(walkedIDs: walked, grid: grid))
    }()

    /// A phone-shaped settled region (402 x 874 points) `height` metres tall.
    static func region(center: Coordinate, height: Double) -> WalkedRegion {
        WalkedRegion(
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            latitudeDelta: height / StreetGrid.metersPerDegreeLatitude,
            longitudeDelta: height * 402 / 874
                / (cos(center.latitude * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator)
        )
    }

    /// The settled regions of one scripted session over `index`'s runs: 60
    /// pans of 10% to 30% of the span in a random direction, with a zoom step
    /// after every 7th pan (out and back in through 750 m to 6 km, so every
    /// stroke band is visited), from 1.5 km over the middle of the data. The
    /// centre stays inside the runs' bounding box. Deterministic per `seed`.
    static func script(over index: WalkedRunIndex, seed: UInt64) -> [WalkedRegion] {
        let runs = index.runs
        guard !runs.isEmpty else { return [] }
        let south = runs.map(\.minLatitude).min() ?? 0
        let north = runs.map(\.maxLatitude).max() ?? 0
        let west = runs.map(\.minLongitude).min() ?? 0
        let east = runs.map(\.maxLongitude).max() ?? 0
        var random = SplitMix(seed: seed)
        var center = Coordinate(latitude: (south + north) / 2, longitude: (west + east) / 2)
        var height = 1_500.0
        let zooms = [0.5, 2, 2, 0.5, 4, 0.25, 2, 0.5]
        var regions = [region(center: center, height: height)]
        for pan in 1 ... 60 {
            let current = region(center: center, height: height)
            let fraction = 0.10 + 0.20 * random.unit()
            let angle = 2 * Double.pi * random.unit()
            center = Coordinate(
                latitude: min(north, max(south, center.latitude + fraction * sin(angle) * current.latitudeDelta)),
                longitude: min(east, max(west, center.longitude + fraction * cos(angle) * current.longitudeDelta))
            )
            regions.append(region(center: center, height: height))
            if pan % 7 == 0 {
                height *= zooms[(pan / 7 - 1) % zooms.count]
                regions.append(region(center: center, height: height))
            }
        }
        return regions
    }

    /// One settle of a replay: what was drawn, and the lines added and
    /// removed against the settle before.
    struct Settle {
        var visible: WalkedOverlay.Visible
        var added: Int
        var removed: Int
        var churn: Int { added + removed }
        var drawnCount: Int {
            if case .runs(let runs) = visible { return runs.count }
            return 0
        }
    }

    /// Replays `regions` through `refresh` (inner-only culling with
    /// `retainMargin` 0.25, which is origin/main, or the hysteresis), from an
    /// empty map.
    static func replay(_ regions: [WalkedRegion], index: WalkedRunIndex, retainMargin: Double) -> [Settle] {
        var drawn = WalkedOverlay.Visible.runs([])
        var settles: [Settle] = []
        for region in regions {
            let next = index.visible(in: region, keeping: drawn, retainMargin: retainMargin)
            let before = ids(drawn)
            let after = ids(next)
            settles.append(Settle(visible: next, added: after.subtracting(before).count, removed: before.subtracting(after).count))
            drawn = next
        }
        return settles
    }

    static func ids(_ visible: WalkedOverlay.Visible) -> Set<UInt32> {
        if case .runs(let runs) = visible { return Set(runs.map(\.id)) }
        return []
    }

    struct Summary {
        var total = 0
        var p95 = 0
        var max = 0
    }

    /// Total, p95 and max of `values` (nearest-rank p95).
    static func summary(_ values: [Int]) -> Summary {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return Summary() }
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up)) - 1
        return Summary(total: sorted.reduce(0, +), p95: sorted[Swift.max(0, rank)], max: sorted[sorted.count - 1])
    }

    /// SplitMix64: a seeded generator, so a script is the same on every run.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }

        /// Uniform in [0, 1).
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}
