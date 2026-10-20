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
/// The List tab is a page over the live map (#23 T2): `BrowseView` keeps
/// `MapScreenView` mounted underneath and inserts this view above it, so the
/// root is full-size and opaque in every state (the loading `ProgressView`
/// and `ContentUnavailableView`s included; DESIGN.md: pages are opaque).
/// `scrollID` and `searchFocus` are `BrowseView`'s, so a Map → List round
/// trip returns to the same row and choosing Map can resign the search field
/// before the page leaves.
///
/// `filter` is `BrowseView`'s shared filter state, bound here only so
/// `.searchable` can edit its search text and the no-matches state can
/// clear its toggles — `BrowseView` pushes the result back into
/// `viewModel.filter`, and this view renders `viewModel.filteredBodegas`.
///
/// Empty-state copy comes from `AppCopy` (#24). `onAddBodega` is the
/// nothing-loaded state's "Add a Bodega": `BrowseView` switches to the Map
/// tab in placement mode.
struct BodegaListView: View {
    let viewModel: BodegaListViewModel
    @Binding var filter: BodegaFilter
    @Binding var scrollID: Bodega.ID?
    var searchFocus: FocusState<Bool>.Binding
    let onAddBodega: () -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            // On the outer view rather than the `List` case alone, so the
            // search field stays put across the empty/no-matches states —
            // otherwise a search that matches nothing would remove the very
            // field needed to edit it.
            .searchable(text: $filter.searchText, prompt: "Name or address")
            .searchFocused(searchFocus)
            // Bodega names are proper nouns and slang: no auto-capitalised
            // first letter (the empty state echoes the query verbatim) and
            // no autocorrect fighting the spelling (#60).
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
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
            ContentUnavailableView {
                Label {
                    Text(AppCopy.emptyNoBodegasTitle.copy.text)
                } icon: {
                    EmptyStateCatSymbol()
                }
            } description: {
                Text(AppCopy.emptyNoBodegasBody.copy.text)
            } actions: {
                Button(AppCopy.addBodegaAction.copy.text, action: onAddBodega)
                    .buttonStyle(.bordered)
            }
        case .loaded where viewModel.filteredBodegas.isEmpty:
            noMatches
        case .loaded:
            List(viewModel.filteredBodegas) { bodega in
                NavigationLink(value: bodega) {
                    BodegaRow(bodega: bodega)
                }
            }
            .listStyle(.plain)
            .scrollPosition(id: $scrollID, anchor: .top)
        case .failed:
            // The raw error isn't shown (design DD5); Retry re-runs the
            // initial load.
            ContentUnavailableView {
                Label(AppCopy.emptyLoadFailedTitle.copy.text, systemImage: "exclamationmark.triangle")
            } description: {
                Text(AppCopy.emptyLoadFailedBody.copy.text)
            } actions: {
                Button(AppCopy.retryAction.copy.text) { viewModel.retry() }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// Distinct from the nothing-loaded state: there *are* bodegas, the
    /// filter just hides all of them. A search-only filter gets the search
    /// state (the search field's own clear button is the obvious way out);
    /// once any data-point toggle is involved, even alongside a search,
    /// that clear button alone wouldn't help, so this offers Clear Filters,
    /// which drops the toggles and keeps the search (design DD6).
    @ViewBuilder
    private var noMatches: some View {
        if filter.requiredAmenities.isEmpty {
            ContentUnavailableView {
                Label(
                    AppCopy.noSearchMatchesTitle(filter.trimmedSearchText).text,
                    systemImage: "magnifyingglass"
                )
            } description: {
                Text(AppCopy.emptyNoSearchMatchesBody.copy.text)
            }
        } else {
            ContentUnavailableView {
                Label(AppCopy.emptyNoFilterMatchesTitle.copy.text, systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(AppCopy.emptyNoFilterMatchesBody.copy.text)
            } actions: {
                Button(AppCopy.clearFiltersAction.copy.text) { filter = filter.clearingAmenities() }
                    .buttonStyle(.bordered)
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
