import SwiftUI
import UIKit

/// `BrowseView`'s tab content and Map/List plumbing (#23 T2), kept out of
/// `BrowseView.swift` so that file stays within its length budget.
///
/// The map is always mounted: the List tab is an opaque page inserted above
/// it, so switching tabs never rebuilds the `Map` (camera, tiles and
/// clusters are pixel-identical on return; PRD §8: the map never goes away).
extension BrowseView {
    /// Layer order, back to front: the live map, then the list page on the
    /// List tab (`zIndex(1)` so its removal also animates above the map).
    @ViewBuilder
    var content: some View {
        ZStack {
            MapScreenView(
                viewModel: mapViewModel,
                cameraPosition: $cameraPosition,
                locationPermissionClient: locationPermissionClient,
                streetsWalkedViewModel: streetsWalkedViewModel,
                isPlacingBodega: $isPlacingBodega,
                onConfirmPlacement: { presentAddBodegaSheet(coordinate: $0) },
                onSelectBodega: { path.append($0) },
                onClearFilters: { filter = mapViewModel.clearedFilterForMapCard(from: filter) },
                showsAddTip: showsAddTip,
                addCompletion: addCompletion,
                showsToolbar: activeTab == .map
            )
            // Pin → detail (#23 T1): the held pin's state and the zoom's
            // namespace, and the pop / placement / List tab events it reacts to.
            .environment(pinMotion)
            .environment(\.pinZoomNamespace, detailTransition)
            .pinMotionEvents(
                pinMotion,
                presentedBodegaID: path.last?.id,
                isPlacing: isPlacingBodega,
                showsMap: activeTab == .map
            )
            // The List tab's search bar adds a bottom container inset, and
            // MapKit re-centres on any inset change, so the map ignores the
            // container's bottom inset and keeps the window's own (home
            // indicator clearance for the Apple logo and Legal link) on both
            // tabs. The map never moves under the page.
            .safeAreaPadding(.bottom, deviceBottomInset)
            .ignoresSafeArea(.container, edges: .bottom)
            // Covered by the list: no taps, and VoiceOver never reaches a
            // pin, cluster or card under the page.
            .allowsHitTesting(activeTab == .map)
            .accessibilityHidden(activeTab == .list)

            // Hosts Account and Add after the map's own toolbar items, so
            // those sit innermost (toolbar items merge in view order).
            Color.clear
                .frame(width: 0, height: 0)
                .toolbar { trailingToolbar }

            if activeTab == .list {
                BodegaListView(
                    viewModel: listViewModel,
                    filter: $filter,
                    scrollID: $listScrollID,
                    searchFocus: $isSearchFocused,
                    userFix: userLocation.usableFix,
                    reservesDistanceSlot: userLocation.isAuthorized,
                    onAddBodega: requestPlacement,
                    onShowMap: { tabSelection.wrappedValue = .map }
                )
                .transition(listTransition)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: listTransitionSeconds), value: activeTab)
        // Re-read on rotation (any size change); the window inset never
        // includes toolbars or the keyboard.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
            deviceBottomInset = Self.windowBottomInset
        }
        .task { deviceBottomInset = Self.windowBottomInset }
    }

    private static var windowBottomInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }?.keyWindow?.safeAreaInsets.bottom
            ?? scenes.first?.keyWindow?.safeAreaInsets.bottom
            ?? 0
    }

    /// The Map/List picker's selection. Choosing Map resigns the search
    /// field on the same tick the page starts to leave, so the keyboard goes
    /// down with it (the map ignores the keyboard, so it does not move).
    var tabSelection: Binding<Tab> {
        Binding(
            get: { activeTab },
            set: { newTab in
                if newTab == .map { isSearchFocused = false }
                activeTab = newTab
                // VoiceOver (design review 18A): back on the map, start from
                // the top of the screen (the toolbar). The list moves focus
                // to its first row itself.
                if newTab == .map {
                    UIAccessibility.post(notification: .screenChanged, argument: nil)
                }
            }
        )
    }

    /// Enters placement mode on the map. From the List tab the page leaves
    /// first and placement starts once it is gone, so the crosshair lands
    /// and the card rises over a map that is already uncovered (design
    /// review 3A). From the Map tab it starts at once, as before.
    func requestPlacement() {
        guard activeTab == .list else {
            isPlacingBodega = true
            return
        }
        isSearchFocused = false
        activeTab = .map
        let delay = listTransitionSeconds
        Task {
            guard (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
            // The user may have gone back to the list meanwhile.
            guard activeTab == .map else { return }
            isPlacingBodega = true
        }
    }

    // MARK: Motion (BrowseMotion.ListTransition)

    /// Read at each render rather than observed: the transition is built on
    /// the render that inserts or removes the page, which is when it counts.
    private var prefersCrossFade: Bool { UIAccessibility.prefersCrossFadeTransitions }

    private var listTransitionSeconds: TimeInterval {
        BrowseMotion.ListTransition.duration(reduceMotion: reduceMotion, crossFade: prefersCrossFade)
    }

    private var listTransition: AnyTransition {
        BrowseMotion.ListTransition.style(reduceMotion: reduceMotion, crossFade: prefersCrossFade).transition
    }
}
