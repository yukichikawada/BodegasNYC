import MapKit
import SwiftUI

/// The walked trail's strokes (#154, shared by #170 eng A8): runs in the
/// `walked` cyan above the roads, as breadcrumbs (round dots over a 35%
/// track) at the 8 and 5pt bands and a solid line at 3 and 2pt. The main
/// map and the Your Walks day map draw the same content.
struct WalkedTrail: MapContent {
    let runs: [WalkedRun]
    /// The band width (`WalkedOverlay.lineWidth`).
    let lineWidth: Double
    /// Increase Contrast draws no track (#154 DS7); `walked` resolves to its
    /// contrast slot there.
    let isContrastIncreased: Bool

    var body: some MapContent {
        switch WalkedOverlay.trailStyle(width: lineWidth) {
        case .line(let width):
            ForEach(runs) { run in
                // The run's cached `MKPolyline`: a reference in the content
                // list, not a coordinate array copied on every graph update.
                MapPolyline(run.polyline)
                    .stroke(Color.walked, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
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
                            Color.walked.opacity(0.35),
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
                        Color.walked,
                        style: StrokeStyle(lineWidth: dot, lineCap: .round, lineJoin: .round, dash: [0.01, spacing])
                    )
                    .mapOverlayLevel(level: .aboveRoads)
            }
        }
    }
}
