import SwiftUI
import TipKit
import UIKit

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
///
/// Distances (#68): `userFix` is `BrowseView`'s `UserLocationProvider`
/// fix (nil until a usable one lands) and `reservesDistanceSlot` whether
/// location is authorized; each row computes its own `BlockDistance`. While
/// location is not authorized the loaded list opens with `DistancesTip`,
/// whose Show Map runs `onShowMap`.
///
/// Order (#81): rows render in `viewModel.filteredBodegas` order (nearest
/// first from a pinned fix, else newest first). When the order changes the
/// rows cross-fade in place, keyed on `viewModel.reorderKey` (design D4):
/// 0.25s `easeInOut`, instant under Reduce Motion, never a row move. The
/// scroll phase goes to the view model, which holds an adopted fix until the
/// list is at rest. An order chosen in the Filters sheet scrolls to the top
/// (design D7); an automatic re-sort keeps the offset and, under VoiceOver
/// while `isForeground` (no sheet, no detail), keeps focus on the same
/// bodega (the new first row if focus was on the first) and announces
/// "Nearest first now." (design D3).
struct BodegaListView: View {
    let viewModel: BodegaListViewModel
    @Binding var filter: BodegaFilter
    @Binding var scrollID: Bodega.ID?
    var searchFocus: FocusState<Bool>.Binding
    var userFix: UserFix?
    var reservesDistanceSlot = false
    var isForeground = true
    let onAddBodega: () -> Void
    var onShowMap: () -> Void = {}

    /// `List` ignores `.scrollPosition(id:)`, so the top row is tracked by
    /// hand (#23): the top edge of each row on screen, kept in a plain
    /// reference so scrolling never re-renders the page, read when a scroll
    /// comes to rest.
    @State private var rowTops = RowTops()
    /// Set once the stored row has been scrolled back to.
    @State private var hasRestoredScroll = false
    @AccessibilityFocusState private var focusedRowID: Bodega.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            ScrollViewReader { proxy in
                List {
                    // The FormTip pattern: inline, first in the list, only
                    // when there are rows (#68, design D4).
                    TipView(DistancesTip()) { action in
                        if action.id == DistancesTip.showMapActionID { onShowMap() }
                    }
                    .inlineBodegaTipStyle()
                    .id(Self.tipRowID)
                    ForEach(viewModel.filteredBodegas) { bodega in
                        NavigationLink(value: bodega) {
                            BodegaRow(
                                bodega: bodega,
                                distance: bodega.coordinate.blockDistance(from: userFix),
                                reservesDistanceSlot: reservesDistanceSlot
                            )
                        }
                        .id(bodega.id)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                            rowTops.tops[bodega.id] = $0
                        }
                        // Off screen (or jumped past by a scrollTo): never the top.
                        .onDisappear { rowTops.tops[bodega.id] = nil }
                        .accessibilityFocused($focusedRowID, equals: bodega.id)
                    }
                    // A new order is a new set of rows, faded in where the
                    // old ones fade out, so nothing slides (design D4).
                    .id(viewModel.reorderKey)
                    .transition(.opacity)
                }
                .listStyle(.plain)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: BrowseMotion.ListOrder.reorderSeconds),
                    value: viewModel.reorderKey
                )
                // Where content stops hiding under the navigation bar: the
                // List's own top (its rows scroll on up behind the bar).
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                    rowTops.visibleTop = $0
                }

                .task { await restoreScroll(proxy) }
                // Each time a scroll comes to rest, remember the first row
                // whose top is in view.
                .onScrollPhaseChange { _, phase in
                    viewModel.scrollPhaseDidChange(isIdle: phase == .idle)
                    guard phase == .idle, hasRestoredScroll else { return }
                    // At the first row, store nil (the top of the list), so
                    // a round trip does not scroll an open tip off screen.
                    let top = rowTops.topRow(in: viewModel.filteredBodegas)
                    scrollID = top == viewModel.filteredBodegas.first?.id ? nil : top
                }
                // A list that leaves mid-scroll must not hold an adoption.
                .onDisappear { viewModel.scrollPhaseDidChange(isIdle: true) }
                .onChange(of: viewModel.order) { scrollToTop(proxy) }
                .onChange(of: viewModel.lastAutomaticReorder) { _, reorder in
                    if let reorder { announce(reorder) }
                }
            }
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

    /// Back to the row that was at the top when the page last left (same
    /// query; `BrowseView` clears it when the filter changes), then VoiceOver
    /// focus on that row (design review 18A).
    private func restoreScroll(_ proxy: ScrollViewProxy) async {
        let stored = scrollID.flatMap { id in viewModel.filteredBodegas.first { $0.id == id }?.id }
        if let stored {
            // Once now, so the page slides in close to the row, and again
            // once the slide has settled: until the List has applied its bar
            // insets, the first scroll lands the row behind the bar.
            await Task.yield()
            scrollWithoutAnimation(proxy, to: stored)
            try? await Task.sleep(for: .seconds(BrowseMotion.ListTransition.slideSeconds + 0.05))
            scrollWithoutAnimation(proxy, to: stored)
        }
        hasRestoredScroll = true
        if UIAccessibility.isVoiceOverRunning {
            focusedRowID = stored ?? viewModel.filteredBodegas.first?.id
        }
    }

    /// The inline tip's row, so the top of the list can be scrolled to
    /// while the tip is showing.
    private static let tipRowID = "distancesTip"

    /// An order chosen in the Filters sheet (design D7): the top of the
    /// list, without animation, under the cross-fade.
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if DistancesTip().shouldDisplay {
                proxy.scrollTo(Self.tipRowID, anchor: .top)
            } else if let first = viewModel.filteredBodegas.first?.id {
                proxy.scrollTo(first, anchor: .top)
            }
        }
    }

    /// An automatic re-sort to nearest (design D3), VoiceOver only and only
    /// with the list in front. The rows were rebuilt, so focus is put back by
    /// id once the cross-fade is done (on the new first row if it was on the
    /// first), then the announcement, at high priority so the focus move
    /// does not cut it off.
    private func announce(_ reorder: BodegaListViewModel.AutomaticReorder) {
        guard isForeground, UIAccessibility.isVoiceOverRunning else { return }
        let focused = focusedRowID
        let target = focused == reorder.previousFirstID ? viewModel.filteredBodegas.first?.id : focused
        Task {
            try? await Task.sleep(for: .seconds(BrowseMotion.ListOrder.reorderSeconds))
            if let target {
                focusedRowID = nil
                await Task.yield()
                focusedRowID = target
            }
            AddCompletionCoordinator.postHighPriorityAnnouncement(AppCopy.listOrderNearestAnnouncement.copy.text)
        }
    }

    private func scrollWithoutAnimation(_ proxy: ScrollViewProxy, to id: Bodega.ID) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(id, anchor: .top) }
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

/// Row top edges in global coordinates and the list's visible top edge. A
/// class on purpose: updating it while scrolling must not re-render.
private final class RowTops {
    var tops: [Bodega.ID: CGFloat] = [:]
    var visibleTop: CGFloat = 0

    func topRow(in bodegas: [Bodega]) -> Bodega.ID? {
        bodegas.first { (tops[$0.id] ?? -.infinity) >= visibleTop - 1 }?.id
    }
}
