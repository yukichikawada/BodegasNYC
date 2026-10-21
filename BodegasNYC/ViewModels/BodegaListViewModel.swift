import Foundation
import Observation

/// Owns the list screen's bodega data: a flat, unclustered fetch of
/// bodegas, decoupled from `BodegaMapViewModel` the same way the two are
/// already decoupled at the view layer — this one has no camera/region
/// concept to react to.
///
/// `.all`-only for now: the one-shot fix a nearby mode would need exists
/// (`LocationPermissionClient.requestCurrentFix()`, read by
/// `UserLocationProvider` for the rows' distances, #68), but the list still
/// has no nearby mode or nearest-first sort; that is the follow-up.
@MainActor
@Observable
final class BodegaListViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle
    /// The full, unfiltered fetch result. `BodegaListView` renders
    /// `filteredBodegas`; this stays whole so it can still tell "nothing
    /// loaded" apart from "nothing matches the filter".
    private(set) var bodegas: [Bodega] = []
    /// Pushed in from `BrowseView`, which owns the shared filter state.
    /// Changing it never refetches — see `filteredBodegas`.
    var filter: BodegaFilter = .none

    /// `bodegas` narrowed by `filter`, recomputed on read rather than cached:
    /// `@Observable` tracks both `bodegas` and `filter` through this getter,
    /// so the view re-renders on either changing with no stored copy to keep
    /// in sync (e.g. through `bodegaWasAdded`'s prepend).
    var filteredBodegas: [Bodega] {
        filter.isActive ? bodegas.filter(filter.matches) : bodegas
    }

    private let bodegaService: BodegaService
    private var fetchTask: Task<Void, Never>?
    /// Guards against a stale fetch's result overwriting a newer one — same
    /// rationale as `BodegaMapViewModel.currentFetchGeneration`, kept even
    /// though there's currently only one call site (`loadInitialIfNeeded`),
    /// as cheap insurance against a future manual-refresh action racing it.
    private var currentFetchGeneration = 0
    /// Whether any fetch has succeeded yet. Until one has, local changes
    /// are buffered in `pendingLocalChanges` rather than superseding the
    /// in-flight fetch — see `isFirstFetchInFlight`.
    private var hasLoadedOnce = false
    private var pendingLocalChanges = PendingBodegaChanges()

    init(bodegaService: BodegaService) {
        self.bodegaService = bodegaService
    }

    /// Safe to call on every view appearance — a no-op once `loadState` has
    /// moved past `.idle`.
    func loadInitialIfNeeded() {
        guard loadState == .idle else { return }
        refetch()
    }

    /// The load-failed empty state's Retry (design DD5): re-runs the same
    /// initial-load path by moving `.failed` back to `.idle`. A no-op in
    /// any other state, so a stray tap can't restart a load in progress or
    /// throw away loaded rows.
    func retry() {
        guard case .failed = loadState else { return }
        loadState = .idle
        loadInitialIfNeeded()
    }

    /// Optimistically reflects a just-inserted bodega without a full
    /// refetch — mirrors `BodegaMapViewModel.bodegaWasAdded`. Once data has
    /// loaded, this bumps `currentFetchGeneration` so an already-in-flight
    /// refetch can't land afterward and silently overwrite this prepend.
    /// During the *first* fetch it instead buffers the row and lets that
    /// fetch land, merging the row into its result (issue #35) — dropping
    /// the fetch would leave the list holding only this one bodega. Note:
    /// if `loadState` is currently `.failed`, `BodegaListView` still
    /// renders the failure state regardless of `bodegas`' contents — a
    /// known, accepted gap.
    func bodegaWasAdded(_ bodega: Bodega) {
        if isFirstFetchInFlight {
            pendingLocalChanges.recordAdded(bodega)
        } else {
            supersedeInFlightFetch()
        }
        // Idempotent (eng review R6): a fetch that already brought this row
        // back keeps one copy, updated in place.
        if let index = bodegas.firstIndex(where: { $0.id == bodega.id }) {
            bodegas[index] = bodega
        } else {
            bodegas.insert(bodega, at: 0)
        }
    }

    /// Reflects an Edit Bodega save without a full refetch: replaces the
    /// bodega with the same id in place (edits don't change `created_at`
    /// ordering). A no-op if it isn't loaded, except during the first
    /// fetch, when the edit is buffered so it wins over that fetch's
    /// (possibly pre-edit) copy of the row. Otherwise bumps
    /// `currentFetchGeneration` for the same reason as
    /// `BodegaMapViewModel.bodegaWasUpdated`, and only when found.
    func bodegaWasUpdated(_ bodega: Bodega) {
        let index = bodegas.firstIndex(where: { $0.id == bodega.id })
        if isFirstFetchInFlight {
            pendingLocalChanges.recordUpdated(bodega)
        } else {
            guard index != nil else { return }
            supersedeInFlightFetch()
        }
        if let index {
            bodegas[index] = bodega
        }
    }

    /// True while the fetch in flight would be the first dataset this view
    /// model holds, so there's nothing valid to fall back on if it were
    /// dropped.
    private var isFirstFetchInFlight: Bool {
        loadState == .loading && !hasLoadedOnce
    }

    /// Same as `BodegaMapViewModel.supersedeInFlightFetch()`: drops any
    /// in-flight fetch and moves `.loading` to `.loaded`, so the spinner
    /// can't be stranded by a fetch whose result is now ignored. Only used
    /// once a fetch has succeeded; during the first fetch, local changes go
    /// through `pendingLocalChanges` instead.
    private func supersedeInFlightFetch() {
        currentFetchGeneration += 1
        if loadState == .loading {
            loadState = .loaded
        }
    }

    private func refetch() {
        fetchTask?.cancel()
        currentFetchGeneration += 1
        let generation = currentFetchGeneration
        loadState = .loading
        // This fetch starts after every change buffered so far, so its
        // result already reflects them.
        pendingLocalChanges = PendingBodegaChanges()

        fetchTask = Task { [bodegaService] in
            do {
                let fetched = try await bodegaService.fetchAll()
                guard generation == currentFetchGeneration else { return }
                bodegas = pendingLocalChanges.applied(to: fetched)
                pendingLocalChanges = PendingBodegaChanges()
                hasLoadedOnce = true
                loadState = .loaded
            } catch {
                guard generation == currentFetchGeneration else { return }
                pendingLocalChanges = PendingBodegaChanges()
                loadState = .failed(error.localizedDescription)
            }
        }
    }

#if DEBUG
    /// Test-only determinism hook, mirroring `BodegaMapViewModel`'s.
    func waitForPendingFetchForTesting() async {
        await fetchTask?.value
    }
#endif
}
