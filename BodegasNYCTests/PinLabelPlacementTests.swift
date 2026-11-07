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
import SwiftUI
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

        mutating func cluster(at point: CGPoint, count: Int = 2) {
            let cluster = MapDisplayItem.Cluster(
                id: "cluster-test",
                coordinate: Coordinate(latitude: 40.73 - Double(point.y) * 0.00001, longitude: -74.0),
                bodegaIDs: (0..<count).map { _ in UUID() }
            )
            items.append(.cluster(cluster))
            points[cluster.id] = point
        }

        var clusterSide: (Int) -> CGFloat = { _ in BodegaMapViewModel.itemObstacleSide }

        func labelled(isBlockZoom: Bool = true, priority: [Bodega.ID] = [], onlyPriority: Bool = false) -> Set<UUID> {
            BodegaMapViewModel.labelledPinIDs(
                items: items,
                points: points,
                isBlockZoom: isBlockZoom,
                priorityIDs: priority,
                onlyPriority: onlyPriority,
                clusterObstacleSide: clusterSide,
                labelSize: PinLabelPlacementTests.testLabelSize
            )
        }
    }

    // MARK: isBlockZoom (design D2: enter at 400 m, leave above 440 m)

    /// protects: labels appear at 400 m or less and stay until above 440 m;
    /// a zero height (the map not laid out) is never block zoom.
    /// fails_when: either threshold moves, the previous state is ignored
    /// (a settle at 420 m blinks every label), or 0 m reads as block zoom.
    /// no_claim: the screen-height measure `MapScreenView` feeds in.
    @Test(arguments: [
        (399.0, false, true), (401.0, false, false), (439.0, false, false), (441.0, false, false),
        (399.0, true, true), (401.0, true, true), (439.0, true, true), (441.0, true, false),
        (400.0, false, true), (440.0, true, true), (0.0, false, false), (0.0, true, false)
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

    /// A badge grows with its count (code review, #67): a "12" at
    /// `.xxLarge` is a 36pt obstacle (`ClusterBadge.measuredObstacleSide`,
    /// checked in `BodegaPinViewTests`). At (295, 271) its 36pt square (x 277
    /// to 313) reaches A's label (x 122 to 278, y 260 to 282); a fixed 32pt
    /// square (x 279 to 311) would not.
    @Test func fGrownClusterBadgeHidesTheLabel() throws {
        var fixture = Fixture()
        let pin = try fixture.pin(1, at: CGPoint(x: 200, y: 300))
        fixture.cluster(at: CGPoint(x: 295, y: 271), count: 12)
        #expect(fixture.labelled() == [pin.id])
        fixture.clusterSide = { $0 >= 10 ? 36 : 32 }
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

// MARK: - The block-zoom camera and the pitch-blind measure (#156)

/// Card for this suite: protects=both landings and the cluster zoom produce
/// the agreed camera, and block zoom, the trail bands, the clustering grid
/// and the nearby radius are blind to pitch while a level camera keeps
/// today's values (eng D4 identity rows); fails_when=distance, pitch, heading
/// or the 420 m floor drifts, a cluster tap zooms out, a pitched settle
/// changes the height or the region spans, or a level settle stops
/// returning MapKit's values; no_claim=MapKit's real pitched region, its
/// pitch clamp or the felt landing (AC 2 to 7 on the simulator).
@Suite
struct BlockZoomCameraTests {
    typealias Model = BodegaMapViewModel
    static let block = Coordinate(latitude: 40.7291, longitude: -73.9965)
    static let portrait = CGSize(width: 402, height: 650)

    static func camera(distance: Double, heading: Double = 0, pitch: Double) -> MapCamera {
        MapCamera(centerCoordinate: block.clLocationCoordinate, distance: distance, heading: heading, pitch: pitch)
    }

    static func region(latitudeSpan: Double, longitudeSpan: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: block.clLocationCoordinate,
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
        )
    }

    // MARK: Camera builders (spec D2, D5; design DS5, DS6, DS8)

    @Test func blockZoomCameraIsFourTwentyMetresWithTheHeadingKept() {
        let camera = Model.blockZoomCamera(center: Self.block, heading: 132, pitch: Model.blockZoomPitch)
        #expect(camera.distance == 420)
        #expect(camera.pitch == 55)
        #expect(camera.heading == 132)
        #expect(Coordinate(camera.centerCoordinate) == Self.block)
    }

    @Test(arguments: [
        (false, false, false, 55.0),
        (true, false, false, 0.0),
        (false, true, false, 0.0),
        (false, false, true, 0.0),
        (true, true, true, 0.0)
    ])
    func landingPitchIsLevelUnderReduceMotionCompactHeightOrTheUsersLevel(
        reduceMotion: Bool, compact: Bool, userLevelled: Bool, expected: Double
    ) {
        #expect(Model.landingPitch(reduceMotion: reduceMotion, compact: compact, userLevelled: userLevelled) == expected)
    }

    @Test func clusterZoomHalvesTheDistanceAndKeepsPitchAndHeading() {
        let camera = Model.clusterZoomCamera(from: Self.camera(distance: 2000, heading: 90, pitch: 40), to: Self.block)
        #expect(camera.distance == 1000)
        #expect(camera.pitch == 40)
        #expect(camera.heading == 90)
    }

    @Test func clusterZoomStopsAtFourTwentyAndNeverZoomsOut() {
        #expect(Model.clusterZoomCamera(from: Self.camera(distance: 600, pitch: 55), to: Self.block).distance == 420)
        // Already closer than 420 m: recentres at the same distance (the old
        // 0.002 span floor zoomed out here).
        #expect(Model.clusterZoomCamera(from: Self.camera(distance: 300, pitch: 55), to: Self.block).distance == 300)
    }

    /// Identity (eng D4): at a level, north-up camera a tap still halves.
    @Test func clusterZoomAtALevelCameraStillHalvesLevel() {
        let camera = Model.clusterZoomCamera(from: Self.camera(distance: 5000, pitch: 0), to: Self.block)
        #expect(camera.distance == 2500)
        #expect(camera.pitch == 0)
        #expect(camera.heading == 0)
    }

    @Test func pitchToggleShowsAtOrUnderEightFortyMetresAndNeverWhilePlacing() {
        #expect(Model.showsPitchToggle(settledDistance: 420, isPlacing: false))
        #expect(Model.showsPitchToggle(settledDistance: 840, isPlacing: false))
        #expect(!Model.showsPitchToggle(settledDistance: 841, isPlacing: false))
        #expect(!Model.showsPitchToggle(settledDistance: 420, isPlacing: true))
        #expect(!Model.showsPitchToggle(settledDistance: nil, isPlacing: false))
    }

    // MARK: The measure (spec D3)

    @Test func levelHeightRatioIsMeasuredOverDistanceAtALevelCamera() {
        #expect(Model.levelHeightRatio(measuredMeters: 350.2, distance: 850, pitch: 0) == 350.2 / 850)
        #expect(Model.levelHeightRatio(measuredMeters: 173, distance: 420, pitch: 0.4) == 173.0 / 420)
    }

    @Test func levelHeightRatioIsNilPitchedOrWithoutAMeasure() {
        #expect(Model.levelHeightRatio(measuredMeters: 900, distance: 420, pitch: 55) == nil)
        #expect(Model.levelHeightRatio(measuredMeters: 0, distance: 420, pitch: 0) == nil)
        #expect(Model.levelHeightRatio(measuredMeters: nil, distance: 420, pitch: 0) == nil)
    }

    /// Identity (eng D4): level, the measured height, the ratio ignored.
    @Test func levelEquivalentHeightAtALevelCameraIsTheMeasure() {
        let ratio = LevelHeightRatio(mapHeight: 650, ratio: 0.412)
        let height = Model.levelEquivalentHeight(
            measuredMeters: 350.2, distance: 850, pitch: 0, ratio: ratio, mapHeight: 650
        )
        #expect(height == 350.2)
        #expect(Model.levelEquivalentHeight(measuredMeters: nil, distance: 850, pitch: 0, ratio: ratio, mapHeight: 650) == nil)
    }

    @Test func levelEquivalentHeightPitchedIsDistanceTimesTheRatioForThisMapHeight() {
        let ratio = LevelHeightRatio(mapHeight: 650, ratio: 0.412)
        let height = Model.levelEquivalentHeight(
            measuredMeters: 1900, distance: 420, pitch: 55, ratio: ratio, mapHeight: 650
        )
        #expect(abs((height ?? 0) - 173.04) < 0.001)
    }

    @Test func levelEquivalentHeightPitchedWithoutARatioForThisHeightIsTheMeasure() {
        let landscape = LevelHeightRatio(mapHeight: 300, ratio: 0.3)
        #expect(Model.levelEquivalentHeight(
            measuredMeters: 1900, distance: 420, pitch: 55, ratio: landscape, mapHeight: 650
        ) == 1900)
        #expect(Model.levelEquivalentHeight(
            measuredMeters: nil, distance: 420, pitch: 55, ratio: nil, mapHeight: 650
        ) == nil)
    }

    // MARK: The data region (eng D2) and the frame (Shape B)

    /// Identity (eng D4): level, MapKit's region unchanged.
    @Test func levelEquivalentRegionAtALevelCameraIsMapKitsRegion() {
        let region = Self.region(latitudeSpan: 0.0031, longitudeSpan: 0.0026)
        let result = Model.levelEquivalentRegion(
            camera: Self.camera(distance: 420, pitch: 0), region: region, heightMeters: 173, mapSize: Self.portrait
        )
        #expect(result.span.latitudeDelta == 0.0031)
        #expect(result.span.longitudeDelta == 0.0026)
    }

    @Test func levelEquivalentRegionPitchedTakesItsSpansFromTheHeightAndAspect() {
        let reported = Self.region(latitudeSpan: 0.02, longitudeSpan: 0.012)
        let result = Model.levelEquivalentRegion(
            camera: Self.camera(distance: 420, pitch: 55), region: reported, heightMeters: 173, mapSize: Self.portrait
        )
        let latitudeDelta = 173 / Model.metersPerDegreeLatitude
        #expect(abs(result.span.latitudeDelta - latitudeDelta) < 1e-12)
        let longitudeDelta = latitudeDelta * (402.0 / 650.0) / cos(Self.block.latitude * .pi / 180)
        #expect(abs(result.span.longitudeDelta - longitudeDelta) < 1e-12)
        #expect(Coordinate(result.center) == Self.block)
    }

    @Test func settledFrameComposesTheHeightTheDataRegionAndThePitchedRadius() {
        let ratio = LevelHeightRatio(mapHeight: 650, ratio: 0.412)
        // MapKit's pitched region: about 1.1 km to the north edge.
        let reported = Self.region(latitudeSpan: 0.02, longitudeSpan: 0.012)
        let pitched = Model.settledFrame(
            camera: Self.camera(distance: 420, pitch: 55), region: reported,
            measuredHeight: 2400, mapSize: Self.portrait, ratio: ratio
        )
        #expect(abs((pitched.heightMeters ?? 0) - 173.04) < 0.001)
        #expect(pitched.dataRegion.span.latitudeDelta < 0.002)
        #expect(pitched.nearbyRadiusMeters == 1000)
        // A shallow pitched region: the 200 m floor.
        let shallow = Model.settledFrame(
            camera: Self.camera(distance: 420, pitch: 55),
            region: Self.region(latitudeSpan: 0.001, longitudeSpan: 0.001),
            measuredHeight: 300, mapSize: Self.portrait, ratio: ratio
        )
        #expect(shallow.nearbyRadiusMeters == 200)
        // Level (identity): MapKit's region, the measured height, no radius.
        let level = Model.settledFrame(
            camera: Self.camera(distance: 420, pitch: 0), region: reported,
            measuredHeight: 173, mapSize: Self.portrait, ratio: ratio
        )
        #expect(level.heightMeters == 173)
        #expect(level.dataRegion.span.latitudeDelta == 0.02)
        #expect(level.nearbyRadiusMeters == nil)
    }

    /// Design DS2: label candidates come from the data region, so at a
    /// pitched settle a pin up the street (inside MapKit's region) is not a
    /// candidate; level, the data region is MapKit's and nothing changes.
    @Test func labelCandidatesFromThePitchedDataRegionLeaveTheFarField() throws {
        let near = try makeTestBodega(name: "Near", latitude: Self.block.latitude + 0.0005, longitude: Self.block.longitude)
        let far = try makeTestBodega(name: "Far", latitude: Self.block.latitude + 0.008, longitude: Self.block.longitude)
        let items: [MapDisplayItem] = [.pin(near), .pin(far)]
        let reported = Self.region(latitudeSpan: 0.02, longitudeSpan: 0.012)
        let ratio = LevelHeightRatio(mapHeight: 650, ratio: 0.412)
        let pitched = Model.settledFrame(
            camera: Self.camera(distance: 420, pitch: 55), region: reported,
            measuredHeight: 2400, mapSize: Self.portrait, ratio: ratio
        )
        #expect(Model.labelCandidates(items, near: pitched.dataRegion).map(\.id) == [MapDisplayItem.pin(near).id])
        let level = Model.settledFrame(
            camera: Self.camera(distance: 420, pitch: 0), region: reported,
            measuredHeight: 173, mapSize: Self.portrait, ratio: ratio
        )
        #expect(Model.labelCandidates(items, near: level.dataRegion).count == 2)
    }

    // MARK: The user's level (design DS6)

    @Test func userLevelledIsSetByAHandLevelAndClearedByAPitchedSettle() {
        #expect(Model.userLevelled(was: false, previousPitch: 55, settledPitch: 0, appLevelWriteInFlight: false))
        #expect(!Model.userLevelled(was: false, previousPitch: 55, settledPitch: 0, appLevelWriteInFlight: true))
        #expect(!Model.userLevelled(was: true, previousPitch: 0, settledPitch: 40, appLevelWriteInFlight: false))
        #expect(Model.userLevelled(was: true, previousPitch: 0, settledPitch: 0, appLevelWriteInFlight: false))
        // A shallow tilt (under 5°) neither sets nor clears it.
        #expect(!Model.userLevelled(was: false, previousPitch: 3, settledPitch: 0, appLevelWriteInFlight: false))
        #expect(Model.userLevelled(was: true, previousPitch: 0, settledPitch: 3, appLevelWriteInFlight: false))
    }
}
