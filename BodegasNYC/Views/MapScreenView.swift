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
    /// Extra bottom padding that keeps the card 8pt above the map's
    /// attribution row (Apple Maps logo + Legal, ~16pt measured, fixed at
    /// every text size) rather than on top of it (#58).
    private static let attributionClearance: CGFloat = 24

    private let viewModel: BodegaMapViewModel
    @Binding private var cameraPosition: MapCameraPosition
    /// The tapped pin or cluster. Both are tagged so MapKit's one tap
    /// recognizer decides every tap; a badge tap gesture used to zoom first,
    /// then MapKit's delayed selection opened a member now under the finger.
    @State private var selectedItemID: MapDisplayItem.ID?
    @State private var lastVisibleRegion: MKCoordinateRegion?
    @State private var showingClearConfirmation = false
    private let locationPermissionClient: LocationPermissionClient
    private let streetsWalkedViewModel: StreetsWalkedViewModel?
    @Binding private var isPlacingBodega: Bool
    private let onConfirmPlacement: (CLLocationCoordinate2D) -> Void
    private let onSelectBodega: (Bodega) -> Void
    private let onClearFilters: () -> Void
    /// Whether the tutorial's Add tip may take the bottom slot. `BrowseView`
    /// computes it (the four `shouldOfferAddTip` inputs plus TipKit's own
    /// verdict), so the slot never shows an empty card.
    private let showsAddTip: Bool
    /// Pin drop phases, the first-add card, the settle signal (#25).
    private let addCompletion: AddCompletionCoordinator?

    init(
        viewModel: BodegaMapViewModel,
        cameraPosition: Binding<MapCameraPosition>,
        locationPermissionClient: LocationPermissionClient,
        streetsWalkedViewModel: StreetsWalkedViewModel? = nil,
        isPlacingBodega: Binding<Bool>,
        onConfirmPlacement: @escaping (CLLocationCoordinate2D) -> Void,
        onSelectBodega: @escaping (Bodega) -> Void,
        onClearFilters: @escaping () -> Void,
        showsAddTip: Bool = false,
        addCompletion: AddCompletionCoordinator? = nil
    ) {
        self.viewModel = viewModel
        _cameraPosition = cameraPosition
        self.locationPermissionClient = locationPermissionClient
        self.streetsWalkedViewModel = streetsWalkedViewModel
        _isPlacingBodega = isPlacingBodega
        self.onConfirmPlacement = onConfirmPlacement
        self.onSelectBodega = onSelectBodega
        self.onClearFilters = onClearFilters
        self.showsAddTip = showsAddTip
        self.addCompletion = addCompletion
    }

    /// What the bottom slot shows when the placement bar isn't up — see
    /// `MapBottomCard.select` for the precedence.
    private var bottomCardContent: MapBottomCard.Content? {
        MapBottomCard.select(
            isPlacing: isPlacingBodega,
            firstAdd: addCompletion?.firstAddCard.map { MapBottomCard.FirstAdd(hasCat: $0.hasCat) },
            emptyState: MapBottomCard.bodegaEmptyState(
                browseMode: viewModel.browseMode,
                isLoadedEmpty: viewModel.isLoadedEmpty,
                isFilteredEmpty: viewModel.isFilteredEmpty
            ),
            addTip: showsAddTip,
            streets: streetsWalkedViewModel.map {
                MapBottomCard.showsStreetsBanner(
                    isTrackingEnabled: $0.isTrackingEnabled,
                    hasPolylines: !$0.polylines.isEmpty,
                    isDismissed: $0.isEmptyBannerDismissed
                )
            } ?? false
        )
    }

    /// Selected and highlighted pins declared last. MapKit stacks by screen
    /// position, so this only settles ties at equal height (see
    /// `BodegaMapViewModel.drawOrdered`, #59).
    private var orderedDisplayItems: [MapDisplayItem] {
        let front = [selectedItemID.flatMap(UUID.init(uuidString:)), viewModel.highlightedBodegaID]
        return BodegaMapViewModel.drawOrdered(viewModel.displayItems, frontIDs: Set(front.compactMap { $0 }))
    }

    var body: some View {
        Map(position: $cameraPosition, selection: $selectedItemID) {
            ForEach(orderedDisplayItems) { item in
                switch item {
                case .pin(let bodega):
                    // One pin view for all (D10); the tag keeps tap-to-detail.
                    Annotation(bodega.name, coordinate: bodega.coordinate.clLocationCoordinate, anchor: .center) {
                        BodegaPinView(
                            bodega: bodega,
                            isSelected: selectedItemID == item.id,
                            phase: addCompletion?.pinPhase(for: bodega.id) ?? .atRest
                        )
                    }
                    .tag(item.id)
                    .annotationTitles(.hidden)
                case .cluster(let cluster):
                    Annotation(
                        "\(cluster.bodegaIDs.count) bodegas",
                        coordinate: cluster.coordinate.clLocationCoordinate
                    ) {
                        ClusterBadge(count: cluster.bodegaIDs.count)
                    }
                    .tag(item.id)
                    .annotationTitles(.hidden)
                }
            }
            if let streetsWalkedViewModel, streetsWalkedViewModel.isTrackingEnabled {
                ForEach(Array(streetsWalkedViewModel.polylines.enumerated()), id: \.offset) { _, path in
                    MapPolyline(coordinates: path.map(\.clLocationCoordinate))
                        .stroke(.orange.opacity(0.55), lineWidth: 4)
                }
            }
            // The standard blue dot + heading cone, same as Apple/Google
            // Maps. Silently renders nothing until When-In-Use is granted
            // and a fix arrives — no separate gating needed here.
            UserAnnotation()
        }
        // The location dot is status, not a control, so it stays system
        // blue rather than taking the app tint (DESIGN.md Colors). Applied
        // to the Map alone, before the overlays, so they keep the tint.
        .tint(.blue)
        .onMapCameraChange(frequency: .onEnd) { context in
            lastVisibleRegion = context.region
            viewModel.regionDidSettle(context.region)
            addCompletion?.cameraDidSettle(center: Coordinate(context.region.center))
        }
        .onChange(of: selectedItemID) { _, newValue in
            guard let newValue else { return }
            // Clears MapKit's selection either way, so returning to this
            // screen doesn't show a stale one and the same item can be
            // tapped again.
            selectedItemID = nil
            guard !isPlacingBodega else { return }
            switch viewModel.displayItems.first(where: { $0.id == newValue }) {
            case .pin(let bodega): onSelectBodega(bodega)
            case .cluster(let cluster): zoom(into: cluster)
            case nil: break
            }
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
        // An overlay, not a safe-area inset, so the map doesn't shift when a
        // card comes or goes (#58). Lifted clear of the Apple Maps logo and
        // Legal link, which must stay visible; VoiceOver still reads it after
        // the map's content (DD15).
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if let content = bottomCardContent {
                    // `.id` makes a change of content a remove + insert, so
                    // every swap in the slot runs the same transition.
                    MapBottomCard(
                        content: content,
                        onAction: { performBottomCardAction(for: content) },
                        onDismiss: { streetsWalkedViewModel?.isEmptyBannerDismissed = true }
                    )
                    .id(content)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, Self.attributionClearance)
            .animation(.easeInOut(duration: AddCompletionCoordinator.cardTransitionSeconds), value: bottomCardContent)
            // An overlay is otherwise read before the map's content.
            .accessibilitySortPriority(-1)
        }
        // Placement is a mode: its bar insets the map, centring the crosshair.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if isPlacingBodega {
                    PlacementBottomBar(
                        onUseThisLocation: {
                            onConfirmPlacement(lastVisibleRegion?.center ?? Self.newYorkCityDefault.center)
                            isPlacingBodega = false
                        },
                        onCancel: { isPlacingBodega = false },
                        onNearMe: { Task { await locateMe() } }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: AddCompletionCoordinator.cardTransitionSeconds), value: isPlacingBodega)
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

    private func performBottomCardAction(for content: MapBottomCard.Content) {
        switch content {
        case .emptyState(.noneNearby), .emptyState(.noBodegas), .addTip:
            isPlacingBodega = true
        case .emptyState(.noFilterMatches):
            onClearFilters()
        case .firstAdd:
            addCompletion?.dismissFirstAddCard()
        case .emptyState(.noStreets):
            break
        }
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
