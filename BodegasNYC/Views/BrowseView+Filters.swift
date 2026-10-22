import CoreLocation
import SwiftUI

// The Filters button and sheet, and the list's order (#81): what the sheet
// edits and when the list pins its order to a fix. Kept out of
// `BrowseView.swift` so that file stays within its length budget.

extension BrowseView {
    /// Filled icon plus a count badge whenever any filter (including a
    /// search typed on the List tab) is active — the only on-screen signal
    /// on the Map tab that pins are being hidden. Uses the system `.badge`,
    /// which iOS 26 draws on toolbar items (a count of 0 hides it). A
    /// hand-drawn overlay doesn't survive the iOS 26 toolbar: it renders
    /// only the label's icon, dropping the overlay and leaking its text
    /// into the button's accessibility label (#43). The list's order is not
    /// a filter and never counts (#81).
    var filterButton: some View {
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

    var filterSheet: some View {
        BodegaFilterSheet(
            filter: $filter,
            order: listOrderBinding,
            isNearestOrdered: listViewModel.orderingFix != nil,
            // The tips' mirror (`syncTipParameters()`), read live from the
            // client so the footer follows a grant made while the sheet is up.
            canBePromptedForLocation: locationPermissionClient.authorizationStatus == .notDetermined
        )
    }

    /// The stored order; an unknown stored value is nearest first.
    var listOrder: ListOrder { ListOrder(storedValue: listOrderRaw) }

    var listOrderBinding: Binding<ListOrder> {
        Binding(get: { listOrder }, set: { listOrderRaw = $0.rawValue })
    }

    var listOrderSync: ListOrderSync {
        ListOrderSync(
            viewModel: listViewModel,
            provider: userLocation,
            order: listOrder,
            showsList: activeTab == .list,
            scrollID: $listScrollID
        )
    }
}

/// Pushes the order into `BodegaListViewModel` and decides when the nearest
/// order is pinned to a fix (spec D2, eng R2): on List tab entry, on the
/// first attach, and on an order change, never on a re-appearance.
/// `BrowseView`'s root content re-appears after every pop, and a pin there
/// would reorder the list on the way back from a detail. That includes
/// `onChange(of:initial: true)`, whose initial action runs again on every
/// re-appearance (seen on the branch simulator: a pop after a moved fix
/// re-sorted the list), so the first attach is a one-shot `onAppear` behind
/// `hasAttached` instead. Every `usableFix` change goes to `noteFix`, which
/// adopts a first fix and un-pins on a loss.
///
/// Tab-entry pins run with animations disabled (design D4), so nothing
/// cross-fades inside the page slide. An order change clears the stored
/// scroll row: a different order has a different top row.
struct ListOrderSync: ViewModifier {
    let viewModel: BodegaListViewModel
    let provider: UserLocationProvider
    let order: ListOrder
    let showsList: Bool
    @Binding var scrollID: Bodega.ID?
    @State private var hasAttached = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !hasAttached else { return }
                hasAttached = true
                viewModel.order = order
                pinWithoutAnimation()
            }
            .onChange(of: order) { _, newOrder in
                viewModel.order = newOrder
                viewModel.pinOrderingFix(provider.usableFix)
                scrollID = nil
            }
            .onChange(of: showsList) { _, showsList in
                if showsList { pinWithoutAnimation() }
            }
            .onChange(of: provider.usableFix) { _, fix in
                viewModel.noteFix(fix)
            }
    }

    private func pinWithoutAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            viewModel.pinOrderingFix(provider.usableFix)
        }
    }
}
