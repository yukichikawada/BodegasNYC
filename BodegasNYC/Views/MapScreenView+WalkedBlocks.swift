import MapKit
import SwiftUI
import UIKit

// Walked blocks on the map (#108): runs of walked blocks in the `walked`
// indigo (design D1), above the roads but under the labels, pins and the
// location dot (D4), width by visible height (D2). What is drawn changes only
// at camera rest and swaps in place (D10: MapKit does not animate
// `MapPolyline` changes, so there is no fade, #113), and past 1,000 visible
// runs nothing is drawn and the bottom card says to zoom in (D3).
extension MapScreenView {
    @MapContentBuilder
    var walkedBlockOverlay: some MapContent {
        if case .runs(let runs) = walkedDisplay.visible {
            ForEach(runs) { run in
                // The run's cached `MKPolyline`: a reference in the content
                // list, not a coordinate array copied on every graph update.
                MapPolyline(run.polyline)
                    .stroke(
                        Color.walked,
                        style: StrokeStyle(lineWidth: walkedDisplay.lineWidth, lineCap: .round, lineJoin: .round)
                    )
                    .mapOverlayLevel(level: .aboveRoads)
            }
        }
    }

    /// The "Zoom in to see your blocks." card: only while the layer would
    /// show (history, Show on Map on) and the cap hid it.
    var showsZoomInForBlocks: Bool {
        (streetsWalkedViewModel?.showsWalkedOverlay ?? false) && walkedDisplay.visible == .overCap
    }

    /// Data changes wait for the camera to rest; the settle itself refreshes
    /// (`cameraDidSettle`). The scene coming forward runs a catch-up pass
    /// (eng A2).
    func walkedBlockTriggers(_ content: some View, proxy: MapProxy) -> some View {
        content
            .onChange(of: streetsWalkedViewModel?.walkedRunsVersion) { refreshWalkedOverlay(proxy) }
            .onChange(of: streetsWalkedViewModel?.showsWalkedOverlay) { refreshWalkedOverlay(proxy) }
            .onChange(of: scenePhase, initial: true) { _, phase in
                streetsWalkedViewModel?.sceneActivityChanged(isActive: phase == .active, scene: streetsSceneToken)
            }
            .sheet(isPresented: $showingYourBlocks) {
                if let streetsWalkedViewModel {
                    YourBlocksSheet(viewModel: streetsWalkedViewModel)
                }
            }
    }

    /// Recomputes what the walked layer draws for the settled region; a
    /// no-op while the camera moves (`WalkedOverlayDisplay.refresh`), so the
    /// Map's content is untouched mid-gesture, and no state write at all
    /// when nothing it draws changed. Culling reads the spatial index, so a
    /// settle costs what is in view, not the whole history. The write is
    /// plain, never in an animated transaction: MapKit applies `MapPolyline`
    /// changes within a frame either way (design D10, #113).
    func refreshWalkedOverlay(_ proxy: MapProxy) {
        guard let streetsWalkedViewModel else { return }
        var height: Double?
        if mapSize.height > 0,
           let bottom = proxy.convert(CGPoint(x: mapSize.width / 2, y: mapSize.height), from: .local) {
            height = visibleHeightMeters(proxy, bottom: bottom)
        }
        var next = walkedDisplay
        let changed = next.refresh(
            index: streetsWalkedViewModel.walkedRunIndex,
            showsOverlay: streetsWalkedViewModel.showsWalkedOverlay,
            region: lastVisibleRegion.map(WalkedRegion.init),
            visibleHeightMeters: height,
            isCameraMoving: isCameraMoving
        )
        guard changed else { return }
        walkedDisplay = next
    }

    // MARK: Menu actions (design D5, D6, D11)

    /// The menu's recording section by state (#123 design DS3): Start
    /// Recording when off, Stop Recording when recording, and while paused
    /// a "Recording Paused" section with Open Settings (when Settings can
    /// fix it) above Stop Recording, which clears the intent.
    @ViewBuilder
    func recordingSection(_ viewModel: StreetsWalkedViewModel) -> some View {
        switch viewModel.recordingState {
        case .off:
            Section {
                Button(AppCopy.startRecordingAction.copy.text) {
                    Task { await toggleStreetsWalked() }
                }
            }
        case .recording:
            Section {
                Button(AppCopy.stopRecordingAction.copy.text) { viewModel.disableTracking() }
            }
        case .paused(let problem):
            Section(AppCopy.Recorder.pausedSection.copy.text) {
                if problem.opensSettings {
                    Button(AppCopy.YourBlocks.openSettings.copy.text) { openSettings() }
                }
                Button(AppCopy.stopRecordingAction.copy.text) { viewModel.disableTracking() }
            }
        }
    }

    /// Start Recording. The sole trigger for the separate Always location
    /// prompt (PRD §5.2: never bundled with the core When-In-Use ask). No
    /// jump to Settings (#123 design DS4): any answer but Always saves the
    /// intent, and the recorder card says what Settings needs (While Using:
    /// needsAlways; Never: denied; restricted: no action). Granting Always
    /// later starts recording when the app comes back (eng R1).
    func toggleStreetsWalked() async {
        guard let streetsWalkedViewModel else { return }
        guard streetsWalkedViewModel.recordingState == .off else {
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
        default:
            streetsWalkedViewModel.saveRecordingIntent()
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
