import MapKit
import SwiftUI

/// The map/list toggle container: owns the single `NavigationStack` for the
/// whole browse session (previously `MapScreenView` wrapped itself in its
/// own, as a stopgap — see its prior doc comment), the map↔list tab
/// selection, and navigation to `BodegaDetailView`.
///
/// Also owns `mapViewModel`/`listViewModel`/`cameraPosition` — constructing
/// them here, once, and handing them down as `let`/`Binding` rather than
/// letting each child view build its own is what makes switching tabs not
/// re-trigger a fetch or reset the map's pan/zoom: a `switch`/`if` branch
/// that swaps out a child view's concrete type tears down and rebuilds any
/// `@State` that child owns itself, which would otherwise silently discard
/// already-loaded data on every tab switch.
struct BrowseView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case map
        case list

        var id: Self { self }

        var label: String {
            switch self {
            case .map: "Map"
            case .list: "List"
            }
        }
    }

    @State private var activeTab: Tab = .map
    @State private var path: [Bodega] = []
    @State private var cameraPosition: MapCameraPosition = .region(MapScreenView.newYorkCityDefault)
    @State private var mapViewModel: BodegaMapViewModel
    @State private var listViewModel: BodegaListViewModel

    private let reviewService: ReviewService
    private let photoService: PhotoService
    private let locationPermissionClient: LocationPermissionClient
    private let streetsWalkedViewModel: StreetsWalkedViewModel?

    init(
        bodegaService: BodegaService,
        reviewService: ReviewService,
        photoService: PhotoService,
        locationPermissionClient: LocationPermissionClient,
        streetsWalkedViewModel: StreetsWalkedViewModel?
    ) {
        _mapViewModel = State(initialValue: BodegaMapViewModel(bodegaService: bodegaService))
        _listViewModel = State(initialValue: BodegaListViewModel(bodegaService: bodegaService))
        self.reviewService = reviewService
        self.photoService = photoService
        self.locationPermissionClient = locationPermissionClient
        self.streetsWalkedViewModel = streetsWalkedViewModel
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Browse Mode", selection: $activeTab) {
                            ForEach(Tab.allCases) { tab in
                                Text(tab.label).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 200)
                    }
                }
                .navigationDestination(for: Bodega.self) { bodega in
                    BodegaDetailView(bodega: bodega, reviewService: reviewService, photoService: photoService)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch activeTab {
        case .map:
            MapScreenView(
                viewModel: mapViewModel,
                cameraPosition: $cameraPosition,
                locationPermissionClient: locationPermissionClient,
                streetsWalkedViewModel: streetsWalkedViewModel,
                onSelectBodega: { path.append($0) }
            )
        case .list:
            BodegaListView(viewModel: listViewModel)
        }
    }
}
