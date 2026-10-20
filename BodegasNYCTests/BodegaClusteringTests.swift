//
//  BodegaClusteringTests.swift
//  BodegasNYCTests
//
//  Pure grid-clustering logic, no networking involved — deliberately a
//  standalone suite rather than nested under `NetworkingTests`, since it has
//  no `MockURLProtocol` shared-state dependency requiring serialization.
//

import MapKit
import Testing

@testable import BodegasNYC

@Suite
struct BodegaClusteringTests {
    /// A wide region: cell size (span / 12) is 0.01° on each axis, so two
    /// points 0.005° apart in latitude land in the same grid cell
    /// regardless of exact alignment (`floor(40.70/0.01) == floor(40.705/0.01) == 4070`).
    private static let wideRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7025, longitude: -73.9875),
        span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
    )

    /// A tight region: cell size is ~0.0000833° — the same two points that
    /// cluster under `wideRegion` are 60 cells apart here
    /// (`floor(40.70/0.0000833) == 488400`, `floor(40.705/0.0000833) == 488460`).
    private static let tightRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7025, longitude: -73.9875),
        span: MKCoordinateSpan(latitudeDelta: 0.001, longitudeDelta: 0.001)
    )

    @Test func singleBodegaStaysAPin() throws {
        let bodega = try makeTestBodega(latitude: 40.70, longitude: -73.99)

        let items = BodegaMapViewModel.cluster([bodega], visibleRegion: Self.wideRegion)

        #expect(items.count == 1)
        #expect(items.first == .pin(bodega))
    }

    @Test func emptyInputProducesNoItems() {
        let items = BodegaMapViewModel.cluster([], visibleRegion: Self.wideRegion)

        #expect(items.isEmpty)
    }

    @Test func nearbyBodegasClusterUnderAWideRegion() throws {
        let bodegaA = try makeTestBodega(latitude: 40.70, longitude: -73.99)
        let bodegaB = try makeTestBodega(latitude: 40.705, longitude: -73.99)

        let items = BodegaMapViewModel.cluster([bodegaA, bodegaB], visibleRegion: Self.wideRegion)

        #expect(items.count == 1)
        guard case .cluster(let cluster) = try #require(items.first) else {
            Issue.record("expected a cluster, got \(String(describing: items.first))")
            return
        }
        #expect(Set(cluster.bodegaIDs) == Set([bodegaA.id, bodegaB.id]))
    }

    @Test func sameBodegasStaySeparatePinsUnderATightRegion() throws {
        let bodegaA = try makeTestBodega(latitude: 40.70, longitude: -73.99)
        let bodegaB = try makeTestBodega(latitude: 40.705, longitude: -73.99)

        let items = BodegaMapViewModel.cluster([bodegaA, bodegaB], visibleRegion: Self.tightRegion)

        #expect(Set(items) == Set([.pin(bodegaA), .pin(bodegaB)]))
    }

    @Test func clusterCoordinateIsTheMemberCentroid() throws {
        let bodegaA = try makeTestBodega(latitude: 10, longitude: 20)
        let bodegaB = try makeTestBodega(latitude: 20, longitude: 40)
        let wideEnoughRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 15, longitude: 30),
            span: MKCoordinateSpan(latitudeDelta: 1000, longitudeDelta: 1000)
        )

        let items = BodegaMapViewModel.cluster([bodegaA, bodegaB], visibleRegion: wideEnoughRegion)

        guard case .cluster(let cluster) = try #require(items.first) else {
            Issue.record("expected a cluster, got \(String(describing: items.first))")
            return
        }
        #expect(cluster.coordinate.latitude == 15)
        #expect(cluster.coordinate.longitude == 30)
    }

    @Test func resultIsIndependentOfInputOrder() throws {
        let bodegaA = try makeTestBodega(latitude: 40.70, longitude: -73.99)
        let bodegaB = try makeTestBodega(latitude: 40.705, longitude: -73.99)

        let forward = BodegaMapViewModel.cluster([bodegaA, bodegaB], visibleRegion: Self.wideRegion)
        let reversed = BodegaMapViewModel.cluster([bodegaB, bodegaA], visibleRegion: Self.wideRegion)

        #expect(Set(forward) == Set(reversed))
    }

    // MARK: Overlap merge (#25 QA F1). protects: no rendered item sits on
    // top of another, so a tap on a badge can't land on a pin hidden under
    // it. fails_when: items in adjacent cells within 1.5 cells stay
    // separate, or items further apart get merged. no_claim: MapKit hit
    // testing itself (checked live on the simulator).

    @Test func itemsInAdjacentCellsThatWouldOverlapAreMerged() throws {
        // 0.0002° apart but straddling the 40.70 cell boundary.
        let south = try makeTestBodega(latitude: 40.6999, longitude: -73.995)
        let north = try makeTestBodega(latitude: 40.7001, longitude: -73.995)

        let items = BodegaMapViewModel.cluster([south, north], visibleRegion: Self.wideRegion)

        #expect(items.count == 1)
        guard case .cluster(let cluster) = items.first else {
            Issue.record("expected one cluster, got \(items)")
            return
        }
        #expect(Set(cluster.bodegaIDs) == [south.id, north.id])
        // The merged group keeps the smaller grid key.
        #expect(cluster.id == "cluster-4069_-7400")
    }

    @Test func itemsTwoCellsApartStaySeparate() throws {
        let first = try makeTestBodega(latitude: 40.701, longitude: -73.995)
        let second = try makeTestBodega(latitude: 40.721, longitude: -73.995)

        let items = BodegaMapViewModel.cluster([first, second], visibleRegion: Self.wideRegion)

        #expect(Set(items) == [.pin(first), .pin(second)])
    }

    @Test func aPinBesideAClusterIsAbsorbedIntoIt() throws {
        let clusterA = try makeTestBodega(latitude: 40.705, longitude: -73.995)
        let clusterB = try makeTestBodega(latitude: 40.706, longitude: -73.995)
        let neighbour = try makeTestBodega(latitude: 40.7105, longitude: -73.995)

        let items = BodegaMapViewModel.cluster([clusterA, clusterB, neighbour], visibleRegion: Self.wideRegion)

        #expect(items.count == 1)
        if case .cluster(let cluster) = items.first {
            #expect(cluster.bodegaIDs.count == 3)
        } else {
            Issue.record("expected one cluster, got \(items)")
        }
    }
}
