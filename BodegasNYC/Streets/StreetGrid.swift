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
    fileprivate let cells: StreetGridCells

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
        cells = StreetGridCells(
            latitudes: parsed.latitudes,
            longitudes: parsed.longitudes,
            vertexStarts: parsed.vertexStarts,
            physicalIDs: parsed.physicalIDs
        )
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
        guard let hit = cells.nearestEdge(to: coordinate, within: radius) else { return nil }
        let edge = hit.vertex
        let edgeFraction = hit.fraction
        let distance = hit.distance
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
