import MapKit
import SwiftUI

/// The walked trail's strokes (#154, shared by #170 eng A8): runs in the
/// `walked` cyan above the roads, as breadcrumbs (round dots over a 35%
/// track) at the 8 and 5pt bands and a solid line at 3 and 2pt. The main
/// map and the Your Walks day map draw the same content.
///
/// A walk someone sent you (#177 DS1) is `.shared`: the `sharedWalk`
/// violet as a solid line with round caps and joins at every band (8, 5, 3
/// and 2pt), no breadcrumbs and no track, so where it ever meets the cyan
/// the two differ in shape as well as colour. Increase Contrast resolves
/// the asset to its contrast slot; the line stays solid.
struct WalkedTrail: MapContent {
    /// Whose walk the trail draws.
    enum Style: Equatable {
        /// Yours: `walked` cyan, breadcrumbs at the wide bands.
        case walked
        /// Someone else's: `sharedWalk` violet, a solid line at every band.
        case shared
    }

    let runs: [WalkedRun]
    /// The band width (`WalkedOverlay.lineWidth`).
    let lineWidth: Double
    /// Increase Contrast draws no track (#154 DS7); `walked` resolves to its
    /// contrast slot there.
    let isContrastIncreased: Bool
    var style: Style = .walked

    /// How `style` draws a band of `width`: a shared walk is a solid line at
    /// every band; yours follows `WalkedOverlay.trailStyle`.
    static func trailStyle(_ style: Style, width: Double) -> WalkedOverlay.TrailStyle {
        switch style {
        case .walked: WalkedOverlay.trailStyle(width: width)
        case .shared: .line(width: width)
        }
    }

    var body: some MapContent {
        let color = style == .shared ? Color.sharedWalk : Color.walked
        switch Self.trailStyle(style, width: lineWidth) {
        case .line(let width):
            ForEach(runs) { run in
                // The run's cached `MKPolyline`: a reference in the content
                // list, not a coordinate array copied on every graph update.
                MapPolyline(run.polyline)
                    .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
            }
        case .breadcrumbs(let dot, let spacing, let track):
            // Two passes (#154 eng D3): every run's track first, then every
            // run's dots, so no track covers another run's dots where runs
            // cross.
            if !isContrastIncreased {
                ForEach(runs) { run in
                    MapPolyline(run.polyline)
                        .stroke(
                            color.opacity(0.35),
                            style: StrokeStyle(lineWidth: track, lineCap: .round, lineJoin: .round)
                        )
                        .mapOverlayLevel(level: .aboveRoads)
                }
            }
            ForEach(runs) { run in
                // Zero-length dashes with round caps draw as dots; the
                // 0.01pt dash is accepted, not compensated.
                MapPolyline(run.polyline)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: dot, lineCap: .round, lineJoin: .round, dash: [0.01, spacing])
                    )
                    .mapOverlayLevel(level: .aboveRoads)
            }
        }
    }
}
