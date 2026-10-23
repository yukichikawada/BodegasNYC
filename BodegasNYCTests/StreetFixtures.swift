//
//  StreetFixtures.swift
//  BodegasNYCTests
//
//  Shared fixtures for the walked-blocks tests (#108): a local metre grid
//  around a Midtown origin, fixture blocks, walks sampled at a speed, and a
//  writer for the `nyc-streets.bin` layout so parsing is tested against
//  bytes built independently of the parser.
//

import Foundation
import SwiftData

@testable import BodegasNYC

enum StreetFixtures {
    static let originLatitude = 40.75
    static let originLongitude = -73.99
    static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    /// The coordinate `x` metres east and `y` metres north of the origin,
    /// in the matcher's own equirectangular plane.
    static func coordinate(x: Double, y: Double) -> Coordinate {
        Coordinate(
            latitude: originLatitude + y / StreetGrid.metersPerDegreeLatitude,
            longitude: originLongitude
                + x / (cos(originLatitude * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator)
        )
    }

    static func segment(_ id: UInt32, _ points: [(Double, Double)], borough: Borough = .manhattan) -> StreetGrid.Segment {
        StreetGrid.Segment(physicalID: id, borough: borough, coordinates: points.map { coordinate(x: $0.0, y: $0.1) })
    }

    /// A Manhattan-like corner: block 100 runs east 100 m along y = 0, with
    /// cross-street blocks 200 (x = 0) and 201 (x = 100) going north 80 m,
    /// block 300 parallel 80 m north, and block 400 continuing east.
    static let cornerSegments: [StreetGrid.Segment] = [
        segment(100, [(0, 0), (100, 0)]),
        segment(200, [(0, 0), (0, 80)]),
        segment(201, [(100, 0), (100, 80)]),
        segment(300, [(0, 80), (100, 80)]),
        segment(400, [(100, 0), (200, 0)])
    ]

    static func cornerGrid(stamp: UInt32 = 1) -> StreetGrid {
        StreetGrid(datasetStamp: stamp, segments: cornerSegments)
    }

    /// One 100 m block alone, so quantization is all that is measured.
    static func loneBlockGrid(length: Double = 100, id: UInt32 = 100) -> StreetGrid {
        StreetGrid(segments: [segment(id, [(0, 0), (length, 0)])])
    }

    /// Fixes along the straight line from `start` to `end` (metres), at most
    /// `spacing` apart, at `speed` m/s, the first at `startTime` seconds
    /// after `baseDate`. The last fix is exactly at `end`.
    static func walk(
        from start: (Double, Double),
        to end: (Double, Double),
        spacing: Double = 10,
        speed: Double = 1.4,
        startTime: TimeInterval = 0
    ) -> [WalkedPointSnapshot] {
        let length = ((end.0 - start.0) * (end.0 - start.0) + (end.1 - start.1) * (end.1 - start.1)).squareRoot()
        let steps = max(1, Int((length / spacing).rounded(.up)))
        return (0 ... steps).map { step in
            let t = Double(step) / Double(steps)
            return WalkedPointSnapshot(
                coordinate: coordinate(x: start.0 + (end.0 - start.0) * t, y: start.1 + (end.1 - start.1) * t),
                recordedAt: baseDate.addingTimeInterval(startTime + length * t / speed)
            )
        }
    }

    static func bins(_ mask: UInt16?) -> Set<Int> {
        Set((0 ..< 10).filter { (mask ?? 0) & (1 << UInt16($0)) != 0 })
    }

    /// The `nyc-streets.bin` layout, written by hand (see
    /// `scripts/build-street-segments.py`).
    static func binary(
        segments: [StreetGrid.Segment],
        stamp: UInt32 = 7,
        version: UInt16 = 1,
        headerCounts: [Int]? = nil,
        magic: [UInt8] = Array("NYCS".utf8)
    ) -> Data {
        var data = Data(magic)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(version)
        append(stamp)
        append(UInt32(segments.count))
        let counts = headerCounts ?? Borough.allCases.map { borough in segments.filter { $0.borough == borough }.count }
        for count in counts { append(UInt32(count)) }
        for segment in segments {
            append(segment.physicalID)
            append(UInt8(segment.borough.rawValue))
            append(UInt16(segment.coordinates.count))
            for coordinate in segment.coordinates {
                append(Float(coordinate.longitude).bitPattern)
                append(Float(coordinate.latitude).bitPattern)
            }
        }
        return data
    }

    /// Saves `snapshots` as `WalkedPoint`s (unmatched) in `context`.
    @MainActor
    static func seed(_ snapshots: [WalkedPointSnapshot], in context: ModelContext) throws {
        for snapshot in snapshots {
            context.insert(
                WalkedPoint(
                    id: snapshot.id,
                    latitude: snapshot.coordinate.latitude,
                    longitude: snapshot.coordinate.longitude,
                    recordedAt: snapshot.recordedAt
                )
            )
        }
        try context.save()
    }
}

/// Motion & Fitness double: fixed rides, optionally held at a gate so a test
/// can act while a pass waits on its activity query.
final class FakeMotionProvider: MotionActivityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _authorization: MotionAuthorization
    private var _requests = 0
    private var _queries = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNextQuery = false
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    let activity: VehicleActivity

    init(authorization: MotionAuthorization = .denied, activity: VehicleActivity = .unavailable) {
        _authorization = authorization
        self.activity = activity
    }

    var authorization: MotionAuthorization { lock.withLock { _authorization } }
    var requests: Int { lock.withLock { _requests } }
    var queries: Int { lock.withLock { _queries } }

    func requestAuthorization() async {
        lock.withLock {
            _requests += 1
            _authorization = .authorized
        }
    }

    /// The next query parks until `release()`.
    func holdNext() { lock.withLock { holdNextQuery = true } }

    /// Returns once a held query is parked.
    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if hasEntered { return true }
                entered = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let parked = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { gate = nil }
            return gate
        }
        parked?.resume()
    }

    func vehicleActivity(from start: Date, to end: Date) async -> VehicleActivity {
        let hold = lock.withLock { () -> Bool in
            _queries += 1
            defer { holdNextQuery = false }
            return holdNextQuery
        }
        if hold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    gate = continuation
                    hasEntered = true
                    defer { entered = nil }
                    return entered
                }
                waiter?.resume()
            }
        }
        return activity
    }
}
