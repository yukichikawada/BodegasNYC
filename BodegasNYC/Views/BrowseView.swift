import MapKit
import SwiftUI
import TipKit

/// The map/list toggle container: owns the single `NavigationStack` for the
/// whole browse session (previously `MapScreenView` wrapped itself in its
/// own, as a stopgap — see its prior doc comment), the map↔list tab
/// selection, and navigation to `BodegaDetailView`.
///
/// Also owns `mapViewModel`/`listViewModel`/`cameraPosition` — constructing
/// them here, once, and handing them down as `let`/`Binding` rather than
/// letting each child view build its own is what makes switching tabs not
/// re-trigger a fetch: the list page is inserted and removed on every tab
/// switch, which would otherwise discard its already-loaded data. The map
/// itself is always mounted under the list (#23, `BrowseView+Content.swift`).
struct BrowseView: View {
    enum Tab: String, CaseIterable, Identifiable {
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

    @State var activeTab: Tab = .map
    @State var path: [Bodega] = []
    @State var cameraPosition: MapCameraPosition = .region(MapScreenView.newYorkCityDefault)
    @State var mapViewModel: BodegaMapViewModel
    @State var listViewModel: BodegaListViewModel
    /// The list's top row, kept here so a Map → List round trip with the
    /// same query lands on the same row (#23).
    @State var listScrollID: Bodega.ID?
    @FocusState var isSearchFocused: Bool
    /// The window's own bottom inset (home indicator), which the covered map
    /// keeps on both tabs instead of the List tab's search-bar inset (#23).
    @State var deviceBottomInset: CGFloat = 0
    @State var showingSignIn = false
    @State var showingAccount = false // the Account sheet (#127)
    @AccessibilityFocusState var accountMenuFocused: Bool // back here after it closes (DS7)
    @State var isPlacingBodega = false
    @State var addRoute = TelemetryEvent.AddRoute.Tracker() // `add_started`'s route (#147 E6)
    @State private var addBodegaViewModel: AddBodegaViewModel?
    @State private var existingToOpen: Bodega? // a duplicate-prompt match (#20)
    @State var detailOpenedFromAddFlow: Bodega.ID? // see `zoomsFromPin(to:)`
    @State var detailOrigin: Tab? // the pushed detail's tab (#150 R5), see `zoomOrigin()`
    @State var showOnMapPending = false // the List path's deferred pop (#150), see `showOnMap`
    @State private var isResolvingCurrentLocation = false
    /// The single source of truth for filter/search across both tabs —
    /// pushed into both view models via `.onChange` below, so switching
    /// Map↔List never loses or desyncs it.
    @State var filter: BodegaFilter = .none
    @State var showingFilters = false
    /// The list's order (#81), remembered across launches; an unreadable
    /// stored value falls back to nearest.
    @AppStorage("listOrder") var listOrder: ListOrder = .nearest
    /// With `browseWidth`, picks `modePicker`'s form: see `BrowseModePickerStyle` (#44, #143).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var browseWidth: CGFloat = 0

    private let bodegaService: BodegaService
    private let reviewService: ReviewService
    private let photoService: PhotoService
    private let flagService: FlagService
    let accountService: AccountService
    let sessionStore: SessionStore
    let locationPermissionClient: LocationPermissionClient
    let streetsWalkedViewModel: StreetsWalkedViewModel?
    /// Passed in by `RootView`, which owns it (and the onboarding overlay)
    /// rather than putting it on `AppEnvironment`; see `RootView`.
    let firstRunState: FirstRunState
    /// `RootView`'s overlay flag: the Account menu's "Show Intro Again"
    /// sets it, and it going false is this view's cue to land on the map.
    @Binding var showingOnboarding: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// The tutorial's Add tip: TipKit's display verdict and whether a
    /// detail has been opened (#22).
    @State private var addTipState = AddTipState()
    /// Everything after a successful add (#25); camera bound on appear.
    @State var addCompletion: AddCompletionCoordinator
    @Namespace var detailTransition // pin → detail zoom source (#23)
    @State var pinMotion = PinMotionState()
    @State var userLocation: UserLocationProvider // distances (#68), see BrowseView+Distance.swift
    let telemetry: Telemetry // events and the menu's switch (#147), see BrowseView+Account.swift

    init(
        bodegaService: BodegaService,
        reviewService: ReviewService,
        photoService: PhotoService,
        flagService: FlagService,
        accountService: AccountService,
        sessionStore: SessionStore,
        locationPermissionClient: LocationPermissionClient,
        streetsWalkedViewModel: StreetsWalkedViewModel?,
        firstRunState: FirstRunState,
        showingOnboarding: Binding<Bool>,
        telemetry: Telemetry
    ) {
        self.firstRunState = firstRunState
        self.telemetry = telemetry
        _showingOnboarding = showingOnboarding
        let mapViewModel = BodegaMapViewModel(bodegaService: bodegaService, telemetry: telemetry)
        let listViewModel = BodegaListViewModel(bodegaService: bodegaService, telemetry: telemetry)
        _mapViewModel = State(initialValue: mapViewModel)
        _listViewModel = State(initialValue: listViewModel)
        _addCompletion = State(initialValue: .forBrowsing(firstRunState, mapViewModel, listViewModel, telemetry))
        _userLocation = State(initialValue: UserLocationProvider(client: locationPermissionClient))
        self.bodegaService = bodegaService
        self.reviewService = reviewService
        self.photoService = photoService
        self.flagService = flagService
        self.accountService = accountService
        self.sessionStore = sessionStore
        self.locationPermissionClient = locationPermissionClient
        self.streetsWalkedViewModel = streetsWalkedViewModel
    }

    /// The Map/List switch in the toolbar's principal slot. A text
    /// segmented control where it fits; from `.xLarge` up, or on phones
    /// narrower than 400 pt, a single-button `Menu` wrapping the same
    /// `Picker` (see `BrowseModePickerStyle`).
    @ViewBuilder
    private var modePicker: some View {
        let picker = Picker("Browse Mode", selection: tabSelection) {
            ForEach(Tab.allCases) { tab in
                Label(tab.label, systemImage: tab.systemImage).tag(tab)
            }
        }
        if BrowseModePickerStyle.resolve(dynamicTypeSize: dynamicTypeSize, width: browseWidth) == .menu {
            Menu {
                picker
            } label: {
                // The principal slot gives a bare icon (no glass button), so the
                // label carries its own target: 44 pt wide, and as tall as the
                // toolbar allows (it caps items at 36 pt, the same as the
                // system Filters button), so taps near the glyph's edge count.
                Label(activeTab.label, systemImage: activeTab.systemImage)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
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
                    // Account and Add: see `trailingToolbar`.
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { browseWidth = $0 }
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
                        sessionStore: sessionStore, userLocation: userLocation, telemetry: telemetry,
                        onShowOnMap: showOnMap
                    ) { updatedBodega in
                        mapViewModel.bodegaWasUpdated(updatedBodega)
                        listViewModel.bodegaWasUpdated(updatedBodega)
                    }
                    .pinToDetailTransition(sourceID: bodega.id, in: detailTransition, fromMap: zoomsFromPin(to: bodega))
                    .task {
                        telemetry.capture(.bodegaOpened(id: bodega.id, fromMap: activeTab == .map))
                        await addTipState.donateDidOpenBodegaDetail()
                    }
                }
                .sheet(isPresented: $showingSignIn) {
                    SignInView(sessionStore: sessionStore)
                }
                .sheet(isPresented: $showingFilters) { filterSheet }
                .onChange(of: filter) { _, newFilter in
                    mapViewModel.filter = newFilter
                    listViewModel.filter = newFilter
                    // A different query has a different top row.
                    listScrollID = nil
                }
                .modifier(BrowseTelemetryEvents(telemetry: telemetry, activeTab: activeTab, filter: filter))
                // The add sheet and everything after a successful add (#25).
                .addBodegaFlow($addBodegaViewModel, sessionStore: sessionStore, completion: addCompletion,
                               existingToOpen: $existingToOpen, openExisting: openExisting) {
                    activeTab = .map
                    pinMotion.send(.interrupted) // an add clears a Show on Map spotlight (#150 R2)
                }
                .onChange(of: path.isEmpty) {
                    if path.isEmpty { detailOpenedFromAddFlow = nil }
                    detailOrigin = path.isEmpty ? nil : activeTab
                }
                .modifier(spotlightWiring)
                .onChange(of: showingOnboarding) { _, isShowing in
                    syncTipParameters()
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
                    syncTipParameters()
                    // Preloaded so the List tab's first slide carries rows,
                    // not a spinner (#23).
                    listViewModel.loadInitialIfNeeded()
                }
                .addCompletion(addCompletion, camera: $cameraPosition, hasLeftMap: !path.isEmpty || activeTab == .list)
                .onChange(of: isPlacingBodega) { _, isPlacing in
                    syncTipParameters()
                    if !isPlacing { addRoute.placementEnded() }
                }
                .onChange(of: firstRunState.hasAddedFirstBodega) { syncTipParameters() }
                .task { await addTipState.observe() }
                .modifier(userLocationRefresh)
                .modifier(listOrderSync)
                // Popover tips (the placement tip) inherit this; the inline
                // tips set their own inline variant.
                .tipViewStyle(BodegaTipStyle())
                .overlay {
                    if isResolvingCurrentLocation {
                        ProgressView()
                    }
                }
        }
    }

    /// Account and Add. Declared by `content` after `MapScreenView`, so the
    /// map-only Locate Me and Streets Walked come before them: innermost in
    /// the trailing group, and Account and Add keep their place when the
    /// List tab drops those two (#23).
    @ToolbarContentBuilder
    var trailingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            accountMenu
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Drop a Pin on Map", systemImage: "mappin.and.ellipse") {
                    // Manual placement: pan-under-a-fixed-pin over whatever
                    // the map already shows (see `PlacementBottomBar`) — no
                    // GPS fetch here. That's "Use Current Location" below.
                    requestPlacement()
                }
                Button("Use Current Location", systemImage: "location.fill") {
                    Task { await useCurrentLocationShortcut() }
                }
            } label: {
                Label("Add Bodega", systemImage: "plus")
            }
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
            presentAddBodegaSheet(coordinate: coordinate, fromCurrentLocation: true)
        } else {
            requestPlacement()
        }
    }

    /// The add sheet's single entry, so `add_started` fires once per
    /// presentation on every route (#147 E6).
    func presentAddBodegaSheet(coordinate: CLLocationCoordinate2D, fromCurrentLocation: Bool = false) {
        let route = addRoute.sheetPresented(fromCurrentLocation: fromCurrentLocation)
        isPlacingBodega = false
        telemetry.capture(.addStarted(route: route))
        addBodegaViewModel = AddBodegaViewModel(
            coordinate: Coordinate(coordinate),
            bodegaService: bodegaService,
            sessionStore: sessionStore,
            telemetry: telemetry
        )
    }
}

// MARK: - List order (#81)

extension BrowseView {
    /// Whether the list is the frontmost thing on screen: nothing pushed
    /// and nothing presented over it (Filters, Sign In, Add Bodega, the
    /// duplicate prompt, the Account sheet). The automatic re-sort's
    /// VoiceOver announcement and focus move wait on it (design D3). Here, not
    /// in `BrowseView+Content.swift`, because the presentation flags are private.
    var isListForeground: Bool {
        path.isEmpty && !showingFilters && !showingSignIn && addBodegaViewModel == nil
            && existingToOpen == nil && !showingAccount
    }

    /// The map is frontmost (Map tab, the above, no location wait, no
    /// onboarding): the Streets Walked intro presents only then (#126).
    var isMapForeground: Bool {
        isListForeground && !isResolvingCurrentLocation && activeTab == .map && !showingOnboarding
    }
}

// MARK: - First run (#21)

extension BrowseView {
    /// The single landing rule for every onboarding exit, first run or
    /// replay: the Map tab, in placement mode only when the user chose "Add
    /// a Bodega You Know" (the pending request is consumed here, once), and
    /// out of any placement left over from before a replay otherwise.
    /// `browseMode` and location are left alone. A no-op while the overlay
    /// is still up; the `onChange` in `body` runs it when it closes.
    private func landAfterOnboarding() {
        guard !showingOnboarding else { return }
        activeTab = .map
        if firstRunState.pendingTutorialAdd { addRoute.onboardingStartsPlacement() }
        isPlacingBodega = firstRunState.pendingTutorialAdd
        firstRunState.pendingTutorialAdd = false
    }
}

// MARK: - Tutorial (#22)

extension BrowseView {
    /// The Add tip takes the map's bottom slot only when the pure gating
    /// agrees (no first add yet, onboarding gone, not placing, a detail
    /// opened) and TipKit itself would render it. On the List tab the map
    /// (and its slot) is covered and VoiceOver-hidden, so the tip is never
    /// seen there.
    var showsAddTip: Bool {
        TutorialTips.shouldOfferAddTip(
            hasAddedFirstBodega: firstRunState.hasAddedFirstBodega,
            isOnboardingVisible: showingOnboarding,
            isPlacingBodega: isPlacingBodega,
            hasOpenedDetail: addTipState.hasOpenedDetail
        ) && addTipState.isDisplayable
    }

    /// Mirrors the state the tips' rules read into their TipKit parameters.
    func syncTipParameters() {
        TutorialTips.canBePromptedForLocation = locationPermissionClient.authorizationStatus == .notDetermined
        TutorialTips.hasAddedFirstBodega = firstRunState.hasAddedFirstBodega
        TutorialTips.isOnboardingVisible = showingOnboarding
        TutorialTips.isPlacingBodega = isPlacingBodega
    }
}
