import MapKit
import SwiftUI
import UIKit

// Walked blocks on the map (#108): runs of walked blocks in the `walked`
// indigo (design D1), above the roads but under the labels, pins and the
// location dot (D4), width by visible height (D2). What is drawn changes only
// at camera rest, with a 0.2s fade or none under Reduce Motion (D10), and past
// 2,000 visible runs nothing is drawn and the bottom card says to zoom in (D3).
extension MapScreenView {
    @MapContentBuilder
    var walkedBlockOverlay: some MapContent {
        if case .runs(let runs) = walkedVisible {
            ForEach(runs) { run in
                MapPolyline(coordinates: run.coordinates.map(\.clLocationCoordinate))
                    .stroke(
                        Color.walked,
                        style: StrokeStyle(lineWidth: walkedLineWidth, lineCap: .round, lineJoin: .round)
                    )
                    .mapOverlayLevel(level: .aboveRoads)
            }
        }
    }

    /// The "Zoom in to see your blocks." card: only while the layer would
    /// show (history, Show on Map on) and the cap hid it.
    var showsZoomInForBlocks: Bool {
        (streetsWalkedViewModel?.showsWalkedOverlay ?? false) && walkedVisible == .overCap
    }

    /// Data changes wait for the camera to rest; the settle itself refreshes
    /// (`cameraDidSettle`). The scene coming forward runs a catch-up pass
    /// (eng A2).
    func walkedBlockTriggers(_ content: some View, proxy: MapProxy) -> some View {
        content
            .onChange(of: streetsWalkedViewModel?.walkedRunsVersion) {
                guard !isCameraMoving else { return }
                refreshWalkedOverlay(proxy)
            }
            .onChange(of: streetsWalkedViewModel?.showsWalkedOverlay) {
                guard !isCameraMoving else { return }
                refreshWalkedOverlay(proxy)
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                streetsWalkedViewModel?.sceneActivityChanged(isActive: phase == .active)
            }
    }

    /// Recomputes what the walked layer draws for the settled region.
    func refreshWalkedOverlay(_ proxy: MapProxy) {
        guard let streetsWalkedViewModel else { return }
        if mapSize.height > 0,
           let bottom = proxy.convert(CGPoint(x: mapSize.width / 2, y: mapSize.height), from: .local),
           let height = visibleHeightMeters(proxy, bottom: bottom) {
            walkedLineWidth = WalkedOverlay.lineWidth(visibleHeightMeters: height, current: walkedLineWidth)
        }
        var next = WalkedOverlay.Visible.runs([])
        if streetsWalkedViewModel.showsWalkedOverlay, let region = lastVisibleRegion {
            next = WalkedOverlay.visible(streetsWalkedViewModel.walkedRuns, in: WalkedRegion(region))
        }
        guard next != walkedVisible else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            walkedVisible = next
        }
    }

    // MARK: Menu actions (design D5, D6, D11)

    /// Start or Stop Recording. The sole trigger for the separate Always
    /// location prompt (PRD §5.2: never bundled with the core When-In-Use
    /// ask). Requesting Always from `.notDetermined` typically only yields
    /// `.authorizedWhenInUse` from the system's first prompt — full
    /// "Always" needs either a later just-in-time prompt or Settings, so
    /// that case gets a nudge there rather than silently doing nothing.
    func toggleStreetsWalked() async {
        guard let streetsWalkedViewModel else { return }
        guard !streetsWalkedViewModel.isTrackingEnabled else {
            streetsWalkedViewModel.disableTracking()
            return
        }
        switch await streetsWalkedViewModel.requestTrackingPermission() {
        case .authorizedAlways:
            do {
                try await streetsWalkedViewModel.enableTracking()
            } catch {
                return
            }
            // Once, after Start Recording succeeds and the location
            // dialogs have closed (design D6).
            await streetsWalkedViewModel.requestMotionAccessIfNeeded()
        case .authorizedWhenInUse:
            openSettings()
        default:
            break
        }
    }

    /// Clear History at the confirm tap (eng R9), then says so (design D11):
    /// the overlay goes without a sound otherwise.
    func clearStreetsWalkedHistory(at tapTime: Date) async {
        guard let streetsWalkedViewModel else { return }
        do {
            try await streetsWalkedViewModel.clearHistory(at: tapTime)
            AccessibilityNotification.Announcement(AppCopy.historyClearedAnnouncement.copy.text).post()
        } catch {
            return
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

extension WalkedRegion {
    init(_ region: MKCoordinateRegion) {
        self.init(
            centerLatitude: region.center.latitude,
            centerLongitude: region.center.longitude,
            latitudeDelta: region.span.latitudeDelta,
            longitudeDelta: region.span.longitudeDelta
        )
    }
}
