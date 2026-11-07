import CoreGraphics
import CoreLocation
import MapKit
import SwiftUI

/// The pitched landing (#156): Locate Me and Show on Map fly to one
/// `MapCamera`, a cluster tap keeps the user's pitch and heading, and every
/// rule that reads how much ground is on screen (block zoom, the trail
/// bands, the clustering grid, the nearby radius) sees a pitched camera as
/// the level camera at the same distance. Pure and unit-tested
/// (`PinLabelPlacementTests`, `LocateMeTests`). Beside the block-zoom rules
/// in `BodegaMapViewModel+PinLabels.swift` (#156 eng D1), in a file of its
/// own only to keep that one under SwiftLint's 400-line `file_length`.
nonisolated extension BodegaMapViewModel {
    /// The camera distance both block-zoom landings fly to (#156 spec D5,
    /// the probe's 420 m shot), replacing #84's 850 m Locate Me distance.
    /// Calibrated on the iPhone 17 Pro simulator (2026-11-07): see
    /// DESIGN.md Motion, Locate Me, for the measured level-equivalent height.
    static let blockZoomCameraDistance: Double = 420
    /// The landing's pitch when nothing asks for a level one (spec D2).
    static let blockZoomPitch: Double = 55
    /// Under this a camera is level: its measured height is the true one
    /// and calibrates the ratio (spec D3).
    static let levelPitchMaximum: Double = 0.5
    /// Over this a settle counts as pitched for `userLevelled` (design DS6).
    static let pitchedPitchMinimum: Double = 5
    /// The pitch toggle shows at or under this settled distance (design DS7).
    static let pitchToggleMaximumDistance: Double = 2 * blockZoomCameraDistance
    /// At a pitched settle the `.nearby` radius is MapKit's north-edge
    /// distance in this range (design DS4); level settles keep 200 m to 5 km.
    static let pitchedNearbyRadiusRange: ClosedRange<Double> = 200...1000
    /// Metres per degree of latitude on CoreLocation's sphere.
    static let metersPerDegreeLatitude: Double = 111_195

    /// 3D buildings on the browse map (#156): MapKit draws them only when
    /// the camera is pitched, so every level view looks as before. The AC 12
    /// and AC 13 fallback is `.flat` (pitch kept). The detail preview is
    /// always `.flat` (#150 R1).
    static var browseMapElevation: MapStyle.Elevation { .realistic }

    /// The landing's pitch (design DS5, DS6, DS8): level under Reduce Motion
    /// (the pan stays, the tilt does not), in the compact vertical size class
    /// (landscape phones) and while the user's own level holds; else 55°.
    static func landingPitch(reduceMotion: Bool, compact: Bool, userLevelled: Bool) -> Double {
        reduceMotion || compact || userLevelled ? 0 : blockZoomPitch
    }

    /// How much of `cameraCenter`'s 74 m screen-down offset a landing at
    /// `pitch` uses. Pitched, all of it: the far side is compressed and the
    /// pin lands about a quarter of the way down (measured 26%, iPhone 17
    /// Pro simulator). Level, 0.4 (about 30 m): a level 420 m camera shows
    /// only about 173 m of ground, so the full 74 m put the pin 7% from the
    /// top, under the toolbar (simulator, 2026-11-07); 0.4 is a sixth of that
    /// height, the add flow's proportion, so the pin sits about a third down.
    static func landingOffsetScale(pitch: Double) -> Double {
        pitch < levelPitchMaximum ? 0.4 : 1
    }

    /// The camera both block-zoom landings fly to: 420 m, the heading kept
    /// from the settled camera, the pitch `landingPitch` chose.
    static func blockZoomCamera(center: Coordinate, heading: Double, pitch: Double) -> MapCamera {
        MapCamera(
            centerCoordinate: center.clLocationCoordinate,
            distance: blockZoomCameraDistance,
            heading: heading,
            pitch: pitch
        )
    }

    /// A cluster tap: half the settled distance, never closer than the
    /// landing's 420 m and never farther than before (closer than 420 m it
    /// recentres at the same distance); pitch and heading kept, so a tap
    /// never levels the user's tilt.
    static func clusterZoomCamera(from settled: MapCamera, to center: Coordinate) -> MapCamera {
        MapCamera(
            centerCoordinate: center.clLocationCoordinate,
            distance: min(settled.distance, max(settled.distance / 2, blockZoomCameraDistance)),
            heading: settled.heading,
            pitch: settled.pitch
        )
    }

    /// Locate Me's "already there" (#84 R4, #156): the target is the
    /// settled camera itself (centre and distance within 1 m, pitch within
    /// 0.5°), so no settle will follow the write and the fetch runs at once.
    /// A hand-levelled map is not there: the next tap re-pitches it.
    static func landsOnSettledCamera(settled: MapCamera?, target: MapCamera) -> Bool {
        guard let settled else { return false }
        return Coordinate(settled.centerCoordinate).distance(to: Coordinate(target.centerCoordinate)) < 1
            && abs(settled.distance - target.distance) < 1
            && abs(settled.pitch - target.pitch) < levelPitchMaximum
    }

    /// Whether the pitch toggle shows (design DS7): at or under 840 m of
    /// settled distance and never while placing (a pitch there would move
    /// the crosshair's ground point). No settle yet: hidden.
    static func showsPitchToggle(settledDistance: Double?, isPlacing: Bool) -> Bool {
        guard let settledDistance, !isPlacing else { return false }
        return settledDistance <= pitchToggleMaximumDistance
    }

    /// The level height-to-distance ratio a settle calibrates (spec D3): the
    /// measured height over the distance at a level camera with a positive
    /// measure, else `nil` (a pitched camera measures far up the street).
    static func levelHeightRatio(measuredMeters: Double?, distance: Double, pitch: Double) -> Double? {
        guard pitch < levelPitchMaximum, let measuredMeters, measuredMeters > 0, distance > 0 else { return nil }
        return measuredMeters / distance
    }

    /// The height block zoom and the trail bands are judged by (spec D3):
    /// level, the measured height; pitched with a ratio measured at this map
    /// height, distance times that ratio; otherwise (a rotation while
    /// pitched, a cold start pitched) the measured value, `nil` included,
    /// until the next level settle at this height calibrates.
    static func levelEquivalentHeight(
        measuredMeters: Double?,
        distance: Double,
        pitch: Double,
        ratio: LevelHeightRatio?,
        mapHeight: CGFloat
    ) -> Double? {
        guard pitch >= levelPitchMaximum else { return measuredMeters }
        guard let ratio, ratio.mapHeight == mapHeight, distance > 0 else { return measuredMeters }
        return distance * ratio.ratio
    }

    /// The region the view model clusters by (eng D2): level, MapKit's
    /// region unchanged; pitched, the level camera's region at this
    /// distance, centred on the camera, `heightMeters` tall and as wide as
    /// the map's aspect. No height, no map size or a pole: MapKit's region.
    static func levelEquivalentRegion(
        camera: MapCamera,
        region: MKCoordinateRegion,
        heightMeters: Double?,
        mapSize: CGSize
    ) -> MKCoordinateRegion {
        guard camera.pitch >= levelPitchMaximum, let heightMeters, heightMeters > 0,
              mapSize.width > 0, mapSize.height > 0 else { return region }
        let cosine = cos(camera.centerCoordinate.latitude * .pi / 180)
        guard cosine.isFinite, cosine > 0.01 else { return region }
        let latitudeDelta = heightMeters / metersPerDegreeLatitude
        let longitudeDelta = latitudeDelta * Double(mapSize.width / mapSize.height) / cosine
        return MKCoordinateRegion(
            center: camera.centerCoordinate,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }

    /// The ground distance from `region`'s centre to its north edge: the
    /// `.nearby` fetch radius before clamping.
    static func northEdgeMeters(of region: MKCoordinateRegion) -> Double {
        let north = Coordinate(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude
        )
        return Coordinate(region.center).distance(to: north)
    }

    /// What a settle means to the app once pitch is taken out (eng Shape B):
    /// the height block zoom and the bands read; the region the view model
    /// clusters by and the labels are chosen from (the near field, design
    /// DS2); at a pitched settle, the `.nearby` radius from MapKit's own
    /// region clamped to 200 m to 1 km (design DS4; `nil` keeps the level
    /// rule). The walked trail keeps culling with MapKit's region (eng D3).
    static func settledFrame(
        camera: MapCamera,
        region: MKCoordinateRegion,
        measuredHeight: Double?,
        mapSize: CGSize,
        ratio: LevelHeightRatio?
    ) -> SettledFrame {
        let height = levelEquivalentHeight(
            measuredMeters: measuredHeight,
            distance: camera.distance,
            pitch: camera.pitch,
            ratio: ratio,
            mapHeight: mapSize.height
        )
        guard camera.pitch >= levelPitchMaximum else {
            return SettledFrame(heightMeters: height, dataRegion: region, nearbyRadiusMeters: nil)
        }
        let range = pitchedNearbyRadiusRange
        return SettledFrame(
            heightMeters: height,
            dataRegion: levelEquivalentRegion(camera: camera, region: region, heightMeters: height, mapSize: mapSize),
            nearbyRadiusMeters: min(max(northEdgeMeters(of: region), range.lowerBound), range.upperBound)
        )
    }

    /// Design DS6: a level the user made holds for the session. Set when a
    /// settle goes from pitched (over 5°) to level (under 0.5°) with no app
    /// levelling write in flight; cleared when a settle arrives pitched;
    /// otherwise unchanged.
    static func userLevelled(
        was: Bool,
        previousPitch: Double?,
        settledPitch: Double,
        appLevelWriteInFlight: Bool
    ) -> Bool {
        if settledPitch > pitchedPitchMinimum { return false }
        guard settledPitch < levelPitchMaximum, let previousPitch, previousPitch > pitchedPitchMinimum,
              !appLevelWriteInFlight else { return was }
        return true
    }
}

/// The level ratio a level settle measured, keyed by the map height it was
/// measured at: a rotation changes the ratio.
nonisolated struct LevelHeightRatio: Equatable, Sendable {
    let mapHeight: CGFloat
    let ratio: Double
}

/// One settle with pitch taken out (eng Shape B, `BodegaMapViewModel.settledFrame`).
nonisolated struct SettledFrame {
    /// The level-equivalent visible height; `nil` is no measure (not block
    /// zoom, the trail keeps its width).
    let heightMeters: Double?
    /// The near field: MapKit's region when level, the level-equivalent box
    /// when pitched. The far field is the rest of MapKit's region.
    let dataRegion: MKCoordinateRegion
    /// The pitched `.nearby` radius (design DS4), `nil` when level.
    let nearbyRadiusMeters: Double?
}
