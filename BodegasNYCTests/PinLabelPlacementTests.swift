//
//  PinLabelPlacementTests.swift
//  BodegasNYCTests
//
//  Pin labels at block zoom (#67): the pure placement in
//  `BodegaMapViewModel+PinLabels.swift`. Points are given directly; a
//  helper builds pins whose latitude falls 0.0001° per 10pt of y, so north
//  is up. Label sizes come from `testLabelSize` (8pt per character up to 18,
//  plus 12pt padding, 22pt high), so every rect below is exact: an 18+
//  character name is 156 x 22 and spans y - 40 to y - 18 above its pin.
//  Circles are 32pt squares (36pt for a priority pin, 24pt for the location
//  dot). Labels keep 4pt from each other; against a circle the label itself
//  must not touch it.
//
//  Shared card for the fixtures: protects=which pins show their name at
//  block zoom; fails_when=a label prints over another label or a drawn
//  circle, a priority (held or dropping) label is dropped, the order is not
//  priority then north to south then id, or labels show outside block zoom;
//  no_claim=that MapProxy points match the rendered pins, that SwiftUI
//  draws the capsule at the measured size, or the fade (live QA).
//

import CoreGraphics
import Foundation
import MapKit
import Testing

@testable import BodegasNYC

@Suite
struct PinLabelPlacementTests {
    static let longName = "Sunny & Annie's Gourmet Deli"

    static func testLabelSize(_ name: String) -> CGSize {
        CGSize(width: CGFloat(min(name.count, 18)) * 8 + 12, height: 22)
    }

    /// Ids that sort in the order given (`uuidString` ascending).
    static func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    struct Fixture {
        var items: [MapDisplayItem] = []
        var points: [String: CGPoint] = [:]

        mutating func pin(_ index: Int, at point: CGPoint, name: String = longName) throws -> Bodega {
            let bodega = try makeTestBodega(
                id: PinLabelPlacementTests.id(index),
                name: name,
                latitude: 40.73 - Double(point.y) * 0.00001,
                longitude: -74.0 + Double(point.x) * 0.00001
            )
            items.append(.pin(bodega))
            points[bodega.id.uuidString] = point
            return bodega
        }

        mutating func cluster(at point: CGPoint) {
            let cluster = MapDisplayItem.Cluster(
                id: "cluster-test",
                coordinate: Coordinate(latitude: 40.73 - Double(point.y) * 0.00001, longitude: -74.0),
                bodegaIDs: []
            )
            items.append(.cluster(cluster))
            points[cluster.id] = point
        }

        func labelled(isBlockZoom: Bool = true, priority: [Bodega.ID] = [], onlyPriority: Bool = false) -> Set<UUID> {
            BodegaMapViewModel.labelledPinIDs(
                items: items,
                points: points,
                isBlockZoom: isBlockZoom,
                priorityIDs: priority,
                onlyPriority: onlyPriority,
                labelSize: PinLabelPlacementTests.testLabelSize
            )
        }
    }

    // MARK: isBlockZoom (design D2: enter at 400 m, leave above 440 m)

    /// protects: labels appear at 400 m or less and stay until above 440 m.
    /// fails_when: either threshold moves, or the previous state is ignored
    /// (a settle at 420 m blinks every label). no_claim: the screen-height
    /// measure `MapScreenView` feeds in.
    @Test(arguments: [
        (399.0, false, true), (401.0, false, false), (439.0, false, false), (441.0, false, false),
        (399.0, true, true), (401.0, true, true), (439.0, true, true), (441.0, true, false),
        (400.0, false, true), (440.0, true, true), (0.0, false, true)
    ])
    func blockZoomHysteresis(heightMeters: Double, wasBlockZoom: Bool, expected: Bool) {
        #expect(BodegaMapViewModel.isBlockZoom(heightMeters: heightMeters, wasBlockZoom: wasBlockZoom) == expected)
    }

    // MARK: isNear (eng D3)

    /// protects: only items inside the visible region grown by half a span
    /// on every side take part. fails_when: the padding is dropped, applied
    /// to one axis, or the edge is excluded. no_claim: longitude wrap at the
    /// antimeridian (irrelevant in New York).
    @Test func isNearInsideOutsideAndEdge() {
        // Exact binary values: half extent = 0.25 * (0.5 + 0.5) = 0.25.
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.5, longitude: -74.0),
            span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
        )
        #expect(BodegaMapViewModel.isNear(region: region, coordinate: Coordinate(latitude: 40.7, longitude: -73.8)))
        #expect(BodegaMapViewModel.isNear(region: region, coordinate: Coordinate(latitude: 40.75, longitude: -73.75)))
        #expect(!BodegaMapViewModel.isNear(region: region, coordinate: Coordinate(latitude: 40.76, longitude: -74.0)))
        #expect(!BodegaMapViewModel.isNear(region: region, coordinate: Coordinate(latitude: 40.5, longitude: -74.26)))
    }

    /// protects: a city-wide load does not put every bodega into placement.
    /// fails_when: items far outside the padded region become candidates or
    /// obstacles. no_claim: the clustering that produces the items.
    @Test func cityWideItemsWithTwentyNearbyGiveTwentyCandidates() throws {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.729, longitude: -73.9965),
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
        )
        var items: [MapDisplayItem] = []
        for index in 0..<1_980 {
            let latitude = 40.60 + Double(index % 100) * 0.001 // 40.600 to 40.699
            let longitude = -74.05 + Double(index / 100) * 0.001
            items.append(.pin(try makeTestBodega(latitude: latitude, longitude: longitude)))
        }
        var nearby = Set<UUID>()
        for index in 0..<20 {
            let bodega = try makeTestBodega(
                latitude: 40.728 + Double(index % 5) * 0.0005,
                longitude: -73.9975 + Double(index / 5) * 0.0005
            )
            nearby.insert(bodega.id)
            items.append(.pin(bodega))
        }

        let candidates = BodegaMapViewModel.labelCandidates(items, near: region)

        #expect(candidates.count == 20)
        #expect(Set(candidates.compactMap { if case .pin(let bodega) = $0 { bodega.id } else { nil } }) == nearby)
    }

    // MARK: labelRect

    /// protects: the rect placement reasons about is where DD3 draws the
    /// label: centred over the pin, its bottom 4pt above the 28pt circle.
    /// fails_when: the gap, centring or size changes. no_claim: SwiftUI's
    /// overlay offset matching it (live QA screenshots).
    @Test func labelRectSitsAboveTheCircle() {
        let rect = BodegaMapViewModel.labelRect(
            for: Self.longName, at: CGPoint(x: 200, y: 300), size: Self.testLabelSize
        )
        #expect(rect == CGRect(x: 122, y: 260, width: 156, height: 22))
    }

    // MARK: labelledPinIDs fixtures

    @Test func aFarApartBothLabelled() throws {
        var fixture = Fixture()
        let first = try fixture.pin(1, at: CGPoint(x: 100, y: 300))
        let second = try fixture.pin(2, at: CGPoint(x: 300, y: 300))
        #expect(fixture.labelled() == [first.id, second.id])
    }

    /// Same latitude 30pt apart: A's label clears B's circle (y 260 to 282
    /// against 284 to 316), B's label hits A's kept label: one, not none.
    @Test func bSameLatitudeThirtyApartFirstByIDOnly() throws {
        var fixture = Fixture()
        let first = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        _ = try fixture.pin(2, at: CGPoint(x: 230, y: 300))
        #expect(fixture.labelled() == [first.id])
    }

    /// 70pt south: B's label (y 330 to 352) clears A's circle (284 to 316)
    /// and, padded to 326 to 356, A's label (260 to 282).
    @Test func cSeventySouthBothLabelled() throws {
        var fixture = Fixture()
        let north = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        let south = try fixture.pin(2, at: CGPoint(x: 200, y: 370))
        #expect(fixture.labelled() == [north.id, south.id])
    }

    /// 50pt south: B's label (y 310 to 332) covers the bottom 6pt of A's
    /// circle (284 to 316), so B hides. The design review listed this row
    /// as "both"; with its own geometry (32pt circle, 22pt label 18pt above
    /// the centre) both labels first fit at 56pt, pinned by the next test.
    @Test func dFiftySouthOnlyNorthern() throws {
        var fixture = Fixture()
        let north = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        _ = try fixture.pin(2, at: CGPoint(x: 200, y: 350))
        #expect(fixture.labelled() == [north.id])
    }

    /// The vertical threshold: at 56pt B's label top (316) touches A's
    /// circle bottom (316) without overlapping; at 55pt it overlaps by 1pt.
    @Test func dThresholdFiftySixSouthBothFiftyFiveNorthernOnly() throws {
        var touching = Fixture()
        let north = try touching.pin(1, at: CGPoint(x: 200, y: 300))
        let south = try touching.pin(2, at: CGPoint(x: 200, y: 356))
        #expect(touching.labelled() == [north.id, south.id])

        var overlapping = Fixture()
        let north2 = try overlapping.pin(1, at: CGPoint(x: 200, y: 300))
        _ = try overlapping.pin(2, at: CGPoint(x: 200, y: 355))
        #expect(overlapping.labelled() == [north2.id])
    }

    @Test func d2FortySouthOnlyNorthern() throws {
        var fixture = Fixture()
        let north = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        _ = try fixture.pin(2, at: CGPoint(x: 200, y: 340))
        #expect(fixture.labelled() == [north.id])
    }

    /// North-first is by latitude, not by id: the southern pin has the
    /// smaller id and still loses.
    @Test func northFirstBeatsIDOrder() throws {
        var fixture = Fixture()
        _ = try fixture.pin(1, at: CGPoint(x: 200, y: 340))
        let north = try fixture.pin(2, at: CGPoint(x: 200, y: 300))
        #expect(fixture.labelled() == [north.id])
    }

    /// (d) with the southern pin held or dropping: it is placed first (its
    /// rect y 310 to 332, its circle 36pt, y 332 to 368); A's padded label
    /// (256 to 286) clears both, so both show.
    @Test func ePrioritySouthernBothLabelled() throws {
        var fixture = Fixture()
        let north = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        let south = try fixture.pin(2, at: CGPoint(x: 200, y: 350))
        #expect(fixture.labelled(priority: [south.id]) == [north.id, south.id])
    }

    /// A priority label is kept even when it covers a neighbour's circle:
    /// B's label (y 290 to 312) lies on A's circle (284 to 316) and stays.
    /// Without the priority, B hides.
    @Test func ePriorityKeptOverACircle() throws {
        var fixture = Fixture()
        let north = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        let south = try fixture.pin(2, at: CGPoint(x: 200, y: 330))
        #expect(fixture.labelled(priority: [south.id]) == [north.id, south.id])
        #expect(fixture.labelled() == [north.id])
    }

    /// A cluster 40pt above: A's label (y 260 to 282) hits its circle (244
    /// to 276). Clusters never get a label themselves.
    @Test func fClusterAboveHidesTheLabel() throws {
        var fixture = Fixture()
        _ = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        fixture.cluster(at: CGPoint(x: 200, y: 260))
        #expect(fixture.labelled().isEmpty)
    }

    @Test func gNotBlockZoomIsEmpty() throws {
        var fixture = Fixture()
        let first = try fixture.pin(1, at: CGPoint(x: 100, y: 300))
        _ = try fixture.pin(2, at: CGPoint(x: 300, y: 300))
        #expect(fixture.labelled(isBlockZoom: false).isEmpty)
        #expect(fixture.labelled(isBlockZoom: false, priority: [first.id]).isEmpty)
    }

    /// A pin with no point (convert gave nil) is not labelled and blocks
    /// nothing: B would hide A's label if it had a point.
    @Test func hMissingPointIsNeitherCandidateNorObstacle() throws {
        var fixture = Fixture()
        let north = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        let ghost = try fixture.pin(2, at: CGPoint(x: 200, y: 260))
        fixture.points[ghost.id.uuidString] = nil
        #expect(fixture.labelled() == [north.id])
        #expect(fixture.labelled(priority: [ghost.id]) == [north.id])
    }

    /// The held pin drawn by its stand-in (eng F1) is an item like any pin:
    /// kept as priority and its label reserved, so a neighbour that sorts
    /// first by id hides instead.
    @Test func h2StandInIsKeptAndReserved() throws {
        var fixture = Fixture()
        _ = try fixture.pin(1, at: CGPoint(x: 300, y: 350))
        let standIn = try fixture.pin(2, at: CGPoint(x: 200, y: 350))
        #expect(fixture.labelled() != [standIn.id])
        #expect(fixture.labelled(priority: [standIn.id]) == [standIn.id])
    }

    /// The location dot (design D1) blocks a label like a 24pt circle and
    /// is never labelled.
    @Test func userLocationDotIsAnObstacleOnly() throws {
        var fixture = Fixture()
        _ = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        fixture.points[BodegaMapViewModel.userLocationObstacleID] = CGPoint(x: 200, y: 250)
        #expect(fixture.labelled().isEmpty)
        fixture.points[BodegaMapViewModel.userLocationObstacleID] = CGPoint(x: 400, y: 250)
        #expect(fixture.labelled().count == 1)
    }

    /// A user standing on a bodega keeps its name (#67 QA): the 24pt dot
    /// square (y 288 to 312) sits under the label (y 260 to 282).
    @Test func aPinAtTheUserLocationKeepsItsLabel() throws {
        var fixture = Fixture()
        let here = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        _ = try fixture.pin(2, at: CGPoint(x: 230, y: 300))
        fixture.points[BodegaMapViewModel.userLocationObstacleID] = CGPoint(x: 200, y: 300)
        #expect(fixture.labelled() == [here.id])
        fixture.points[BodegaMapViewModel.userLocationObstacleID] = CGPoint(x: 230, y: 300)
        #expect(fixture.labelled() == [here.id])
    }

    /// A label whose rect would cover the 24pt dot square is hidden: the dot
    /// at (200, 272) spans y 260 to 284, across the label's y 260 to 282.
    @Test func aLabelOverTheLocationDotIsHidden() throws {
        var fixture = Fixture()
        _ = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        fixture.points[BodegaMapViewModel.userLocationObstacleID] = CGPoint(x: 200, y: 272)
        #expect(fixture.labelled().isEmpty)
        fixture.points[BodegaMapViewModel.userLocationObstacleID] = CGPoint(x: 200, y: 246)
        #expect(fixture.labelled().count == 1)
    }

    /// Circles clear (130pt apart), labels overlap: the first by id only.
    @Test func kLabelOverlapOnlySecondHidden() throws {
        var fixture = Fixture()
        let first = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        _ = try fixture.pin(2, at: CGPoint(x: 330, y: 300))
        #expect(fixture.labelled() == [first.id])
    }

    /// 160pt apart: 156pt labels leave exactly the 4pt clearance; touching
    /// edges do not intersect.
    @Test func lOneSixtyApartBothLabelled() throws {
        var fixture = Fixture()
        let first = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        let second = try fixture.pin(2, at: CGPoint(x: 360, y: 300))
        #expect(fixture.labelled() == [first.id, second.id])
    }

    @Test func mOneFiftyNineApartSecondHidden() throws {
        var fixture = Fixture()
        let first = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        _ = try fixture.pin(2, at: CGPoint(x: 359, y: 300))
        #expect(fixture.labelled() == [first.id])
    }

    @Test func nPriorityReversesTheWinner() throws {
        var fixture = Fixture()
        _ = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        let second = try fixture.pin(2, at: CGPoint(x: 330, y: 300))
        #expect(fixture.labelled(priority: [second.id]) == [second.id])
    }

    /// During the first add's drop (design D11) only the priority pin is
    /// labelled, even where others would fit.
    @Test func oOnlyPriorityReturnsThePrioritySet() throws {
        var fixture = Fixture()
        _ = try fixture.pin(1, at: CGPoint(x: 50, y: 300))
        let dropping = try fixture.pin(2, at: CGPoint(x: 250, y: 300))
        _ = try fixture.pin(3, at: CGPoint(x: 450, y: 300))
        #expect(fixture.labelled(priority: [dropping.id], onlyPriority: true) == [dropping.id])
        #expect(fixture.labelled(priority: [], onlyPriority: true).isEmpty)
    }

    /// The pan guarantee (spec AC 2, eng F3): a uniform screen translation
    /// changes nothing.
    @Test func aUniformTranslationKeepsTheSameSet() throws {
        var fixture = Fixture()
        for (index, point) in [(1, CGPoint(x: 200, y: 300)), (2, CGPoint(x: 230, y: 300)),
                               (3, CGPoint(x: 200, y: 345)), (4, CGPoint(x: 330, y: 380))] {
            _ = try fixture.pin(index, at: point)
        }
        let before = fixture.labelled()
        fixture.points = fixture.points.mapValues { CGPoint(x: $0.x - 137, y: $0.y + 61) }
        #expect(fixture.labelled() == before)
        #expect(!before.isEmpty)
    }

    /// protects: placement stays cheap for a dense block. fails_when: an
    /// accidental cubic loop (200 pins over 50 ms, best of 5). no_claim: a
    /// benchmark; device timing.
    @Test func twoHundredPinsPlaceQuickly() throws {
        var fixture = Fixture()
        for index in 0..<200 {
            _ = try fixture.pin(index, at: CGPoint(x: Double(index % 20) * 60, y: Double(index / 20) * 60))
        }
        let clock = ContinuousClock()
        var best = Duration.seconds(60)
        for _ in 0..<5 {
            let elapsed = clock.measure { _ = fixture.labelled() }
            best = min(best, elapsed)
        }
        #expect(best < .milliseconds(50))
    }
}
