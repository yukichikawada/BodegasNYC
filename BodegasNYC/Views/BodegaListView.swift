import SwiftUI

/// The list screen: a flat, `.all`-only list of bodegas (see
/// `BodegaListViewModel`'s doc comment for why there's no nearby-mode
/// toggle yet). Lives inside `BrowseView`'s single `NavigationStack` — rows
/// push to detail via `NavigationLink(value:)` against that ancestor
/// stack's `.navigationDestination(for: Bodega.self)`, so this view needs
/// no navigation callback of its own, unlike `MapScreenView`.
///
/// Takes an already-built `BodegaListViewModel` rather than constructing
/// one internally — `BrowseView` owns it so it survives Map↔List tab
/// switches instead of being torn down and rebuilt (and refetched) every
/// time this view remounts.
///
/// `filter` is `BrowseView`'s shared filter state, bound here only so
/// `.searchable` can edit its search text and the no-matches state can
/// clear it — `BrowseView` pushes the result back into `viewModel.filter`,
/// and this view renders `viewModel.filteredBodegas`.
struct BodegaListView: View {
    let viewModel: BodegaListViewModel
    @Binding var filter: BodegaFilter

    var body: some View {
        content
            // On the outer view rather than the `List` case alone, so the
            // search field stays put across the empty/no-matches states —
            // otherwise a search that matches nothing would remove the very
            // field needed to edit it.
            .searchable(text: $filter.searchText, prompt: "Name or address")
            // iOS 26's default search presentation hides the navigation bar
            // while the field is focused, taking `BrowseView`'s Filters
            // button, Map/List picker, and Account/Add buttons with it
            // (issue #37). Keep the toolbar on screen so a search in
            // progress can still switch tabs or open Filters.
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .task { viewModel.loadInitialIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            ProgressView()
        case .loaded where viewModel.bodegas.isEmpty:
            ContentUnavailableView(
                "No bodegas yet",
                systemImage: "cart",
                description: Text("Be the first to add one.")
            )
        case .loaded where viewModel.filteredBodegas.isEmpty:
            noMatches
        case .loaded:
            List(viewModel.filteredBodegas) { bodega in
                NavigationLink(value: bodega) {
                    BodegaRow(bodega: bodega)
                }
            }
            .listStyle(.plain)
        case .failed(let message):
            ContentUnavailableView(
                "Couldn't load bodegas",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    /// Distinct from "No bodegas yet": there *are* bodegas, the filter just
    /// hides all of them. A search-only filter gets the system's standard
    /// search empty state (the search field's own clear button is the
    /// obvious way out); once any data-point toggle is involved, that clear
    /// button alone wouldn't help, so this offers Clear Filters instead.
    @ViewBuilder
    private var noMatches: some View {
        if filter.requiredAmenities.isEmpty {
            ContentUnavailableView.search(text: filter.trimmedSearchText)
        } else {
            ContentUnavailableView {
                Label("No bodegas match", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Try turning off some filters.")
            } actions: {
                Button("Clear Filters") { filter = .none }
            }
        }
    }
}

private struct BodegaRow: View {
    let bodega: Bodega

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bodega.name)
                .font(.headline)
            if let address = bodega.address {
                Text(address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
