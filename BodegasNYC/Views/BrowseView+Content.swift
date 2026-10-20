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
            // Covered by the list: no taps, and VoiceOver never reaches a
            // pin, cluster or card under the page.
            .allowsHitTesting(activeTab == .map)
            .accessibilityHidden(activeTab == .list)

            if activeTab == .list {
                BodegaListView(
                    viewModel: listViewModel,
                    filter: $filter,
                    scrollID: $listScrollID,
                    searchFocus: $isSearchFocused,
                    onAddBodega: requestPlacement
                )
                .transition(listTransition)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: listTransitionSeconds), value: activeTab)
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
