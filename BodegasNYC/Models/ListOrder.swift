import Foundation

/// The List tab's order (#81, spec D1): nearest first or newest first, chosen
/// in the Filters sheet's "List Order" section and remembered across launches
/// (`@AppStorage("listOrder")` in `BrowseView`). Not a filter: Clear Filters,
/// `BodegaFilter.activeCount` and the toolbar badge all ignore it.
///
/// `.nearest` falls back to `.newest` whenever the list has no pinned fix
/// (`BodegaListViewModel.orderingFix`). Newest first is the fetch order
/// (`created_at` descending from the server) with local additions in front:
/// insertion order, not a client-side timestamp sort (eng F1).
///
/// The raw values are the stored `UserDefaults` values; never rename them.
nonisolated enum ListOrder: String, CaseIterable, Identifiable, Sendable {
    case nearest
    case newest

    var id: Self { self }

    /// The stored value read back: anything unknown (a renamed case, a
    /// corrupted default) is nearest first, the default.
    init(storedValue: String) {
        self = ListOrder(rawValue: storedValue) ?? .nearest
    }

    /// The picker row's label.
    var label: AppCopy {
        switch self {
        case .nearest: .listOrderNearestLabel
        case .newest: .listOrderNewestLabel
        }
    }

    /// The Filters sheet's one footer line under "List Order" (design D2,
    /// D6), or nil with Newest First chosen. `isNearestOrdered` is whether the
    /// list holds a pinned fix (eng R4), not whether one exists, so the sheet
    /// never claims an order the list is not in. `canBePromptedForLocation`
    /// is the tips' mirror (`authorizationStatus == .notDetermined`): only
    /// then can the map's Locate Me still ask.
    static func sheetFooter(
        for order: ListOrder,
        isNearestOrdered: Bool,
        canBePromptedForLocation: Bool
    ) -> AppCopy? {
        guard order == .nearest else { return nil }
        if isNearestOrdered { return .listOrderActiveFootnote }
        return canBePromptedForLocation ? .listOrderNeedsLocationBody : .listOrderFallbackBody
    }
}
