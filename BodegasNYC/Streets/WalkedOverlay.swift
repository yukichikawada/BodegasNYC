import Foundation
import MapKit

/// What the walked layer draws: the visible pieces (#119) with, at the
/// breadcrumb bands, the runs that carry the dots, or over the cap; and the
/// stroke width. It changes only when the camera is at rest (design D10), so
/// nothing the Map's content reads changes during a pan or pinch (the R3
/// device trace showed a graph update on every mid-gesture region change).
nonisolated struct WalkedOverlayDisplay: Sendable, Equatable {
    var visible = WalkedOverlay.Visible.empty
    var lineWidth = WalkedOverlay.widestBeyond
    /// Whether the piece/vertex cap hid the layer at the last settle: the
    /// state DS2's hysteresis reads. Kept apart from the dots' run cap, so a
    /// breadcrumb view hidden by 500+ dot runs does not make the next line
    /// view clear the stricter 10%-under bar.
    var isHiddenByPieceCap = false

    /// Recomputes for the current data and settled camera. While the camera
    /// moves it does nothing; the settle that ends the gesture calls it
    /// again. Culling reads the spatial indexes, so the cost follows the
    /// cells in view. Returns whether anything the map draws changed; when
    /// nothing did, the caller writes no state and the Map's content is not
    /// touched.
    ///
    /// The cap (#119 eng D9, design DS2): over `maxDrawnPieces` pieces or
    /// `maxDrawnVertices` vertices the whole layer hides, never a subset.
    /// A drawing layer hides only once a count is 10% over its cap; a
    /// hidden one draws again only once both are 10% under. At the
    /// breadcrumb bands the dots' runs keep #154's 500-run cap.
    @discardableResult
    mutating func refresh(
        index: WalkedLayerIndex,
        showsOverlay: Bool,
        region: WalkedRegion?,
        visibleHeightMeters: Double?,
        isCameraMoving: Bool
    ) -> Bool {
        guard !isCameraMoving else { return false }
        let before = self
        if let visibleHeightMeters {
            lineWidth = WalkedOverlay.lineWidth(visibleHeightMeters: visibleHeightMeters, current: lineWidth)
        }
        if showsOverlay, let region {
            let next = WalkedOverlay.visibleAndCap(
                index: index, in: region, style: WalkedOverlay.trailStyle(width: lineWidth),
                wasHidden: isHiddenByPieceCap
            )
            visible = next.visible
            isHiddenByPieceCap = next.piecesOverCap
        } else {
            // Nothing to draw resets the cap state (design DS6: Show on Map
            // off and on redraws with no card flash).
            visible = .empty
            isHiddenByPieceCap = false
        }
        return self != before
    }
}

/// The two spatial indexes the walked layer culls (#119): the pieces, which
/// carry every line and the breadcrumb track, and the runs, which carry the
/// breadcrumb dots (owner decision 2026-11-10). Built together off the main
/// actor from the same walked set.
nonisolated struct WalkedLayerIndex: Sendable, Equatable {
    var pieces: WalkedPieceIndex
    var runs: WalkedRunIndex

    static let empty = WalkedLayerIndex(pieces: .empty, runs: .empty)
}

/// A settled camera's visible region as plain numbers, so the overlay's
/// culling stays a pure function.
nonisolated struct WalkedRegion: Sendable, Equatable {
    var centerLatitude: Double
    var centerLongitude: Double
    var latitudeDelta: Double
    var longitudeDelta: Double
}

/// The overlay's pure rules (#108 spec Implementation 6, eng R3, design
/// D2/D3; #119).
nonisolated enum WalkedOverlay {
    /// The region is expanded by this fraction of its span on each side.
    static let regionMargin = 0.25
    static let joinToleranceMeters = 1.0
    /// An interior vertex within this of the line through its neighbours is
    /// dropped from the drawn polyline: well under a point at the 8pt zoom.
    static let simplifyToleranceMeters = 0.5

    /// What the map draws at a settled camera.
    nonisolated enum Visible: Sendable, Equatable {
        /// The pieces in view, in id order; `dotRuns` are the runs in view
        /// at the breadcrumb bands (empty at the line bands).
        case pieces([WalkedPiece], dotRuns: [WalkedRun])
        /// Over the cap: draw nothing and say "Zoom in to see your blocks."
        case overCap

        static let empty = Visible.pieces([], dotRuns: [])
    }

    // MARK: Cap (#119 eng D9, design DS1/DS2)

    /// More drawn piece vertices than this and the layer hides. Phase 0 on
    /// the owner's iPhone 17 Pro Max (2026-11-10): all of Manhattan in view
    /// on the 5,006-block seed drew 93 pieces, 9,616 vertices, in 22 to 23 ms
    /// of overlay work against 68 to 70 ms for main's 593 runs; rounded down
    /// to a multiple of 1,000. No higher count was measured.
    static let maxDrawnVertices = 9_000
    /// More drawn pieces than this and the layer hides. Phase 0 drew at most
    /// 93; 1,000 is the overlay count #108's R3 device check measured as
    /// smooth, and the floor design DS1 sets (1,000 isolated pieces draw).
    static let maxDrawnPieces = 1_000
    /// Design DS2: hide only 10% over a cap, show again only 10% under both.
    static let capHysteresis = 0.10
    /// #154 eng D8, kept for the dots: a breadcrumb run is one dot polyline
    /// over a track on the pieces, and the layer hides past 500 dot runs, as
    /// it did before #119.
    static let maxDotRuns = 500

    /// Whether `pieces` and `vertices` are over the cap, given whether the
    /// layer is hidden now (design DS2).
    static func isOverCap(pieces: Int, vertices: Int, wasHidden: Bool) -> Bool {
        let factor = wasHidden ? 1 - capHysteresis : 1 + capHysteresis
        return Double(pieces) > Double(maxDrawnPieces) * factor
            || Double(vertices) > Double(maxDrawnVertices) * factor
    }

    /// The pieces (and at the breadcrumb bands the dot runs) for `region`, or
    /// `overCap`. Never a subset; an empty index is nothing to draw, never
    /// over the cap (design DS6).
    static func visible(
        index: WalkedLayerIndex,
        in region: WalkedRegion,
        style: TrailStyle,
        wasHidden: Bool
    ) -> Visible {
        visibleAndCap(index: index, in: region, style: style, wasHidden: wasHidden).visible
    }

    /// `visible(...)` and whether the piece/vertex cap is what hid it.
    static func visibleAndCap(
        index: WalkedLayerIndex,
        in region: WalkedRegion,
        style: TrailStyle,
        wasHidden: Bool
    ) -> (visible: Visible, piecesOverCap: Bool) {
        let pieces = index.pieces.visible(in: region)
        let vertices = pieces.reduce(0) { $0 + $1.vertexCount }
        guard !isOverCap(pieces: pieces.count, vertices: vertices, wasHidden: wasHidden) else {
            return (.overCap, true)
        }
        guard case .breadcrumbs = style else { return (.pieces(pieces, dotRuns: []), false) }
        guard let dotRuns = index.runs.visible(in: region, cap: maxDotRuns) else { return (.overCap, false) }
        return (.pieces(pieces, dotRuns: dotRuns), false)
    }

    // MARK: Simplification

    /// `coordinates` without collinear interior vertices: a vertex is kept
    /// only if it sits more than `simplifyToleranceMeters` off the segment
    /// from the last kept vertex to the next one. Ends are always kept. A
    /// run along a straight avenue draws as two points.
    static func simplified(_ coordinates: [Coordinate]) -> [Coordinate] {
        guard coordinates.count > 2 else { return coordinates }
        var kept = [coordinates[0]]
        for index in 1 ..< (coordinates.count - 1) {
            let anchor = kept[kept.count - 1]
            if offset(of: coordinates[index], fromSegment: anchor, coordinates[index + 1]) > simplifyToleranceMeters {
                kept.append(coordinates[index])
            }
        }
        kept.append(coordinates[coordinates.count - 1])
        return kept
    }

    /// Metres from `point` to the segment `start`-`end`, in the local plane.
    private static func offset(of point: Coordinate, fromSegment start: Coordinate, _ end: Coordinate) -> Double {
        let scaleX = cos(point.latitude * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator
        let scaleY = StreetGrid.metersPerDegreeLatitude
        let startX = (start.longitude - point.longitude) * scaleX
        let startY = (start.latitude - point.latitude) * scaleY
        let edgeX = (end.longitude - point.longitude) * scaleX - startX
        let edgeY = (end.latitude - point.latitude) * scaleY - startY
        let lengthSquared = edgeX * edgeX + edgeY * edgeY
        let along = lengthSquared > 0 ? min(1, max(0, -(startX * edgeX + startY * edgeY) / lengthSquared)) : 0
        let nearestX = startX + along * edgeX
        let nearestY = startY + along * edgeY
        return (nearestX * nearestX + nearestY * nearestY).squareRoot()
    }

    // MARK: Culling

    struct Bounds {
        var minLatitude: Double
        var maxLatitude: Double
        var minLongitude: Double
        var maxLongitude: Double

        /// Whether a box meets these bounds (edges touching count).
        func meets(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) -> Bool {
            maxLatitude >= self.minLatitude && minLatitude <= self.maxLatitude
                && maxLongitude >= self.minLongitude && minLongitude <= self.maxLongitude
        }
    }

    /// The region expanded by `regionMargin` of its span on each side.
    static func expandedBounds(_ region: WalkedRegion) -> Bounds {
        let halfLatitude = region.latitudeDelta * (0.5 + regionMargin)
        let halfLongitude = region.longitudeDelta * (0.5 + regionMargin)
        return Bounds(
            minLatitude: region.centerLatitude - halfLatitude,
            maxLatitude: region.centerLatitude + halfLatitude,
            minLongitude: region.centerLongitude - halfLongitude,
            maxLongitude: region.centerLongitude + halfLongitude
        )
    }

    static func meets(_ run: WalkedRun, _ bounds: Bounds) -> Bool {
        bounds.meets(
            minLatitude: run.minLatitude, maxLatitude: run.maxLatitude,
            minLongitude: run.minLongitude, maxLongitude: run.maxLongitude
        )
    }

    static func meets(_ piece: WalkedPiece, _ bounds: Bounds) -> Bool {
        bounds.meets(
            minLatitude: piece.minLatitude, maxLatitude: piece.maxLatitude,
            minLongitude: piece.minLongitude, maxLongitude: piece.maxLongitude
        )
    }

    // MARK: Stroke width (design D2)

    /// Up to 400 m of visible height 8pt, up to 2 km 5pt, up to 8 km 3pt,
    /// above that 2pt. Leaving a band takes 10% more height than entering it.
    /// Visible height is `MapScreenView.visibleHeightMeters`, not the full
    /// screen (#113).
    static let widthBands: [WidthBand] = [
        WidthBand(maxHeight: 400, width: 8),
        WidthBand(maxHeight: 2_000, width: 5),
        WidthBand(maxHeight: 8_000, width: 3)
    ]
    static let widestBeyond = 2.0
    static let hysteresis = 0.10

    struct WidthBand {
        let maxHeight: Double
        let width: Double
    }

    static func lineWidth(visibleHeightMeters height: Double, current: Double?) -> Double {
        let entered = widthBands.first { height <= $0.maxHeight }?.width ?? widestBeyond
        guard let current, current > entered,
              let band = widthBands.first(where: { $0.width == current })
        else { return entered }
        // Zooming out from a thicker band: stay until 10% past its edge.
        return height <= band.maxHeight * (1 + hysteresis) ? current : entered
    }

    // MARK: Trail style (#154 eng D1)

    /// How a band's width is drawn.
    enum TrailStyle: Equatable {
        /// Round dots of `dot` pt every `spacing` pt (centre to centre), over
        /// a translucent track `track` pt wide.
        case breadcrumbs(dot: Double, spacing: Double, track: Double)
        case line(width: Double)
    }

    /// Breadcrumbs at the 8 and 5pt bands (visible height up to 2 km), a
    /// plain line at 3 and 2pt: the trail cools as you leave your block.
    /// Dots and track are capped so block zoom does not draw a 10pt dot on a
    /// 22pt track.
    static func trailStyle(width: Double) -> TrailStyle {
        guard width >= 5 else { return .line(width: width) }
        return .breadcrumbs(
            dot: min(width * 1.3, 8),
            spacing: min(width * 2.6, 16),
            track: min(width * 2.8, 16)
        )
    }
}
