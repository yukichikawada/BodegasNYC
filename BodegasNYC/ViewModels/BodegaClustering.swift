import MapKit

/// A single item to render on the map: either an individual bodega pin, or
/// a cluster badge summarizing several bodegas too close together to
/// distinguish at the current zoom level. SwiftUI's declarative `Map` has no
/// native annotation clustering (confirmed against the iOS 26.2 SDK —
/// `MKClusterAnnotation`/`clusteringIdentifier` remain `MKMapView`-only
/// mechanisms), so `BodegaMapViewModel.cluster(_:visibleRegion:)` computes
/// this client-side instead.
nonisolated enum MapDisplayItem: Identifiable, Hashable {
    case pin(Bodega)
    case cluster(Cluster)

    nonisolated struct Cluster: Identifiable, Hashable {
        var id: String
        var coordinate: Coordinate
        var bodegaIDs: [Bodega.ID]
    }

    var id: String {
        switch self {
        case .pin(let bodega):
            bodega.id.uuidString
        case .cluster(let cluster):
            cluster.id
        }
    }
}

extension BodegaMapViewModel {
    /// Buckets `bodegas` into a grid sized to `visibleRegion`'s span, so
    /// cell size — and therefore how aggressively pins merge — scales with
    /// zoom level rather than using one fixed real-world distance. Singleton
    /// cells stay individual pins; cells with more than one bodega become a
    /// cluster centered at their coordinate centroid.
    ///
    /// Pure and synchronous by design: no dependency on a live `Map` view,
    /// so it's directly unit-testable (see `BodegaClusteringTests`).
    /// Explicitly `nonisolated` — this touches no `MainActor`-isolated
    /// state, unlike the rest of `BodegaMapViewModel`, and callers
    /// shouldn't need actor-hopping ceremony just to compute a pure value.
    nonisolated static func cluster(
        _ bodegas: [Bodega],
        visibleRegion: MKCoordinateRegion,
        gridDivisions: Int = 12
    ) -> [MapDisplayItem] {
        guard !bodegas.isEmpty else { return [] }

        // Guards against a degenerate (near-)zero span at extreme zoom
        // levels, where dividing by the raw span would produce infinity/NaN
        // bucket indices.
        let cellLatDelta = max(visibleRegion.span.latitudeDelta / Double(gridDivisions), .leastNormalMagnitude)
        let cellLongDelta = max(visibleRegion.span.longitudeDelta / Double(gridDivisions), .leastNormalMagnitude)

        var buckets: [GridKey: [Bodega]] = [:]
        for bodega in bodegas {
            let key = GridKey(
                latIndex: Int((bodega.coordinate.latitude / cellLatDelta).rounded(.down)),
                longIndex: Int((bodega.coordinate.longitude / cellLongDelta).rounded(.down))
            )
            buckets[key, default: []].append(bodega)
        }

        let groups = mergeOverlapping(
            buckets.sorted { $0.key < $1.key }.map { (key: $0.key, members: $0.value) },
            latThreshold: cellLatDelta * overlapCells,
            longThreshold: cellLongDelta * overlapCells
        )
        return groups.map { key, members in
            guard members.count > 1 else {
                return .pin(members[0])
            }
            return .cluster(centroidCluster(for: members, key: key))
        }
    }

    /// How close (in grid cells, per axis) two items' centers may sit
    /// before they are merged into one cluster. A cell is about 33pt on a
    /// phone, and pins and badges take a 44pt tap target, so 1.5 cells keeps
    /// every rendered item's target clear of its neighbours'.
    nonisolated static let overlapCells = 1.5

    /// Grid cells alone leave items in *adjacent* cells overlapping on
    /// screen: a badge with a member-adjacent pin under it, or two badges
    /// stacked. A tap on such a badge could land on the hidden pin (MapKit
    /// selection wins over the badge's tap gesture) and open that bodega's
    /// detail instead of zooming. Merging any two groups whose centroids are
    /// within the threshold, until none are, makes rendered items disjoint.
    /// A merged group keeps the smallest grid key, so its id stays stable.
    private nonisolated static func mergeOverlapping(
        _ initial: [(key: GridKey, members: [Bodega])],
        latThreshold: Double,
        longThreshold: Double
    ) -> [(key: GridKey, members: [Bodega])] {
        var groups = initial
        var merged = true
        while merged {
            merged = false
            let centroids = groups.map { centroid(of: $0.members) }
            search: for first in groups.indices {
                for second in groups.indices where second > first {
                    let isClose = abs(centroids[first].latitude - centroids[second].latitude) < latThreshold
                        && abs(centroids[first].longitude - centroids[second].longitude) < longThreshold
                    guard isClose else { continue }
                    groups[first].key = min(groups[first].key, groups[second].key)
                    groups[first].members += groups[second].members
                    groups.remove(at: second)
                    merged = true
                    break search
                }
            }
        }
        return groups.sorted { $0.key < $1.key }
    }

    private nonisolated static func centroid(of members: [Bodega]) -> Coordinate {
        let count = Double(members.count)
        return Coordinate(
            latitude: members.reduce(0) { $0 + $1.coordinate.latitude } / count,
            longitude: members.reduce(0) { $0 + $1.coordinate.longitude } / count
        )
    }

    private nonisolated struct GridKey: Hashable, Comparable {
        var latIndex: Int
        var longIndex: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.latIndex, lhs.longIndex) < (rhs.latIndex, rhs.longIndex)
        }
    }

    private nonisolated static func centroidCluster(for members: [Bodega], key: GridKey) -> MapDisplayItem.Cluster {
        MapDisplayItem.Cluster(
            id: "cluster-\(key.latIndex)_\(key.longIndex)",
            coordinate: centroid(of: members),
            // Sorted so a cluster's identity doesn't depend on the order
            // `bodegas` happened to be passed in — two calls with the same
            // membership in a different order would otherwise produce
            // unequal `Cluster` values (arrays are order-sensitive for
            // `Equatable`/`Hashable`) despite representing the same cluster.
            bodegaIDs: members.map(\.id).sorted { $0.uuidString < $1.uuidString }
        )
    }
}
