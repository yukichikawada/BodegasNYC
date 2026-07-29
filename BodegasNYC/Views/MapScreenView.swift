import MapKit
import SwiftUI

/// The map screen: bodega pins/clusters (`BodegaMapViewModel`) rendered on
/// a declarative `Map`. Does not know about list/detail screens (a future
/// parent container owns the map/list toggle chrome) or the streets-walked
/// heatmap's live UI yet (`// TODO(streets-walked)` below marks its two
/// hook points) — see `docs/PRD.md` §7 and the map-architecture plan for why
/// those are decoupled rather than folded in here.
struct MapScreenView: View {
    private static let newYorkCityDefault = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )

    @State private var viewModel: BodegaMapViewModel
    @State private var cameraPosition: MapCameraPosition
    private let locationPermissionClient: LocationPermissionClient

    init(bodegaService: BodegaService, locationPermissionClient: LocationPermissionClient) {
        _viewModel = State(initialValue: BodegaMapViewModel(bodegaService: bodegaService))
        _cameraPosition = State(initialValue: .region(Self.newYorkCityDefault))
        self.locationPermissionClient = locationPermissionClient
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
                // TODO(streets-walked): add the heatmap's MapPolyline overlay here.
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                viewModel.regionDidSettle(context.region)
            }
            .task {
                viewModel.loadInitialIfNeeded(region: Self.newYorkCityDefault)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await locateMe() }
                    } label: {
                        Label("Locate Me", systemImage: "location")
                    }
                }
                // TODO(streets-walked): add the heatmap on/off toggle here.
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
