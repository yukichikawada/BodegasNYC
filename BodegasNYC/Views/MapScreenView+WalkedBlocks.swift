import MapKit
import SwiftUI
import UIKit

// Walked blocks on the map (#108, #154): runs of walked blocks in the
// `walked` cyan, above the roads but under the labels, pins and the location
// dot (#108 D4), styled by width, itself by visible height (D2): at the 8 and
// 5pt bands breadcrumbs (round dots over a 35% track), at 3 and 2pt a solid
// line, so the trail cools as you leave your block (#154 D1, DS9). What is
// drawn changes only at camera rest and swaps in place (D10: MapKit does not
// animate `MapPolyline` changes, so there is no fade, #113), and past the
// cap (500 runs for breadcrumbs, 1,000 for a line, #154 D8) nothing is drawn
// and the bottom card says to zoom in (D3).
extension MapScreenView {
    @MapContentBuilder
    var walkedBlockOverlay: some MapContent {
        if case .runs(let runs) = walkedDisplay.visible {
            walkedLines(runs, dots: runs)
        } else if case .pieces(let pieces, let dotRuns) = walkedDisplay.visible {
            // #119 Phase 0 probe: pieces in place of runs, the same stroke.
            if let dotRuns {
                walkedLines(pieces, dots: dotRuns)
            } else {
                walkedLines(pieces, dots: pieces)
            }
        }
    }

    /// The walked layer for `lines` (runs or #119 pieces); at the breadcrumb
    /// bands the dots are drawn on `dots`, which is `lines` except in the
    /// probe's `piecesDotsOnRuns` mode.
    @MapContentBuilder
    func walkedLines<Line: WalkedDrawable, Dot: WalkedDrawable>(_ lines: [Line], dots: [Dot]) -> some MapContent {
        switch WalkedOverlay.trailStyle(width: walkedDisplay.lineWidth) {
        case .line(let width):
            ForEach(lines) { run in
                // The run's cached `MKPolyline`: a reference in the content
                // list, not a coordinate array copied on every graph update.
                MapPolyline(run.polyline)
                    .stroke(Color.walked, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveRoads)
            }
        case .breadcrumbs(let dot, let spacing, let track):
            // Two passes (#154 eng D3): every run's track first, then every
            // run's dots, so no track covers another run's dots where runs
            // cross. Increase Contrast draws no track (DS7); `walked`
            // resolves to its contrast slot there.
            if colorSchemeContrast != .increased {
                ForEach(lines) { run in
                    MapPolyline(run.polyline)
                        .stroke(
                            Color.walked.opacity(0.35),
                            style: StrokeStyle(lineWidth: track, lineCap: .round, lineJoin: .round)
                        )
                        .mapOverlayLevel(level: .aboveRoads)
                }
            }
            ForEach(dots) { run in
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

    /// The "Zoom in to see your blocks." card: only while the layer would
    /// show (history, Show on Map on) and the cap hid it.
    var showsZoomInForBlocks: Bool {
        (streetsWalkedViewModel?.showsWalkedOverlay ?? false) && walkedDisplay.visible == .overCap
    }

    /// Data changes wait for the camera to rest; the settle itself refreshes
    /// (`cameraDidSettle`). The scene coming forward runs a catch-up pass
    /// (eng A2).
    func walkedBlockTriggers(_ content: some View, proxy: MapProxy) -> some View {
        // The intro's sheet sits beside Your Blocks' sheet, whose flag is in
        // the intro's gate, so the two never compete for one presentation
        // (#126 eng).
        streetsWalkedIntro(
            content
                .onChange(of: streetsWalkedViewModel?.walkedRunsVersion) { refreshWalkedOverlay(proxy, reason: "data") }
                .onChange(of: streetsWalkedViewModel?.showsWalkedOverlay) {
                    refreshWalkedOverlay(proxy, reason: "toggle")
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    streetsWalkedViewModel?.sceneActivityChanged(isActive: phase == .active, scene: streetsSceneToken)
                }
                .sheet(isPresented: $showingYourBlocks) {
                    if let streetsWalkedViewModel {
                        YourBlocksSheet(viewModel: streetsWalkedViewModel)
                    }
                }
        )
    }

    /// Recomputes what the walked layer draws for the settled region; a
    /// no-op while the camera moves (`WalkedOverlayDisplay.refresh`), so the
    /// Map's content is untouched mid-gesture, and no state write at all
    /// when nothing it draws changed. Culling reads the spatial index, so a
    /// settle costs what is in view, not the whole history. The write is
    /// plain, never in an animated transaction: MapKit applies `MapPolyline`
    /// changes within a frame either way (design D10, #113).
    func refreshWalkedOverlay(_ proxy: MapProxy, reason: String = "settle") {
        guard let streetsWalkedViewModel else { return }
        // The bands read the level-equivalent height (#156 spec D3); the
        // culling keeps MapKit's region, so a pitched view draws every run up
        // to the far field and the run cap stays the valve (eng D3).
        let measured = measuredHeightMeters(proxy)
        let height = settledFrame(measuredHeight: measured).map(\.heightMeters) ?? measured
        var next = walkedDisplay
        // #119 Phase 0 probe: pieces (or the mode's mix), uncapped.
        let changed = next.refresh(
            index: streetsWalkedViewModel.walkedRunIndex,
            showsOverlay: streetsWalkedViewModel.showsWalkedOverlay,
            region: lastVisibleRegion.map(WalkedRegion.init),
            visibleHeightMeters: height,
            isCameraMoving: isCameraMoving,
            pieceIndex: streetsWalkedViewModel.walkedPieceIndex,
            probeMode: WalkedProbe.mode
        )
        if !isCameraMoving {
            WalkedProbe.record(
                reason: reason,
                changed: changed,
                counts: WalkedProbe.counts(next, drawsTrack: colorSchemeContrast != .increased),
                lineWidth: next.lineWidth,
                heightMeters: height,
                center: lastVisibleRegion.map { ($0.center.latitude, $0.center.longitude) }
            )
        }
        guard changed else { return }
        walkedDisplay = next
    }

    // MARK: Menu actions (design D5, D6, D11)

    /// The Streets Walked toolbar menu (design D5): Your Blocks with How
    /// Streets Walked Works under it (#126), Show on Map, Start/Stop
    /// Recording, Clear History…, each in its own section. VoiceOver returns
    /// here after the intro closes (#126 design D8).
    @ToolbarContentBuilder
    var streetsWalkedToolbarItem: some ToolbarContent {
        if let streetsWalkedViewModel {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button(AppCopy.YourBlocks.title.copy.text) { showingYourBlocks = true }
                            .accessibilityHint(AppCopy.YourBlocks.menuHint.copy.text)
                        Button(AppCopy.StreetsWalkedIntro.menuItem.copy.text) { presentStreetsWalkedIntro() }
                    }
                    Section {
                        Toggle(
                            AppCopy.showOnMapToggle.copy.text,
                            isOn: Binding(
                                get: { streetsWalkedViewModel.isOverlayVisible },
                                set: { streetsWalkedViewModel.isOverlayVisible = $0 }
                            )
                        )
                        .disabled(!streetsWalkedViewModel.hasHistory)
                    }
                    recordingSection(streetsWalkedViewModel)
                    Section {
                        Button(AppCopy.clearHistoryMenuItem.menuItemWithEllipsis, role: .destructive) {
                            showingClearConfirmation = true
                        }
                    }
                } label: {
                    Label(AppCopy.streetsWalkedMenuLabel.copy.text, systemImage: "figure.walk")
                }
                .accessibilityFocused($isStreetsWalkedMenuFocused)
            }
        }
    }

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

/// What the walked layer strokes: a run or a #119 piece, by its cached
/// `MKPolyline`.
nonisolated protocol WalkedDrawable: Identifiable {
    var polyline: MKPolyline { get }
}

extension WalkedRun: WalkedDrawable {}
extension WalkedPiece: WalkedDrawable {}

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
