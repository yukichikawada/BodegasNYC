//
//  WalkedPathSegmentingTests.swift
//  BodegasNYCTests
//
//  Pure segmenting logic, no SwiftData/CLLocationManager involved — a
//  standalone suite, same shape as BodegaClusteringTests.swift. Unlike
//  clustering, input order matters here (must stay chronological), so
//  there's no order-independence test.
//

import Foundation
import Testing

@testable import BodegasNYC

@Suite
struct WalkedPathSegmentingTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    private static func point(_ secondsOffset: TimeInterval, latitude: Double = 40.700, longitude: Double = -73.990) -> WalkedPointSnapshot {
        WalkedPointSnapshot(
            coordinate: Coordinate(latitude: latitude, longitude: longitude),
            recordedAt: baseDate.addingTimeInterval(secondsOffset)
        )
    }

    @Test func emptyInputProducesNoSegments() {
        #expect(StreetsWalkedViewModel.segments(from: []).isEmpty)
    }

    @Test func aSingleTotalPointIsDropped() {
        #expect(StreetsWalkedViewModel.segments(from: [Self.point(0)]).isEmpty)
    }

    @Test func oneContiguousWalkStaysOneSegment() {
        let points = [
            Self.point(0, latitude: 40.7000, longitude: -73.9900),
            Self.point(30, latitude: 40.7002, longitude: -73.9898),
            Self.point(60, latitude: 40.7004, longitude: -73.9896),
        ]

        let segments = StreetsWalkedViewModel.segments(from: points)

        #expect(segments.count == 1)
        #expect(segments.first?.count == 3)
    }

    @Test func aBigTimeGapSplitsIntoTwoSegments() {
        let points = [
            Self.point(0, latitude: 40.7000, longitude: -73.9900),
            Self.point(30, latitude: 40.7002, longitude: -73.9898),
            Self.point(30 + 3600, latitude: 40.7004, longitude: -73.9896),
            Self.point(60 + 3600, latitude: 40.7006, longitude: -73.9894),
        ]

        let segments = StreetsWalkedViewModel.segments(from: points)

        #expect(segments.count == 2)
        #expect(segments[0].count == 2)
        #expect(segments[1].count == 2)
    }

    @Test func aBigDistanceGapWithASmallTimeGapSplitsIntoTwoSegments() {
        let points = [
            Self.point(0, latitude: 40.7000, longitude: -73.9900),
            Self.point(10, latitude: 40.7000, longitude: -73.9900),
            Self.point(20, latitude: 40.8000, longitude: -74.1000),
            Self.point(30, latitude: 40.8002, longitude: -74.0998),
        ]

        let segments = StreetsWalkedViewModel.segments(from: points)

        #expect(segments.count == 2)
        #expect(segments[0].count == 2)
        #expect(segments[1].count == 2)
    }

    @Test func isolatedPointsWithinALargerSetAreAllDropped() {
        let points = [
            Self.point(0),
            Self.point(3600 * 5),
            Self.point(3600 * 10),
        ]

        #expect(StreetsWalkedViewModel.segments(from: points).isEmpty)
    }
}
