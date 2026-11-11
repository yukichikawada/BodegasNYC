import CoreFoundation
import Foundation
import MapKit
import os
import QuartzCore
import SwiftUI

/// Signposts and log lines for measuring the walked layer on a device
/// (#119 eng D2-D4, the device A/B; not for merge). Read-only: it counts
/// what the display already holds and never changes what is drawn.
/// Release-safe: signposts cost next to nothing when no instrument records
/// them, and the log line is one `notice` per settle.
///
/// Signposts (Points of Interest, subsystem `BodegasNYC.walkedProbe`):
/// event `WalkedSettle` on every settle, interval `WalkedApply` from a
/// write to the end of the run loop pass that applies it. Log lines,
/// category `walked`: `WALKED_SETTLE ...`.
nonisolated enum WalkedTrace {
    /// Not the bundle identifier: test builds install under another one.
    static let subsystem = "BodegasNYC.walkedProbe"
    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    static let logger = Logger(subsystem: subsystem, category: "walked")

    /// What a display draws, counted for the log.
    nonisolated struct Counts: Sendable, Equatable {
        var runs = 0
        var vertices = 0
        /// `MapPolyline`s in the Map's content: one per run at 3 and 2pt;
        /// track plus dots per run at 8 and 5pt (dots only under Increase
        /// Contrast).
        var polylines = 0
        var overCap = false
    }

    static func counts(_ display: WalkedOverlayDisplay, drawsTrack: Bool) -> Counts {
        var counts = Counts()
        guard case .runs(let runs) = display.visible else {
            counts.overCap = true
            return counts
        }
        counts.runs = runs.count
        counts.vertices = runs.reduce(0) { $0 + $1.polyline.pointCount }
        switch WalkedOverlay.trailStyle(width: display.lineWidth) {
        case .breadcrumbs: counts.polylines = runs.count * (drawsTrack ? 2 : 1)
        case .line: counts.polylines = runs.count
        }
        return counts
    }

    /// Settles seen since launch (the A/B divides by the driver's own count).
    @MainActor static var sequence = 0

    /// One settle as recorded: why it ran, whether it wrote, what it draws.
    nonisolated struct Settle: Sendable {
        var reason: String
        /// `cull` (the drawn set is the view plus 25%) or `all` (the whole
        /// history, #119 no-cull probe).
        var mode: String
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
        let line = "seq=\(sequence) reason=\(settle.reason) mode=\(settle.mode) changed=\(settle.changed ? 1 : 0) "
            + "runs=\(counts.runs) vertices=\(counts.vertices) polylines=\(counts.polylines) "
            + "overCap=\(counts.overCap ? 1 : 0) widthPt=\(Int(settle.lineWidth)) "
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

    /// DEBUG only, simulator checks: `-WalkedLaunchCamera "<lat>,<lon>,<m>"`
    /// starts the map on a level camera there. Release builds ignore it.
    static var launchCamera: MapCameraPosition? {
        #if DEBUG
        guard let value = UserDefaults.standard.string(forKey: "WalkedLaunchCamera") else { return nil }
        let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else { return nil }
        return .camera(MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]), distance: parts[2]
        ))
        #else
        return nil
        #endif
    }

    /// DEBUG only, the simulator check without touch injection:
    /// `-WalkedCameraScript YES` moves the camera itself, 60 s after launch,
    /// through level settles 4 s apart: four pans at 6 km of camera
    /// distance (the 3pt line band), a zoom to 3 km (the 5pt breadcrumb
    /// band), two pans, a zoom back out and one pan. Each line is logged.
    @MainActor
    static func runCameraScript(_ move: (MapCameraPosition) -> Void) async {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "WalkedCameraScript") else { return }
        struct Step {
            let name: String
            let north: Double
            let east: Double
            let distance: Double
        }
        let steps = [
            Step(name: "pan-line", north: 0.004, east: 0, distance: 6_000),
            Step(name: "pan-line", north: 0, east: 0.004, distance: 6_000),
            Step(name: "pan-line", north: -0.004, east: 0, distance: 6_000),
            Step(name: "pan-line", north: 0, east: -0.004, distance: 6_000),
            Step(name: "zoom-in", north: 0, east: 0, distance: 3_000),
            Step(name: "pan-crumbs", north: 0.003, east: 0, distance: 3_000),
            Step(name: "pan-crumbs", north: 0, east: 0, distance: 3_000),
            Step(name: "zoom-out", north: 0, east: 0, distance: 6_000),
            Step(name: "pan-line", north: 0.004, east: 0.004, distance: 6_000)
        ]
        try? await Task.sleep(for: .seconds(60))
        for step in steps {
            logger.notice("WALKED_SCRIPT \(step.name, privacy: .public) distance=\(Int(step.distance))")
            move(.camera(MapCamera(
                centerCoordinate: CLLocationCoordinate2D(latitude: 40.7308 + step.north, longitude: -73.9973 + step.east),
                distance: step.distance
            )))
            try? await Task.sleep(for: .seconds(4))
        }
        #endif
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
