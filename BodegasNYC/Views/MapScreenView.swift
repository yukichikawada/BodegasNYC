import MapKit
import SwiftUI
import UIKit

/// The map screen: bodega pins/clusters (`BodegaMapViewModel`) and the
/// opt-in streets-walked heatmap overlay (`StreetsWalkedViewModel`)
/// rendered on a declarative `Map`. Does not know about list/detail screens
/// (a future parent container owns the map/list toggle chrome) — see
/// `docs/PRD.md` §7 and the map-architecture plan for why that's decoupled
/// rather than folded in here.
struct MapScreenView: View {
    private static let newYorkCityDefault = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )

    @State private var viewModel: BodegaMapViewModel
    @State private var cameraPosition: MapCameraPosition
    @State private var showingClearConfirmation = false
    private let locationPermissionClient: LocationPermissionClient
    private let streetsWalkedViewModel: StreetsWalkedViewModel?

    init(
        bodegaService: BodegaService,
        locationPermissionClient: LocationPermissionClient,
        streetsWalkedViewModel: StreetsWalkedViewModel? = nil
    ) {
        _viewModel = State(initialValue: BodegaMapViewModel(bodegaService: bodegaService))
        _cameraPosition = State(initialValue: .region(Self.newYorkCityDefault))
        self.locationPermissionClient = locationPermissionClient
        self.streetsWalkedViewModel = streetsWalkedViewModel
    }

    var body: some View {
        // `.toolbar` needs a navigation bar to attach to, and there's no
        // parent container yet (the future map/list/detail container will
        // likely own this instead — see the type-level doc comment).
        NavigationStack {
            Map(position: $cameraPosition) {
                ForEach(viewModel.displayItems) { item in
                    switch item {
                    case .pin(let bodega):
                        Marker(bodega.name, coordinate: bodega.coordinate.clLocationCoordinate)
                    case .cluster(let cluster):
                        Annotation(
                            "\(cluster.bodegaIDs.count) bodegas",
                            coordinate: cluster.coordinate.clLocationCoordinate
                        ) {
                            ClusterBadge(count: cluster.bodegaIDs.count)
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
                viewModel.regionDidSettle(context.region)
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
