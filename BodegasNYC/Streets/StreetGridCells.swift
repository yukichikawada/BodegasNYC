import Foundation

/// A uniform grid over the data's bounding box in compressed rows: cell
/// `c`'s edges are `edges[starts[c] ..< starts[c + 1]]`, an edge being the
/// global index of its first vertex. Each edge is in every cell its bounding
/// box overlaps (eng A1).
nonisolated struct StreetGridCells: Sendable {
    let originLatitude: Double
    let originLongitude: Double
    let rows: Int
    let columns: Int
    let starts: [Int32]
    /// Indexes into `records`.
    let edges: [Int32]
    /// One per edge: its endpoints and block id, read in one load per
    /// candidate (the lookup is the matcher's hot loop).
    let records: [EdgeRecord]

    struct EdgeRecord: Sendable {
        var startLatitude: Double
        var startLongitude: Double
        var endLatitude: Double
        var endLongitude: Double
        var physicalID: UInt32
        /// The global index of the edge's first vertex.
        var vertex: Int32
    }

    /// A nearest-edge result: the edge's first vertex, how far along it the
    /// projection lands (0...1) and the distance in metres.
    struct EdgeHit {
        var vertex: Int
        var fraction: Double
        var distance: Double
    }

    init(latitudes: [Double], longitudes: [Double], vertexStarts: [Int32], physicalIDs: [UInt32]) {
        let originLatitude = (latitudes.min() ?? 0) - StreetGrid.cellLatitudeDegrees
        let originLongitude = (longitudes.min() ?? 0) - StreetGrid.cellLongitudeDegrees
        let maxLatitude = (latitudes.max() ?? 0) + StreetGrid.cellLatitudeDegrees
        let maxLongitude = (longitudes.max() ?? 0) + StreetGrid.cellLongitudeDegrees
        let rows = max(1, Int(((maxLatitude - originLatitude) / StreetGrid.cellLatitudeDegrees).rounded(.up)))
        let columns = max(1, Int(((maxLongitude - originLongitude) / StreetGrid.cellLongitudeDegrees).rounded(.up)))
        self.originLatitude = originLatitude
        self.originLongitude = originLongitude
        self.rows = rows
        self.columns = columns

        var allEdges: [Int] = []
        allEdges.reserveCapacity(latitudes.count)
        for segment in 0 ..< physicalIDs.count {
            let start = Int(vertexStarts[segment])
            let end = Int(vertexStarts[segment + 1])
            if end - start >= 2 { allEdges.append(contentsOf: start ..< (end - 1)) }
        }
        func cellsOf(_ edge: Int) -> [Int] {
            let row = { (latitude: Double) in
                let cell = Int(((latitude - originLatitude) / StreetGrid.cellLatitudeDegrees).rounded(.down))
                return min(rows - 1, max(0, cell))
            }
            let column = { (longitude: Double) in
                let cell = Int(((longitude - originLongitude) / StreetGrid.cellLongitudeDegrees).rounded(.down))
                return min(columns - 1, max(0, cell))
            }
            let lat0 = latitudes[edge], lat1 = latitudes[edge + 1]
            let lon0 = longitudes[edge], lon1 = longitudes[edge + 1]
            let rowRange = row(min(lat0, lat1)) ... row(max(lat0, lat1))
            let columnRange = column(min(lon0, lon1)) ... column(max(lon0, lon1))
            return rowRange.flatMap { cellRow in columnRange.map { cellRow * columns + $0 } }
        }
        var counts = [Int32](repeating: 0, count: rows * columns + 1)
        let edgeCells = allEdges.map(cellsOf)
        for cells in edgeCells {
            for cell in cells { counts[cell + 1] += 1 }
        }
        for cell in 1 ..< counts.count {
            counts[cell] += counts[cell - 1]
        }
        var fill = counts
        var refs = [Int32](repeating: 0, count: Int(counts.last ?? 0))
        for (record, cells) in edgeCells.enumerated() {
            for cell in cells {
                refs[Int(fill[cell])] = Int32(record)
                fill[cell] += 1
            }
        }
        starts = counts
        edges = refs
        records = Self.records(allEdges, latitudes: latitudes, longitudes: longitudes,
                               vertexStarts: vertexStarts, physicalIDs: physicalIDs)
    }

    private static func records(
        _ edges: [Int], latitudes: [Double], longitudes: [Double], vertexStarts: [Int32], physicalIDs: [UInt32]
    ) -> [EdgeRecord] {
        var owner = [UInt32](repeating: 0, count: latitudes.count)
        for segment in 0 ..< physicalIDs.count {
            for vertex in Int(vertexStarts[segment]) ..< Int(vertexStarts[segment + 1]) {
                owner[vertex] = physicalIDs[segment]
            }
        }
        return edges.map { edge in
            EdgeRecord(
                startLatitude: latitudes[edge],
                startLongitude: longitudes[edge],
                endLatitude: latitudes[edge + 1],
                endLongitude: longitudes[edge + 1],
                physicalID: owner[edge],
                vertex: Int32(edge)
            )
        }
    }

    /// The nearest edge within `radius` metres among the 3x3 cells around
    /// `coordinate`: its first vertex, how far along it the projection lands
    /// (0...1) and the distance. Ties within 0.01 m go to the lower
    /// `physicalid`.
    func nearestEdge(to coordinate: Coordinate, within radius: Double) -> EdgeHit? {
        let row = Int(((coordinate.latitude - originLatitude) / StreetGrid.cellLatitudeDegrees).rounded(.down))
        let column = Int(((coordinate.longitude - originLongitude) / StreetGrid.cellLongitudeDegrees).rounded(.down))
        guard row >= -1, row <= rows, column >= -1, column <= columns else { return nil }
        let scaleX = cos(coordinate.latitude * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator
        let scaleY = StreetGrid.metersPerDegreeLatitude
        var best = Best()
        starts.withUnsafeBufferPointer { starts in
            edges.withUnsafeBufferPointer { edges in
                records.withUnsafeBufferPointer { records in
                    for cellRow in max(0, row - 1) ... min(rows - 1, row + 1) {
                        let rowStart = cellRow * columns
                        for cell in (rowStart + max(0, column - 1)) ... (rowStart + min(columns - 1, column + 1)) {
                            for slot in Int(starts[cell]) ..< Int(starts[cell + 1]) {
                                best.consider(
                                    records[Int(edges[slot])], from: coordinate,
                                    scaleX: scaleX, scaleY: scaleY, radius: radius
                                )
                            }
                        }
                    }
                }
            }
        }
        return best.vertex >= 0 ? EdgeHit(vertex: best.vertex, fraction: best.fraction, distance: best.distance) : nil
    }

    private struct Best {
        var vertex = -1
        var fraction = 0.0
        var distance = Double.infinity
        var physicalID = UInt32.max

        mutating func consider(
            _ record: EdgeRecord, from point: Coordinate, scaleX: Double, scaleY: Double, radius: Double
        ) {
            let startX = (record.startLongitude - point.longitude) * scaleX
            let startY = (record.startLatitude - point.latitude) * scaleY
            let edgeX = (record.endLongitude - point.longitude) * scaleX - startX
            let edgeY = (record.endLatitude - point.latitude) * scaleY - startY
            let lengthSquared = edgeX * edgeX + edgeY * edgeY
            let along = lengthSquared > 0 ? min(1, max(0, -(startX * edgeX + startY * edgeY) / lengthSquared)) : 0
            let nearestX = startX + along * edgeX
            let nearestY = startY + along * edgeY
            let candidate = (nearestX * nearestX + nearestY * nearestY).squareRoot()
            guard candidate <= radius else { return }
            let tie = StreetGrid.tieMeters
            if candidate < distance - tie || (candidate <= distance + tie && record.physicalID < physicalID) {
                vertex = Int(record.vertex)
                fraction = along
                distance = candidate
                physicalID = record.physicalID
            }
        }
    }
}
