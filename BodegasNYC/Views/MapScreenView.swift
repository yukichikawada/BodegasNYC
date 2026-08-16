import MapKit
import SwiftUI
import UIKit

/// The map screen's `Map` content: bodega pins/clusters (`BodegaMapViewModel`)
/// and the opt-in streets-walked heatmap overlay (`StreetsWalkedViewModel`).
/// Owned inside `BrowseView`'s single `NavigationStack` — see that file for
/// the map/list toggle chrome and navigation wiring. Reports bodega
/// selection via `onSelectBodega` rather than navigating directly, keeping
/// this view decoupled from `NavigationPath`/the container's routing.
///
/// `viewModel`/`cameraPosition` are received already-built rather than
/// constructed here, unlike a plain single-screen view — `BrowseView` keeps
/// both alive across Map↔List tab switches (SwiftUI tears down and rebuilds
/// `@State` owned by a view that gets swapped out of the rendered tree),
/// so this view must not own them itself.
struct MapScreenView: View {
    static let newYorkCityDefault = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )
    private static let minimumZoomSpan = 0.002

    private let viewModel: BodegaMapViewModel
    @Binding private var cameraPosition: MapCameraPosition
    @State private var selectedBodegaID: Bodega.ID?
    @State private var lastVisibleRegion: MKCoordinateRegion?
    @State private var showingClearConfirmation = false
    private let locationPermissionClient: LocationPermissionClient
    private let streetsWalkedViewModel: StreetsWalkedViewModel?
    @Binding private var isPlacingBodega: Bool
    private let onConfirmPlacement: (CLLocationCoordinate2D) -> Void
    private let onSelectBodega: (Bodega) -> Void

    init(
        viewModel: BodegaMapViewModel,
        cameraPosition: Binding<MapCameraPosition>,
        locationPermissionClient: LocationPermissionClient,
        streetsWalkedViewModel: StreetsWalkedViewModel? = nil,
        isPlacingBodega: Binding<Bool>,
        onConfirmPlacement: @escaping (CLLocationCoordinate2D) -> Void,
        onSelectBodega: @escaping (Bodega) -> Void
    ) {
        self.viewModel = viewModel
        _cameraPosition = cameraPosition
        self.locationPermissionClient = locationPermissionClient
        self.streetsWalkedViewModel = streetsWalkedViewModel
        _isPlacingBodega = isPlacingBodega
        self.onConfirmPlacement = onConfirmPlacement
        self.onSelectBodega = onSelectBodega
    }

    var body: some View {
        Map(position: $cameraPosition, selection: $selectedBodegaID) {
            ForEach(viewModel.displayItems) { item in
                switch item {
                case .pin(let bodega):
                    Marker(
                        bodega.name,
                        systemImage: bodega.hasCat ? "cat" : "figure.wave",
                        coordinate: bodega.coordinate.clLocationCoordinate
                    )
                    .tag(bodega.id)
                    .tint(bodega.hasCat ? .orange : .red)
                case .cluster(let cluster):
                    Annotation(
                        "\(cluster.bodegaIDs.count) bodegas",
                        coordinate: cluster.coordinate.clLocationCoordinate
                    ) {
                        ClusterBadge(count: cluster.bodegaIDs.count)
                            .onTapGesture { zoom(into: cluster) }
                    }
                }
            }
            if let streetsWalkedViewModel, streetsWalkedViewModel.isTrackingEnabled {
                ForEach(Array(streetsWalkedViewModel.polylines.enumerated()), id: \.offset) { _, path in
                    MapPolyline(coordinates: path.map(\.clLocationCoordinate))
                        .stroke(.orange.opacity(0.55), lineWidth: 4)
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            lastVisibleRegion = context.region
            viewModel.regionDidSettle(context.region)
        }
        .onChange(of: selectedBodegaID) { _, newValue in
            guard !isPlacingBodega else { return }
            guard let newValue, let bodega = bodega(withID: newValue) else { return }
            onSelectBodega(bodega)
            // Clears MapKit's selected-marker highlight after navigating
            // away, so returning to this screen doesn't show a stale
            // selection.
            selectedBodegaID = nil
        }
        .overlay(alignment: .top) {
            if let error = streetsWalkedViewModel?.lastTrackingError {
                TrackingErrorBanner(message: error) {
                    streetsWalkedViewModel?.dismissTrackingError()
                }
            }
        }
        .overlay {
            if isPlacingBodega {
                // `figure.wave` has no directional "point" the way `mappin`
                // does, so it's centered directly on the screen-center
                // coordinate `lastVisibleRegion.center` resolves to — no
                // offset needed.
                Image(systemName: "figure.wave")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isPlacingBodega {
                PlacementBottomBar(
                    onUseThisLocation: {
                        onConfirmPlacement(lastVisibleRegion?.center ?? Self.newYorkCityDefault.center)
                        isPlacingBodega = false
                    },
                    onCancel: { isPlacingBodega = false }
                )
            }
        }
        .task {
            viewModel.loadInitialIfNeeded(region: Self.newYorkCityDefault)
            streetsWalkedViewModel?.loadPolylinesIfNeeded()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await locateMe() }
                } label: {
                    Label("Locate Me", systemImage: "location")
                }
            }
            if let streetsWalkedViewModel {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(streetsWalkedViewModel.isTrackingEnabled ? "Turn Off" : "Turn On") {
                            Task { await toggleStreetsWalked() }
                        }
                        Button("Clear History…", role: .destructive) {
                            showingClearConfirmation = true
                        }
                    } label: {
                        Label("Streets Walked", systemImage: "figure.walk")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete all walked-street history? This can't be undone.",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                Task { await clearStreetsWalkedHistory() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Only `.pin` items carry a full `Bodega` — `.cluster` items hold only
    /// `bodegaIDs`, with no back-reference, so a selected ID that resolves
    /// to a cluster (which shouldn't happen, since clusters are never
    /// tagged/added to `selection`) simply finds nothing here.
    private func bodega(withID id: Bodega.ID) -> Bodega? {
        for item in viewModel.displayItems {
            if case .pin(let bodega) = item, bodega.id == id {
                return bodega
            }
        }
        return nil
    }

    /// Standard map UX for a cluster tap: zoom in rather than navigate,
    /// since a cluster has no single `Bodega` to show detail for. Halves
    /// the current span each tap, clamped to a minimum so repeated taps on
    /// a cluster that never fully separates don't zoom to nothing.
    private func zoom(into cluster: MapDisplayItem.Cluster) {
        let baseSpan = lastVisibleRegion?.span ?? Self.newYorkCityDefault.span
        let span = MKCoordinateSpan(
            latitudeDelta: max(baseSpan.latitudeDelta / 2, Self.minimumZoomSpan),
            longitudeDelta: max(baseSpan.longitudeDelta / 2, Self.minimumZoomSpan)
        )
        cameraPosition = .region(MKCoordinateRegion(center: cluster.coordinate.clLocationCoordinate, span: span))
    }

    /// The sole trigger for the core When-In-Use location prompt (PRD
    /// §4.2: requested on first map interaction, not at launch) — never
    /// fired by incidental panning/zooming or at app launch.
    private func locateMe() async {
        let status = await locationPermissionClient.requestWhenInUseAuthorization()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        viewModel.browseModeDidChange(.nearby, currentRegion: nil)
        cameraPosition = .userLocation(followsHeading: false, fallback: .region(Self.newYorkCityDefault))
    }

    /// The sole trigger for the separate Always location prompt (PRD §5.2:
    /// never bundled with the core When-In-Use ask above). Requesting
    /// Always from `.notDetermined` typically only yields
    /// `.authorizedWhenInUse` from the system's first prompt — full
    /// "Always" needs either a later just-in-time prompt or Settings, so
    /// that case gets a nudge there rather than silently doing nothing.
    private func toggleStreetsWalked() async {
        guard let streetsWalkedViewModel else { return }
        guard !streetsWalkedViewModel.isTrackingEnabled else {
            streetsWalkedViewModel.disableTracking()
            return
        }
        switch await streetsWalkedViewModel.requestTrackingPermission() {
        case .authorizedAlways:
            try? await streetsWalkedViewModel.enableTracking()
        case .authorizedWhenInUse:
            openSettings()
        default:
            break
        }
    }

    private func clearStreetsWalkedHistory() async {
        try? await streetsWalkedViewModel?.clearHistory()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Non-modal: `didUpdateLocations`'s save-failure path can re-set
/// `lastTrackingError` on every subsequent location update if the
/// underlying condition doesn't resolve, so a `.alert` would re-interrupt
/// the user repeatedly. This communicates "tracking is currently degraded"
/// as ongoing state instead, dismissible without blocking map interaction.
private struct TrackingErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.footnote)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

/// The confirm/cancel bar shown while `isPlacingBodega` — pans underneath a
/// fixed center-screen pin (see `MapScreenView`'s `.overlay`); "Use This
/// Location" reads whatever coordinate is currently under that pin.
private struct PlacementBottomBar: View {
    let onUseThisLocation: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack {
            Button("Cancel", action: onCancel)
            Spacer()
            Button("Use This Location", action: onUseThisLocation)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial)
    }
}

private struct ClusterBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.bold())
            .padding(8)
            .background(.blue, in: Circle())
            .foregroundStyle(.white)
    }
}
