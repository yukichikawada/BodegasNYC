import Foundation

/// The five boroughs by their CSCL `boroughcode` (#108).
nonisolated enum Borough: Int, CaseIterable, Sendable, Hashable {
    case manhattan = 1
    case bronx = 2
    case brooklyn = 3
    case queens = 4
    case statenIsland = 5

    /// The order Your Blocks lists them in (spec Implementation 7).
    static let displayOrder: [Borough] = [.manhattan, .brooklyn, .queens, .bronx, .statenIsland]
}

/// Every NYC street block (`BodegasNYC/Resources/nyc-streets.bin`, built by
/// `scripts/build-street-segments.py` from the CSCL centerline, #108) plus a
/// uniform grid of about 100 m cells for nearest-segment lookups.
///
/// Immutable once built, so one instance is shared between the matching actor
/// and the map overlay. Loaded off the main actor, once, on first use: only
/// when Streets Walked has history or is turned on, never at launch for
/// people who never opt in.
///
/// Planar math uses a local equirectangular plane centred on the query
/// (x = Δlon · cos(lat) · 111,320 m, y = Δlat · 110,540 m), under 0.1% off at
/// NYC scale.
nonisolated final class StreetGrid: Sendable {
    nonisolated enum LoadError: Error, Equatable {
        case missingResource
        case badMagic
        case unsupportedVersion(UInt16)
        case truncated
        case badBorough(UInt8)
        case countMismatch
    }

    /// One block as the tests and the binary parser describe it.
    nonisolated struct Segment: Sendable, Equatable {
        var physicalID: UInt32
        var borough: Borough
        var coordinates: [Coordinate]
    }

    /// A sample's nearest block: its index, how far along it the projection
    /// lands (0...1, start to end), and the distance in metres.
    nonisolated struct Match: Sendable, Equatable {
        var segment: Int
        var fraction: Double
        var distance: Double
    }

    static let formatVersion: UInt16 = 1
    static let metersPerDegreeLatitude = 110_540.0
    static let metersPerDegreeLongitudeAtEquator = 111_320.0
    /// About 133 m x 135 m at NYC's latitude: larger than the 30 m match
    /// radius, so the 3x3 neighbourhood of a sample's cell holds every edge
    /// within the radius (eng A1).
    static let cellLatitudeDegrees = 0.0012
    static let cellLongitudeDegrees = 0.0016
    /// Two distances within this are a tie, which goes to the lower
    /// `physicalid` (spec Implementation 3).
    static let tieMeters = 0.01
    fileprivate static let headerSize = 4 + 2 + 4 + 4 + 5 * 4

    let datasetStamp: UInt32
    /// Blocks per borough, from the file's header.
    let blockCounts: [Borough: Int]
    let physicalIDs: [UInt32]
    let boroughs: [Borough]
    /// `vertexStarts[i] ..< vertexStarts[i + 1]` are segment `i`'s vertices.
    fileprivate let vertexStarts: [Int32]
    fileprivate let latitudes: [Double]
    fileprivate let longitudes: [Double]
    /// Metres along the segment at each vertex (the segment's own plane).
    fileprivate let cumulativeMeters: [Double]
    /// The segment each vertex belongs to.
    fileprivate let vertexSegment: [Int32]
    fileprivate let indexByPhysicalID: [UInt32: Int32]
    fileprivate let cells: CellIndex

    var segmentCount: Int { physicalIDs.count }
    var totalBlockCount: Int { blockCounts.values.reduce(0, +) }

    // MARK: Loading

    /// The bundled file. Throws `missingResource` if it is not in the app.
    static func loadBundled(bundle: Bundle = Bundle(for: StreetGrid.self)) throws -> StreetGrid {
        guard let url = bundle.url(forResource: "nyc-streets", withExtension: "bin") else {
            throw LoadError.missingResource
        }
        return try StreetGrid(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Parses the `nyc-streets.bin` layout (see the script's docstring).
    convenience init(data: Data) throws {
        let parsed = try data.withUnsafeBytes { raw -> ParsedStreets in
            try ParsedStreets(raw)
        }
        self.init(parsed: parsed)
    }

    /// Builds a grid from explicit segments (tests, fixtures). Header counts
    /// are the segments' own per-borough counts.
    convenience init(datasetStamp: UInt32 = 1, segments: [Segment]) {
        var parsed = ParsedStreets(datasetStamp: datasetStamp)
        for segment in segments.sorted(by: { $0.physicalID < $1.physicalID }) {
            parsed.append(segment)
            parsed.blockCounts[segment.borough, default: 0] += 1
        }
        self.init(parsed: parsed)
    }

    fileprivate init(parsed: ParsedStreets) {
        datasetStamp = parsed.datasetStamp
        blockCounts = parsed.blockCounts
        physicalIDs = parsed.physicalIDs
        boroughs = parsed.boroughs
        vertexStarts = parsed.vertexStarts
        latitudes = parsed.latitudes
        longitudes = parsed.longitudes

        let vertexCount = parsed.latitudes.count
        var cumulative = [Double](repeating: 0, count: vertexCount)
        var owner = [Int32](repeating: 0, count: vertexCount)
        var byID: [UInt32: Int32] = [:]
        byID.reserveCapacity(parsed.physicalIDs.count)
        for segment in 0 ..< parsed.physicalIDs.count {
            byID[parsed.physicalIDs[segment]] = Int32(segment)
            let start = Int(parsed.vertexStarts[segment])
            let end = Int(parsed.vertexStarts[segment + 1])
            guard start < end else { continue }
            let scaleX = cos(parsed.latitudes[start] * .pi / 180) * Self.metersPerDegreeLongitudeAtEquator
            owner[start] = Int32(segment)
            for vertex in (start + 1) ..< end {
                owner[vertex] = Int32(segment)
                let deltaX = (parsed.longitudes[vertex] - parsed.longitudes[vertex - 1]) * scaleX
                let deltaY = (parsed.latitudes[vertex] - parsed.latitudes[vertex - 1]) * Self.metersPerDegreeLatitude
                cumulative[vertex] = cumulative[vertex - 1] + (deltaX * deltaX + deltaY * deltaY).squareRoot()
            }
        }
        cumulativeMeters = cumulative
        vertexSegment = owner
        indexByPhysicalID = byID
        cells = CellIndex(parsed)
    }
}

// MARK: - Queries

nonisolated extension StreetGrid {
    func index(ofPhysicalID physicalID: UInt32) -> Int? {
        indexByPhysicalID[physicalID].map(Int.init)
    }

    func borough(for index: Int) -> Borough { boroughs[index] }

    func polyline(for index: Int) -> [Coordinate] {
        (Int(vertexStarts[index]) ..< Int(vertexStarts[index + 1])).map {
            Coordinate(latitude: latitudes[$0], longitude: longitudes[$0])
        }
    }

    /// The block's length in metres along its centerline.
    func length(of index: Int) -> Double {
        cumulativeMeters[Int(vertexStarts[index + 1]) - 1]
    }

    /// The nearest block edge to `coordinate` within `radius` metres, with
    /// ties (within 0.01 m) going to the lower `physicalid`.
    func nearestSegment(to coordinate: Coordinate, within radius: Double) -> Match? {
        guard let best = cells.nearestEdge(to: coordinate, within: radius) else { return nil }
        let (edge, edgeFraction, distance) = best
        let segment = Int(vertexSegment[edge])
        let total = cumulativeMeters[Int(vertexStarts[segment + 1]) - 1]
        let edgeStart = cumulativeMeters[edge]
        let along = edgeStart + edgeFraction * (cumulativeMeters[edge + 1] - edgeStart)
        let fraction = total > 0 ? min(1, max(0, along / total)) : 0
        return Match(segment: segment, fraction: fraction, distance: distance)
    }
}

// MARK: - File parsing

/// The file's contents as flat arrays, before the derived indexes.
nonisolated private struct ParsedStreets {
    var datasetStamp: UInt32
    var blockCounts: [Borough: Int] = [:]
    var physicalIDs: [UInt32] = []
    var boroughs: [Borough] = []
    var vertexStarts: [Int32] = [0]
    var latitudes: [Double] = []
    var longitudes: [Double] = []

    init(datasetStamp: UInt32) {
        self.datasetStamp = datasetStamp
    }

    mutating func append(_ segment: StreetGrid.Segment) {
        physicalIDs.append(segment.physicalID)
        boroughs.append(segment.borough)
        for coordinate in segment.coordinates {
            latitudes.append(coordinate.latitude)
            longitudes.append(coordinate.longitude)
        }
        vertexStarts.append(Int32(latitudes.count))
    }

    /// Reads the layout `scripts/build-street-segments.py` writes.
    init(_ raw: UnsafeRawBufferPointer) throws {
        typealias LoadError = StreetGrid.LoadError
        guard raw.count >= StreetGrid.headerSize else { throw LoadError.truncated }
        guard Array(raw[0 ..< 4]) == Array("NYCS".utf8) else { throw LoadError.badMagic }
        let version = Self.uint16(raw, 4)
        guard version == StreetGrid.formatVersion else { throw LoadError.unsupportedVersion(version) }
        self.init(datasetStamp: Self.uint32(raw, 6))
        let count = Int(Self.uint32(raw, 10))
        for (index, borough) in Borough.allCases.enumerated() {
            blockCounts[borough] = Int(Self.uint32(raw, 14 + index * 4))
        }
        physicalIDs.reserveCapacity(count)
        boroughs.reserveCapacity(count)
        vertexStarts.reserveCapacity(count + 1)
        var offset = StreetGrid.headerSize
        for _ in 0 ..< count {
            guard offset + 7 <= raw.count else { throw LoadError.truncated }
            let code = raw[offset + 4]
            guard let borough = Borough(rawValue: Int(code)) else { throw LoadError.badBorough(code) }
            let vertexCount = Int(Self.uint16(raw, offset + 5))
            guard vertexCount >= 2, offset + 7 + vertexCount * 8 <= raw.count else { throw LoadError.truncated }
            physicalIDs.append(Self.uint32(raw, offset))
            boroughs.append(borough)
            offset += 7
            for vertex in 0 ..< vertexCount {
                longitudes.append(Double(Float(bitPattern: Self.uint32(raw, offset + vertex * 8))))
                latitudes.append(Double(Float(bitPattern: Self.uint32(raw, offset + vertex * 8 + 4))))
            }
            offset += vertexCount * 8
            vertexStarts.append(Int32(latitudes.count))
        }
        guard offset == raw.count else { throw LoadError.countMismatch }
    }

    private static func uint16(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    private static func uint32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}

// MARK: - Cell index

/// A uniform grid over the data's bounding box in compressed rows: cell
/// `c`'s edges are `edges[starts[c] ..< starts[c + 1]]`, an edge being the
/// global index of its first vertex. Each edge is in every cell its bounding
/// box overlaps (eng A1).
nonisolated private struct CellIndex: Sendable {
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

    init(_ parsed: ParsedStreets) {
        let latitudes = parsed.latitudes
        let longitudes = parsed.longitudes
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
        for segment in 0 ..< parsed.physicalIDs.count {
            let start = Int(parsed.vertexStarts[segment])
            let end = Int(parsed.vertexStarts[segment + 1])
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
        var owner = [UInt32](repeating: 0, count: latitudes.count)
        for segment in 0 ..< parsed.physicalIDs.count {
            for vertex in Int(parsed.vertexStarts[segment]) ..< Int(parsed.vertexStarts[segment + 1]) {
                owner[vertex] = parsed.physicalIDs[segment]
            }
        }
        records = allEdges.map { edge in
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
    func nearestEdge(to coordinate: Coordinate, within radius: Double) -> (Int, Double, Double)? {
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
        return best.vertex >= 0 ? (best.vertex, best.fraction, best.distance) : nil
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
