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
    @State private var showingSignIn = false
    @State private var showingSignOutConfirmation = false
    @State private var signOutErrorMessage: String?
    @State private var isPlacingBodega = false
    /// True from the moment a programmatic recenter (the auto-locate fetch
    /// in `beginPlacementMode`) is triggered until `MapScreenView`'s
    /// `onMapCameraChange(.onEnd)` confirms the camera has actually
    /// settled there. `MapScreenView` disables "Use This Location" while
    /// this is true — otherwise a confirm tapped mid-recenter would read
    /// `lastVisibleRegion`'s *previous* value, silently submitting a
    /// coordinate that doesn't match what's visually under the pin.
    @State private var isAwaitingCameraSettle = false
    @State private var addBodegaViewModel: AddBodegaViewModel?
    @State private var isResolvingCurrentLocation = false

    private let bodegaService: BodegaService
    private let reviewService: ReviewService
    private let photoService: PhotoService
    private let sessionStore: SessionStore
    private let locationPermissionClient: LocationPermissionClient
    private let streetsWalkedViewModel: StreetsWalkedViewModel?

    init(
        bodegaService: BodegaService,
        reviewService: ReviewService,
        photoService: PhotoService,
        sessionStore: SessionStore,
        locationPermissionClient: LocationPermissionClient,
        streetsWalkedViewModel: StreetsWalkedViewModel?
    ) {
        _mapViewModel = State(initialValue: BodegaMapViewModel(bodegaService: bodegaService))
        _listViewModel = State(initialValue: BodegaListViewModel(bodegaService: bodegaService))
        self.bodegaService = bodegaService
        self.reviewService = reviewService
        self.photoService = photoService
        self.sessionStore = sessionStore
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
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if sessionStore.isSignedIn {
                                showingSignOutConfirmation = true
                            } else {
                                showingSignIn = true
                            }
                        } label: {
                            Label(
                                "Account",
                                systemImage: sessionStore.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle"
                            )
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Drop a Pin on Map", systemImage: "mappin.and.ellipse") {
                                activeTab = .map
                                Task { await beginPlacementMode() }
                            }
                            Button("Use Current Location", systemImage: "location.fill") {
                                Task { await useCurrentLocationShortcut() }
                            }
                        } label: {
                            Label("Add Bodega", systemImage: "plus")
                        }
                    }
                }
                .navigationDestination(for: Bodega.self) { bodega in
                    BodegaDetailView(bodega: bodega, reviewService: reviewService, photoService: photoService)
                }
                .sheet(isPresented: $showingSignIn) {
                    SignInView(sessionStore: sessionStore)
                }
                .sheet(item: $addBodegaViewModel) { viewModel in
                    AddBodegaView(viewModel: viewModel, sessionStore: sessionStore) { insertedBodega in
                        mapViewModel.bodegaWasAdded(insertedBodega)
                        listViewModel.bodegaWasAdded(insertedBodega)
                        addBodegaViewModel = nil
                    }
                }
                .overlay {
                    if isResolvingCurrentLocation {
                        ProgressView()
                    }
                }
                .confirmationDialog(
                    "Sign out of your account?",
                    isPresented: $showingSignOutConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Sign Out", role: .destructive) {
                        Task {
                            await sessionStore.signOut()
                            if sessionStore.isSignedIn {
                                signOutErrorMessage = sessionStore.lastAuthError
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .alert(
                    "Couldn't Sign Out",
                    isPresented: Binding(
                        get: { signOutErrorMessage != nil },
                        set: { if !$0 { signOutErrorMessage = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(signOutErrorMessage ?? "")
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
                isPlacingBodega: $isPlacingBodega,
                isAwaitingCameraSettle: $isAwaitingCameraSettle,
                onConfirmPlacement: { presentAddBodegaSheet(coordinate: $0) },
                onSelectBodega: { path.append($0) }
            )
        case .list:
            BodegaListView(viewModel: listViewModel)
        }
    }

    /// Switches to the Map tab and enters placement mode. Best-effort:
    /// attempts a quick current-location fix first (if already authorized)
    /// to center the map somewhere useful before the user starts panning,
    /// but placement mode works fine via manual panning regardless.
    private func beginPlacementMode() async {
        isPlacingBodega = true
        guard LocationPermissionClient.canRequestCurrentLocation(
            authorizationStatus: locationPermissionClient.authorizationStatus
        ) else { return }
        // `isPlacingBodega` re-checked after the await: the user may have
        // already cancelled placement mode (or, more precisely, this fetch
        // is stale) by the time a fix arrives — recentering the map on
        // their way out would be a confusing, unrequested jump.
        if let coordinate = await locationPermissionClient.requestCurrentLocation(), isPlacingBodega {
            isAwaitingCameraSettle = true
            cameraPosition = .region(
                MKCoordinateRegion(center: coordinate, span: MapScreenView.newYorkCityDefault.span)
            )
        }
    }

    /// "Use Current Location" toolbar shortcut: skips placement mode
    /// entirely when a fast GPS fix is available, falling back to manual
    /// placement mode (on the Map tab) if permission is missing or the fix
    /// times out.
    private func useCurrentLocationShortcut() async {
        isResolvingCurrentLocation = true
        defer { isResolvingCurrentLocation = false }
        if let coordinate = await locationPermissionClient.requestCurrentLocation() {
            presentAddBodegaSheet(coordinate: coordinate)
        } else {
            activeTab = .map
            isPlacingBodega = true
        }
    }

    private func presentAddBodegaSheet(coordinate: CLLocationCoordinate2D) {
        isPlacingBodega = false
        addBodegaViewModel = AddBodegaViewModel(
            coordinate: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude),
            bodegaService: bodegaService,
            sessionStore: sessionStore
        )
    }
}
