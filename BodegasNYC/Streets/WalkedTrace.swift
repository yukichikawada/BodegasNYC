import CoreFoundation
import Foundation
import MapKit
import os
import QuartzCore
import SwiftUI

/// Signposts and log lines for measuring the walked layer on a device
/// (#119 eng D2-D4; kept from the Phase 0 probe because the PR build is
/// re-measured on the owner's iPhone before merge, eng D4). Release-safe:
/// signposts cost next to nothing when no instrument records them, and the
/// log lines are one `notice` per settle and per summary build.
///
/// Signposts (Points of Interest, subsystem `BodegasNYC.walkedProbe`):
/// event `WalkedSettle` on every settle, interval `WalkedApply` from a
/// write to the end of the run loop pass that applies it. Log lines,
/// category `walked`: `WALKED_SETTLE ...` and `WALKED_BUILD ...`.
nonisolated enum WalkedTrace {
    /// Not the bundle identifier: test builds install under another one.
    /// Unchanged from the probe so the Phase 0 recipe still reads it.
    static let subsystem = "BodegasNYC.walkedProbe"
    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    static let logger = Logger(subsystem: subsystem, category: "walked")

    /// What a display draws, counted for the log.
    nonisolated struct Counts: Sendable, Equatable {
        var pieces = 0
        var dotRuns = 0
        /// Drawn piece vertices (the cap's count) plus the dot runs'.
        var vertices = 0
        /// `MapPolyline`s in the Map's content: one per piece at 3 and 2pt;
        /// at 8 and 5pt one track per piece (none under Increase Contrast)
        /// plus one dot line per run.
        var polylines = 0
        var overCap = false
    }

    static func counts(_ display: WalkedOverlayDisplay, drawsTrack: Bool) -> Counts {
        var counts = Counts()
        guard case .pieces(let pieces, let dotRuns) = display.visible else {
            counts.overCap = true
            return counts
        }
        counts.pieces = pieces.count
        counts.dotRuns = dotRuns.count
        counts.vertices = pieces.reduce(0) { $0 + $1.vertexCount } + dotRuns.reduce(0) { $0 + $1.polyline.pointCount }
        switch WalkedOverlay.trailStyle(width: display.lineWidth) {
        case .breadcrumbs: counts.polylines = (drawsTrack ? pieces.count : 0) + dotRuns.count
        case .line: counts.polylines = pieces.count
        }
        return counts
    }

    /// Settles seen since launch (the A/B divides by the driver's own count).
    @MainActor static var sequence = 0

    /// One settle as recorded: why it ran, whether it wrote, what it draws.
    nonisolated struct Settle: Sendable {
        var reason: String
        var changed: Bool
        var counts: Counts
        var lineWidth: Double
        var heightMeters: Double?
        var center: Coordinate?
    }

    /// One settle's signpost event and log line; on a write, also the
    /// `WalkedApply` interval from the state write to the end of the run
    /// loop pass that applies it (an upper bound on SwiftUI's diff plus
    /// MapKit's `addOverlays:`/`removeOverlays:`; Time Profiler stays the
    /// measure of record, eng D2).
    @MainActor
    static func record(_ settle: Settle) {
        sequence += 1
        let counts = settle.counts
        let line = "seq=\(sequence) reason=\(settle.reason) changed=\(settle.changed ? 1 : 0) "
            + "pieces=\(counts.pieces) dotRuns=\(counts.dotRuns) vertices=\(counts.vertices) "
            + "polylines=\(counts.polylines) overCap=\(counts.overCap ? 1 : 0) widthPt=\(Int(settle.lineWidth)) "
            + "heightM=\(Int(settle.heightMeters ?? -1)) "
            + "lat=\(String(format: "%.4f", settle.center?.latitude ?? 0)) "
            + "lon=\(String(format: "%.4f", settle.center?.longitude ?? 0))"
        signposter.emitEvent("WalkedSettle", "\(line, privacy: .public)")
        guard settle.changed else {
            logger.notice("WALKED_SETTLE \(line, privacy: .public) applyMs=-")
            return
        }
        let state = signposter.beginInterval("WalkedApply", "\(line, privacy: .public)")
        afterThisRunLoopPass(start: CACurrentMediaTime()) { milliseconds in
            signposter.endInterval("WalkedApply", state, "applyMs=\(milliseconds, format: .fixed(precision: 1))")
            logger.notice(
                "WALKED_SETTLE \(line, privacy: .public) applyMs=\(milliseconds, format: .fixed(precision: 1))"
            )
        }
    }

    /// The summary build's log line (off the main actor).
    static func build(blocks: Int, tiles: Int, rebuiltTiles: Int, pieces: WalkedPieceIndex, elapsed: Duration) {
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000
        let line = "blocks=\(blocks) tiles=\(tiles) rebuiltTiles=\(rebuiltTiles) "
            + "pieces=\(pieces.pieces.count) vertices=\(pieces.vertexCount) ms=\(String(format: "%.1f", milliseconds))"
        logger.notice("WALKED_BUILD \(line, privacy: .public)")
    }

    /// Calls `done` with the milliseconds since `start`, from a main run
    /// loop observer that runs last before the loop sleeps, after Core
    /// Animation's commit (which carries SwiftUI's graph update and the
    /// Map's overlay changes). One-shot.
    private nonisolated static func afterThisRunLoopPass(
        start: CFTimeInterval,
        _ done: @escaping @Sendable (Double) -> Void
    ) {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
        ) { _, _ in
            done((CACurrentMediaTime() - start) * 1_000)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// DEBUG only, for the simulator look checks and the close-zoom UI
    /// test: `-WalkedProbeCamera "<lat>,<lon>,<distance m>"` starts the map
    /// on a level camera there. Release builds ignore it.
    static var launchCamera: MapCameraPosition? {
        #if DEBUG
        guard let value = UserDefaults.standard.string(forKey: "WalkedProbeCamera") else { return nil }
        let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else { return nil }
        return .camera(MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]), distance: parts[2]
        ))
        #else
        return nil
        #endif
    }
}
