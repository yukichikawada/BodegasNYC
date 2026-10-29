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
/// constructed here, unlike a plain single-screen view: `BrowseView` owns
/// them alongside the list's. This view itself stays mounted on both tabs
/// (#23): the List tab is a page laid over it, so `showsToolbar` is false
/// there, which hides the map-only toolbar items and stops camera settles
/// from refetching or reclustering under the page.
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

    let viewModel: BodegaMapViewModel
    @Binding var cameraPosition: MapCameraPosition
    /// The tapped pin or cluster. Both are tagged so MapKit's one tap
    /// recognizer decides every tap; a badge tap gesture used to zoom first,
    /// then MapKit's delayed selection opened a member now under the finger.
    @State var selectedItemID: MapDisplayItem.ID?
    @State var lastVisibleRegion: MKCoordinateRegion?
    @State private var showingClearConfirmation = false
    /// A settle held back under the List tab, and the last one delivered:
    /// the held one is replayed on return only if the camera really moved.
    @State var pendingSettledRegion: MKCoordinateRegion?
    @State var deliveredRegion: MKCoordinateRegion?
    /// Pin labels (#67, see `MapScreenView+PinLabels.swift`).
    @State var isCameraMoving = false
    @State var lastSettledCamera: MapCamera?
    @State var mapSize: CGSize = .zero
    /// Placement card height (slot chrome included) and the crosshair's
    /// global centre, the space `MapProxy.convert` reads (#23 T3).
    @State private var placementCardHeight: CGFloat = 0
    @State private var crosshairPoint: CGPoint?
    /// Locate Me (#84, `MapScreenView+LocateMe.swift`): the latest tap, the
    /// pulse, and the settles that moved the camera's centre.
    @State var locateRequest: LocateRequest?
    @State var isLocating = false
    @State var cameraTakeoverCount = 0
    @State var mapResizedAt: Date?
    /// Walked blocks (#108, `MapScreenView+WalkedBlocks.swift`): what the
    /// map draws, changed only at camera rest (design D10), and its width.
    @State var walkedDisplay = WalkedOverlayDisplay()
    /// The Your Blocks sheet (#108 PR 2, design D7).
    @State var showingYourBlocks = false
    /// This window's identity for the shared Streets Walked view model's
    /// scene count (#123 eng R5).
    @State var streetsSceneToken = StreetsWalkedViewModel.SceneToken.make()
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Environment(PinMotionState.self) var pinMotion // held pin (#23 T1)
    let locationPermissionClient: LocationPermissionClient
    let userLocation: UserLocationProvider? // the dot, a pin-label obstacle (#67)
    let streetsWalkedViewModel: StreetsWalkedViewModel?
    @Binding var isPlacingBodega: Bool
    private let onConfirmPlacement: (CLLocationCoordinate2D) -> Void
    private let onSelectBodega: (Bodega) -> Void
    private let onClearFilters: () -> Void
    /// Whether the tutorial's Add tip may take the bottom slot. `BrowseView`
    /// computes it (the four `shouldOfferAddTip` inputs plus TipKit's own
    /// verdict), so the slot never shows an empty card.
    private let showsAddTip: Bool
    /// Pin drop phases, the first-add card, the settle signal (#25).
    let addCompletion: AddCompletionCoordinator?
    /// False under the List tab: no Locate Me / Streets Walked, settles held.
    let showsToolbar: Bool
    /// The List tab or a pushed detail is up (live, from `BrowseView`): a
    /// pending Locate Me is cancelled (#84).
    let hasLeftMap: Bool

    init(
        viewModel: BodegaMapViewModel,
        cameraPosition: Binding<MapCameraPosition>,
        locationPermissionClient: LocationPermissionClient,
        userLocation: UserLocationProvider? = nil,
        streetsWalkedViewModel: StreetsWalkedViewModel? = nil,
        isPlacingBodega: Binding<Bool>,
        onConfirmPlacement: @escaping (CLLocationCoordinate2D) -> Void,
        onSelectBodega: @escaping (Bodega) -> Void,
        onClearFilters: @escaping () -> Void,
        showsAddTip: Bool = false,
        addCompletion: AddCompletionCoordinator? = nil,
        showsToolbar: Bool = true,
        hasLeftMap: Bool = false
    ) {
        self.viewModel = viewModel
        _cameraPosition = cameraPosition
        self.locationPermissionClient = locationPermissionClient
        self.userLocation = userLocation
        self.streetsWalkedViewModel = streetsWalkedViewModel
        _isPlacingBodega = isPlacingBodega
        self.onConfirmPlacement = onConfirmPlacement
        self.onSelectBodega = onSelectBodega
        self.onClearFilters = onClearFilters
        self.showsAddTip = showsAddTip
        self.addCompletion = addCompletion
        self.showsToolbar = showsToolbar
        self.hasLeftMap = hasLeftMap
    }

    /// The bottom slot's one occupant: the placement card while placing,
    /// else the card `MapBottomCard.select` picks, else nothing.
    private var bottomSlot: BrowseMotion.BottomSlot {
        BrowseMotion.BottomSlot.select(isPlacing: isPlacingBodega, card: bottomCardContent)
    }

    /// What the bottom slot shows when the placement card isn't up — see
    /// `MapBottomCard.select` for the precedence.
    private var bottomCardContent: MapBottomCard.Content? {
        MapBottomCard.select(
            isPlacing: isPlacingBodega,
            firstAdd: addCompletion?.firstAddCard.map { MapBottomCard.FirstAdd(hasCat: $0.hasCat) },
            recorder: streetsWalkedViewModel?.cardProblem,
            emptyState: MapBottomCard.bodegaEmptyState(
                browseMode: viewModel.browseMode,
                isLoadedEmpty: viewModel.isLoadedEmpty,
                isFilteredEmpty: viewModel.isFilteredEmpty,
                isBlockZoom: viewModel.pinLabels.isBlockZoom
            ),
            addTip: showsAddTip,
            streets: streetsWalkedViewModel.map {
                MapBottomCard.showsStreetsBanner(
                    // Never while paused: walking would fill nothing in (#123 DS3).
                    isTrackingEnabled: $0.recordingState == .recording,
                    hasCounted: $0.hasCounted && $0.countState != .unavailable,
                    hasWalkedBlocks: !$0.walkedBlockIDs.isEmpty,
                    isDismissed: $0.isEmptyBannerDismissed
                )
            } ?? false,
            zoomInForBlocks: showsZoomInForBlocks
        )
    }

    var body: some View {
        MapReader { proxy in
            // Back to front (spec layer order): map, bottom slot, crosshair
            // (never covered by the card). Recorder problems are a bottom
            // card (#123 design DS1).
            walkedBlockTriggers(locateMeEvents(pinLabelTriggers(map(proxy), proxy: proxy)), proxy: proxy)
                .onChange(of: showsToolbar) { _, isMapTab in
                    if isMapTab { mapTabDidReturn(proxy) }
                }
                .overlay { PinTransitionAnchor(proxy: proxy) }
                // An overlay, not a safe-area inset, so the map doesn't shift
                // when a card or the placement card comes or goes (#58, #23).
                // Lifted clear of the Apple Maps logo and Legal link, which
                // must stay visible; VoiceOver still reads it after the map's
                // content (DD15).
                .overlay(alignment: .bottom) { bottomSlotLayer(proxy) }
                .overlay {
                    PlacementCrosshair(
                        isPlacing: isPlacingBodega,
                        cardHeight: placementCardHeight,
                        clearance: Self.attributionClearance,
                        point: $crosshairPoint
                    )
                }
        }
        // The List tab's search keyboard must never resize the covered map.
        .ignoresSafeArea(.keyboard)
        .onChange(of: isPlacingBodega) { _, isPlacing in
            guard !isPlacing else { return }
            // Measure afresh next time; VoiceOver restarts at the toolbar.
            placementCardHeight = 0
            crosshairPoint = nil
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
        .task {
            viewModel.loadInitialIfNeeded(region: Self.newYorkCityDefault)
            // The map showing is one of the times matching runs (eng R2).
            await streetsWalkedViewModel?.refreshWalkedBlocks()
        }
        .toolbar {
            // Map-only items, innermost in the trailing group so Account and
            // Add keep their place when the List tab drops these (#23).
            if showsToolbar {
                mapToolbarItems
            }
        }
        .confirmationDialog(
            AppCopy.clearHistoryConfirmTitle.copy.text,
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppCopy.deleteHistoryAction.copy.text, role: .destructive) {
                // The cutoff is this tap (design D5, eng R9).
                let tapTime = Date()
                Task { await clearStreetsWalkedHistory(at: tapTime) }
            }
            Button(AppCopy.cancelAction.copy.text, role: .cancel) {}
        } message: {
            Text(AppCopy.clearHistoryConfirmBody.copy.text)
        }
    }

    private func map(_ proxy: MapProxy) -> some View {
        Map(position: $cameraPosition, selection: $selectedItemID) {
            ForEach(orderedDisplayItems) { item in
                switch item {
                case .pin(let bodega):
                    // One pin view for all (D10); the tag keeps tap-to-detail.
                    Annotation(bodega.name, coordinate: bodega.coordinate.clLocationCoordinate, anchor: .center) {
                        HeldPinView(
                            bodega: bodega,
                            motion: pinMotion,
                            labels: viewModel.pinLabels,
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
            pinMotion.standInAnnotation(among: viewModel.displayItems)
            walkedBlockOverlay
            // The standard blue dot + heading cone, same as Apple/Google
            // Maps. Silently renders nothing until When-In-Use is granted
            // and a fix arrives — no separate gating needed here.
            UserAnnotation()
        }
        // The location dot is status, not a control, so it stays system
        // blue rather than taking the app tint (DESIGN.md Colors). Applied
        // to the Map alone, before the overlays, so they keep the tint.
        .tint(.blue)
        // Ours are the only business names; wayfinding stays (#67 D1).
        .mapStyle(.standard(pointsOfInterest: .excluding(BodegaMapViewModel.excludedPOICategories)))
        .onMapCameraChange(frequency: .onEnd) { cameraDidSettle($0, proxy: proxy) }
        .onChange(of: selectedItemID) { _, newValue in
            guard let newValue else { return }
            // Cleared at once so every tap is a change. MapKit reports taps late:
            // one landing after the List tab covers the map is ignored.
            selectedItemID = nil
            guard !isPlacingBodega, showsToolbar else { return }
            if let cluster = pinMotion.tapped(newValue, among: viewModel.displayItems, onPush: onSelectBodega) {
                zoom(into: cluster)
            }
        }
    }

    private func performBottomCardAction(for content: MapBottomCard.Content) {
        switch content {
        case .emptyState(.noneNearby), .emptyState(.noneOnBlock), .emptyState(.noBodegas), .addTip:
            isPlacingBodega = true
        case .emptyState(.noFilterMatches):
            onClearFilters()
        case .firstAdd:
            addCompletion?.dismissFirstAddCard()
        case .recorder(let problem):
            if problem.opensSettings { openSettings() }
        case .emptyState(.noStreets), .emptyState(.zoomInForBlocks):
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
}

// MARK: - Bottom slot, placement and map toolbar (#23)

// In an extension (same file, so the private state stays private) to keep the
// struct body within SwiftLint's type length.
extension MapScreenView {
    /// The bottom slot: placement card or `MapBottomCard`, one at a time,
    /// 24pt clear of the attribution row.
    private func bottomSlotLayer(_ proxy: MapProxy) -> some View {
        VStack(spacing: 0) {
            switch bottomSlot {
            case .placing:
                PlacementBottomBar(
                    onUseThisLocation: { confirmPlacement(proxy) },
                    onCancel: { isPlacingBodega = false },
                    onNearMe: { Task { await locateMe() } }
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { placementCardHeight = $0 }
                .transition(slotTransition)
            case .card(let content):
                // `.id` makes a change of content a remove + insert, so
                // every swap in the slot runs the same transition.
                MapBottomCard(
                    content: content,
                    onAction: { performBottomCardAction(for: content) },
                    onDismiss: { dismissBottomCard(content) }
                )
                .id(content)
                .transition(slotTransition)
            case .empty:
                EmptyView()
            }
        }
        .padding(.bottom, Self.attributionClearance)
        .animation(.easeInOut(duration: BrowseMotion.BottomSlot.transitionSeconds), value: bottomSlot)
        // An overlay is otherwise read before the map's content.
        .accessibilitySortPriority(-1)
    }

    /// The close: the recorder card hides for its problem (DS5); the
    /// streets banner for this launch.
    private func dismissBottomCard(_ content: MapBottomCard.Content) {
        if case .recorder = content {
            streetsWalkedViewModel?.dismissRecorderCard()
        } else {
            streetsWalkedViewModel?.isEmptyBannerDismissed = true
        }
    }

    private var slotTransition: AnyTransition {
        BrowseMotion.BottomSlot.style(reduceMotion: reduceMotion).transition
    }

    /// Submits the coordinate under the crosshair's measured point (the
    /// visible centre only if it was never measured).
    private func confirmPlacement(_ proxy: MapProxy) {
        let underCrosshair = crosshairPoint.flatMap { proxy.convert($0, from: .global) }
        onConfirmPlacement(underCrosshair ?? lastVisibleRegion?.center ?? Self.newYorkCityDefault.center)
        isPlacingBodega = false
    }

    @ToolbarContentBuilder
    private var mapToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await locateMe() }
            } label: {
                locateMeLabel
            }
        }
        if let streetsWalkedViewModel {
            ToolbarItem(placement: .topBarTrailing) {
                // Design D5: Your Blocks, Show on Map, Start/Stop Recording,
                // Clear History…, each in its own section.
                Menu {
                    Section {
                        Button(AppCopy.YourBlocks.title.copy.text) { showingYourBlocks = true }
                            .accessibilityHint(AppCopy.YourBlocks.menuHint.copy.text)
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
            }
        }
    }
}
