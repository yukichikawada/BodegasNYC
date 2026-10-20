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

        var systemImage: String {
            switch self {
            case .map: "map"
            case .list: "list.bullet"
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
    @State private var addBodegaViewModel: AddBodegaViewModel?
    @State private var isResolvingCurrentLocation = false
    /// The single source of truth for filter/search across both tabs —
    /// pushed into both view models via `.onChange` below, so switching
    /// Map↔List never loses or desyncs it.
    @State private var filter: BodegaFilter = .none
    @State private var showingFilters = false
    /// On iOS 26 the trailing toolbar buttons grow with Dynamic Type and
    /// squeeze the principal slot: at `.xLarge` the segmented Map/List
    /// control truncates and from `.xxLarge` up the toolbar drops it
    /// entirely, even icon-only (#44). `modePicker` switches to a compact
    /// `Menu` from `.xLarge` up so the List tab stays reachable.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let bodegaService: BodegaService
    private let reviewService: ReviewService
    private let photoService: PhotoService
    private let flagService: FlagService
    private let sessionStore: SessionStore
    private let locationPermissionClient: LocationPermissionClient
    private let streetsWalkedViewModel: StreetsWalkedViewModel?
    /// Passed in by `RootView`, which owns it (and the onboarding overlay)
    /// rather than putting it on `AppEnvironment`; see `RootView`.
    private let firstRunState: FirstRunState
    /// `RootView`'s overlay flag: the Account menu's "Show Intro Again"
    /// sets it, and it going false is this view's cue to land on the map.
    @Binding private var showingOnboarding: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        bodegaService: BodegaService,
        reviewService: ReviewService,
        photoService: PhotoService,
        flagService: FlagService,
        sessionStore: SessionStore,
        locationPermissionClient: LocationPermissionClient,
        streetsWalkedViewModel: StreetsWalkedViewModel?,
        firstRunState: FirstRunState,
        showingOnboarding: Binding<Bool>
    ) {
        self.firstRunState = firstRunState
        _showingOnboarding = showingOnboarding
        _mapViewModel = State(initialValue: BodegaMapViewModel(bodegaService: bodegaService))
        _listViewModel = State(initialValue: BodegaListViewModel(bodegaService: bodegaService))
        self.bodegaService = bodegaService
        self.reviewService = reviewService
        self.photoService = photoService
        self.flagService = flagService
        self.sessionStore = sessionStore
        self.locationPermissionClient = locationPermissionClient
        self.streetsWalkedViewModel = streetsWalkedViewModel
    }

    /// The Map/List switch in the toolbar's principal slot. A text
    /// segmented control at default sizes; from `.xLarge` up it becomes a
    /// single-button `Menu` wrapping the same `Picker` (see the
    /// `dynamicTypeSize` doc comment for why).
    @ViewBuilder
    private var modePicker: some View {
        let picker = Picker("Browse Mode", selection: $activeTab) {
            ForEach(Tab.allCases) { tab in
                Label(tab.label, systemImage: tab.systemImage).tag(tab)
            }
        }
        if dynamicTypeSize >= .xLarge {
            Menu {
                picker
            } label: {
                Label(activeTab.label, systemImage: activeTab.systemImage)
            }
            .accessibilityLabel("Browse Mode")
            .accessibilityValue(activeTab.label)
        } else {
            picker
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .frame(maxWidth: 200)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        modePicker
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        filterButton
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        accountMenu
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Drop a Pin on Map", systemImage: "mappin.and.ellipse") {
                                // Manual placement: pan-under-a-fixed-pin
                                // over whatever the map already shows (see
                                // `MapScreenView`'s `PlacementBottomBar` doc
                                // comment) — no GPS fetch here. That's the
                                // separate "Use Current Location" item below.
                                activeTab = .map
                                isPlacingBodega = true
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
                    // `path` is deliberately left holding the pre-edit
                    // `Bodega` after an edit: the detail screen renders
                    // from its own view model (updated in place), and
                    // swapping the path element for a value that hashes
                    // differently would make SwiftUI treat it as a new
                    // destination and rebuild the screen, re-fetching
                    // reviews/photos for nothing.
                    BodegaDetailView(
                        bodega: bodega,
                        bodegaService: bodegaService,
                        reviewService: reviewService,
                        photoService: photoService,
                        flagService: flagService,
                        sessionStore: sessionStore
                    ) { updatedBodega in
                        mapViewModel.bodegaWasUpdated(updatedBodega)
                        listViewModel.bodegaWasUpdated(updatedBodega)
                    }
                }
                .sheet(isPresented: $showingSignIn) {
                    SignInView(sessionStore: sessionStore)
                }
                .sheet(isPresented: $showingFilters) {
                    BodegaFilterSheet(filter: $filter)
                }
                .onChange(of: filter) { _, newFilter in
                    mapViewModel.filter = newFilter
                    listViewModel.filter = newFilter
                }
                .sheet(item: $addBodegaViewModel) { viewModel in
                    AddBodegaView(viewModel: viewModel, sessionStore: sessionStore) { insertedBodega in
                        mapViewModel.bodegaWasAdded(insertedBodega)
                        listViewModel.bodegaWasAdded(insertedBodega)
                        // The single call site until #25's coordinator
                        // takes it over and uses the return value.
                        firstRunState.markFirstBodegaAdded()
                        addBodegaViewModel = nil
                    }
                }
                .onChange(of: showingOnboarding) { _, isShowing in
                    guard !isShowing else { return }
                    landAfterOnboarding()
                }
                .onAppear {
                    // The overlay can be gone before this view exists (the
                    // environment was still loading, or failed and was
                    // retried, when the user picked the add path).
                    if firstRunState.pendingTutorialAdd {
                        landAfterOnboarding()
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
                onConfirmPlacement: { presentAddBodegaSheet(coordinate: $0) },
                onSelectBodega: { path.append($0) },
                onClearFilters: { filter = filter.clearingAmenities() }
            )
        case .list:
            BodegaListView(viewModel: listViewModel, filter: $filter) {
                // Same as the toolbar's "Drop a Pin on Map".
                activeTab = .map
                isPlacingBodega = true
            }
        }
    }

    /// Filled icon plus a count badge whenever any filter (including a
    /// search typed on the List tab) is active — the only on-screen signal
    /// on the Map tab that pins are being hidden. Uses the system `.badge`,
    /// which iOS 26 draws on toolbar items (a count of 0 hides it). A
    /// hand-drawn overlay doesn't survive the iOS 26 toolbar: it renders
    /// only the label's icon, dropping the overlay and leaking its text
    /// into the button's accessibility label (#43).
    private var filterButton: some View {
        Button {
            showingFilters = true
        } label: {
            Label(
                "Filters",
                systemImage: filter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .badge(filter.activeCount)
        .accessibilityValue(filter.isActive ? "\(filter.activeCount) active" : "None active")
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

// MARK: - First run (#21)

extension BrowseView {
    /// Account toolbar item: a `Menu` (was a plain button) so it can also
    /// hold "Show Intro Again" (#21). Same label and accessibility label as
    /// before, so the #44 toolbar layout is unchanged.
    private var accountMenu: some View {
        Menu {
            if sessionStore.isSignedIn {
                Button("Sign Out…", role: .destructive) {
                    showingSignOutConfirmation = true
                }
            } else {
                Button("Sign In") {
                    showingSignIn = true
                }
            }
            Divider()
            Button(AppCopy.onboardingReplayMenuItem.copy.text) {
                withAnimation(OnboardingView.animation(reduceMotion: reduceMotion)) {
                    showingOnboarding = true
                }
            }
        } label: {
            Label(
                "Account",
                systemImage: sessionStore.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle"
            )
        }
    }

    /// The single landing rule for every onboarding exit, first run or
    /// replay: the Map tab, in placement mode only when the user chose "Add
    /// a Bodega You Know" (the pending request is consumed here, once), and
    /// out of any placement left over from before a replay otherwise.
    /// `browseMode` and location are left alone. A no-op while the overlay
    /// is still up; the `onChange` in `body` runs it when it closes.
    private func landAfterOnboarding() {
        guard !showingOnboarding else { return }
        activeTab = .map
        isPlacingBodega = firstRunState.pendingTutorialAdd
        firstRunState.pendingTutorialAdd = false
    }
}
