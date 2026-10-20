import Foundation

/// Local adds/edits made while a view model's *first* fetch is still in
/// flight, held so they can be merged into that fetch's result when it
/// lands instead of one side discarding the other (issue #35).
///
/// Only used before any dataset has loaded. Once one has, `bodegaWasAdded`
/// / `bodegaWasUpdated` keep superseding an in-flight refetch instead (see
/// `supersedeInFlightFetch()` in both view models): the data already held
/// is a valid base to stay on, which isn't true of an empty initial state.
struct PendingBodegaChanges {
    /// Newest first, matching `fetchAll`'s `created_at desc` ordering.
    private(set) var added: [Bodega] = []
    /// Edits to rows that weren't added locally, keyed by id.
    private(set) var updated: [UUID: Bodega] = [:]

    mutating func recordAdded(_ bodega: Bodega) {
        added.removeAll { $0.id == bodega.id }
        added.insert(bodega, at: 0)
    }

    /// An edit to a locally added row replaces it in `added`, so it stays
    /// at the front rather than being tracked twice.
    mutating func recordUpdated(_ bodega: Bodega) {
        if let index = added.firstIndex(where: { $0.id == bodega.id }) {
            added[index] = bodega
        } else {
            updated[bodega.id] = bodega
        }
    }

    /// `fetched` with local edits applied in place (the local version wins
    /// over the fetched one) and locally added rows at the front. A row that
    /// was added locally and also came back in `fetched` appears once, as
    /// the local version. An edit to a row `fetched` doesn't contain is
    /// dropped: there's nothing on screen for it to update.
    func applied(to fetched: [Bodega]) -> [Bodega] {
        let addedIDs = Set(added.map(\.id))
        let rest = fetched
            .filter { !addedIDs.contains($0.id) }
            .map { updated[$0.id] ?? $0 }
        return added + rest
    }
}
