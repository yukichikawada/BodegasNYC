import CoreFoundation
import Foundation
import MapKit
import os
import QuartzCore

/// #119 Phase 0 device probe (probe branch only, not for merge): which
/// geometry the walked layer draws, and the per-settle signposts and log
/// lines the device A/B reads (eng D2-D4).
///
/// Mode, by launch argument `-WalkedProbeMode <mode>` (the argument domain):
/// - `pieces` (default): one polyline per walked patch per ~1 km tile, under
///   both the breadcrumb track and the dots. Uncapped.
/// - `piecesDotsOnRuns`: pieces for the line bands and the breadcrumb track,
///   but the breadcrumb dots stay on runs (a retraced piece doubles the dot
///   rhythm, see the probe report). Uncapped.
/// - `runs`: today's runs, uncapped, for an in-build comparison.
///
/// Signposts go to Points of Interest under `subsystem`; log lines are
/// `notice` level with the `WALKED_` prefix, category `walked`.
nonisolated enum WalkedProbe {
    nonisolated enum Mode: String, Sendable {
        case pieces
        case piecesDotsOnRuns
        case runs
    }

    static let modeKey = "WalkedProbeMode"
    static let mode: Mode = UserDefaults.standard.string(forKey: modeKey).flatMap(Mode.init) ?? .pieces

    /// Not the bundle identifier: test builds install under another one.
    static let subsystem = "BodegasNYC.walkedProbe"
    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    static let logger = Logger(subsystem: subsystem, category: "walked")

    /// What a display draws, counted for the log.
    nonisolated struct Counts: Sendable, Equatable {
        var pieces = 0
        var runs = 0
        /// Drawn vertices: the pieces' (or runs') simplified coordinates,
        /// plus the dot runs' in `piecesDotsOnRuns` at the breadcrumb bands.
        var vertices = 0
        /// `MapPolyline`s in the Map's content: one per line at 3 and 2pt;
        /// track plus dots per line at 8 and 5pt (dots only under Increase
        /// Contrast).
        var polylines = 0
        var overCap = false
    }

    static func counts(_ display: WalkedOverlayDisplay, drawsTrack: Bool) -> Counts {
        var counts = Counts()
        let isBreadcrumbs: Bool
        switch WalkedOverlay.trailStyle(width: display.lineWidth) {
        case .breadcrumbs: isBreadcrumbs = true
        case .line: isBreadcrumbs = false
        }
        switch display.visible {
        case .overCap:
            counts.overCap = true
        case .runs(let runs):
            counts.runs = runs.count
            counts.vertices = runs.reduce(0) { $0 + $1.polyline.pointCount }
            counts.polylines = isBreadcrumbs ? runs.count * (drawsTrack ? 2 : 1) : runs.count
        case .pieces(let pieces, let dotRuns):
            counts.pieces = pieces.count
            counts.vertices = pieces.reduce(0) { $0 + $1.vertexCount }
            if isBreadcrumbs {
                let dots = dotRuns?.count ?? pieces.count
                counts.runs = dotRuns?.count ?? 0
                counts.vertices += dotRuns?.reduce(0) { $0 + $1.polyline.pointCount } ?? 0
                counts.polylines = (drawsTrack ? pieces.count : 0) + dots
            } else {
                counts.polylines = pieces.count
            }
        }
        return counts
    }

    /// Settles seen since launch (the A/B divides by the driver's own count).
    @MainActor static var sequence = 0

    /// One settle's signpost event and log line; on a write, also the
    /// `WalkedApply` interval from the state write to the end of the run
    /// loop pass that applies it (an upper bound on SwiftUI's diff plus
    /// MapKit's `addOverlays:`/`removeOverlays:`; Time Profiler stays the
    /// measure of record, eng D2).
    @MainActor
    static func record(
        reason: String,
        changed: Bool,
        counts: Counts,
        lineWidth: Double,
        heightMeters: Double?,
        center: (latitude: Double, longitude: Double)?
    ) {
        sequence += 1
        let seq = sequence
        let height = heightMeters ?? -1
        let line = "seq=\(seq) reason=\(reason) changed=\(changed ? 1 : 0) mode=\(mode.rawValue) "
            + "pieces=\(counts.pieces) runs=\(counts.runs) vertices=\(counts.vertices) "
            + "polylines=\(counts.polylines) overCap=\(counts.overCap ? 1 : 0) widthPt=\(Int(lineWidth)) "
            + "heightM=\(Int(height)) lat=\(String(format: "%.4f", center?.latitude ?? 0)) "
            + "lon=\(String(format: "%.4f", center?.longitude ?? 0))"
        signposter.emitEvent("WalkedSettle", "\(line, privacy: .public)")
        guard changed else {
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
}
