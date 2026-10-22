import Foundation
import Observation

/// Owns the list screen's bodega data: a flat, unclustered fetch of
/// bodegas, decoupled from `BodegaMapViewModel` the same way the two are
/// already decoupled at the view layer — this one has no camera/region
/// concept to react to.
///
/// `.all`-only: the list fetches every row (one request, capped at 1,000 rows
/// by PostgREST's `max_rows`; see TODOS.md) and has no nearby fetch mode.
/// Nearest first (#81) is a client-side sort of that fetch by straight-line
/// distance from `orderingFix`, a fix pinned when the List tab is entered or
/// the order changes, so rows never move under the reader when a later fix
/// only changes the distances. Newest first is the fetch order (`created_at`
/// descending) with local additions in front: insertion order (eng F1).
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
    private(set) var bodegas: [Bodega] = [] {
        didSet { reorder() }
    }
    /// Pushed in from `BrowseView`, which owns the shared filter state.
    /// Changing it never refetches — see `filteredBodegas`.
    var filter: BodegaFilter = .none

    /// `orderedBodegas` narrowed by `filter`: order first, so a filter
    /// change never re-sorts. Filtered on read (cheap, and `@Observable`
    /// tracks `filter` through this getter); the sort itself is cached.
    var filteredBodegas: [Bodega] {
        filter.isActive ? orderedBodegas.filter(filter.matches) : orderedBodegas
    }

    /// `bodegas` in `order` (see `ordered(_:by:from:)`), recomputed only when
    /// `bodegas`, `order` or `orderingFix` changes, never on read: at the
    /// 1,000-row cap a sort is a thousand `CLLocation` distances, and
    /// `filteredBodegas` is read several times per render. A value-only fix
    /// changes none of the three, so it never re-sorts.
    private(set) var orderedBodegas: [Bodega] = []

#if DEBUG
    /// Test-only: how many distance sorts have run (a cache miss each).
    @ObservationIgnored private(set) var distanceSortCountForTesting = 0
#endif

    private func reorder() {
#if DEBUG
        if order == .nearest, orderingFix != nil { distanceSortCountForTesting += 1 }
#endif
        orderedBodegas = Self.ordered(bodegas, by: order, from: orderingFix)
    }

    // MARK: List order (#81)

    /// Pushed in from `BrowseView`, which persists it. Not a filter.
    var order: ListOrder = .nearest {
        didSet { if order != oldValue { reorder() } }
    }
    /// The fix the nearest order is computed from (spec D2): pinned on List
    /// tab entry and on an order change, adopted once when the first usable
    /// fix lands while none is pinned, cleared when the fix is lost. Never
    /// the live fix, so a later fix changes the rows' values, not their order.
    private(set) var orderingFix: UserFix? {
        didSet { if orderingFix != oldValue { reorder() } }
    }
    /// A fix adopted while the list was scrolling, applied at the next scroll
    /// rest (design D4): rows never cross-fade under a moving finger.
    @ObservationIgnored private var pendingAdoption: UserFix?
    @ObservationIgnored private var isScrollIdle = true
    /// The last automatic re-sort to nearest (an adopted fix, never a pin or
    /// an order change), for the list's VoiceOver announcement and focus
    /// (design D3). `previousFirstID` is the first row before it.
    private(set) var lastAutomaticReorder: AutomaticReorder?

    struct AutomaticReorder: Equatable {
        let serial: Int
        let previousFirstID: Bodega.ID?
    }

    /// What the order is computed from: changes only when the rows' order
    /// can (a pin, an adoption, a loss, an order change). The fix is carried
    /// only under `.nearest`, since newest first ignores it. `BodegaListView`
    /// keys its cross-fade on this.
    struct ReorderKey: Hashable {
        let order: ListOrder
        let fix: UserFix?
    }

    var reorderKey: ReorderKey {
        ReorderKey(order: order, fix: order == .nearest ? orderingFix : nil)
    }

    /// Pins the order to `fix` (spec D2), called on List tab entry and on an
    /// order change. Only a fix at most `UserLocationProvider.maxFixAge` old
    /// is pinned (eng R1); an older one pins nil, so the visit behaves like a
    /// cold start and adopts the fresh fix when the refresh lands it. This is
    /// a check at pin time, not a timer: the provider still evaluates expiry
    /// only inside `refresh()` (#68).
    func pinOrderingFix(_ fix: UserFix?, now: Date = Date()) {
        pendingAdoption = nil
        if let fix, now.timeIntervalSince(fix.timestamp) <= UserLocationProvider.maxFixAge {
            orderingFix = fix
        } else {
            orderingFix = nil
        }
    }

    /// Every `UserLocationProvider.usableFix` change. A lost fix (nil)
    /// un-pins at once, so the list falls back to newest first as the
    /// distances fade out; a fix while none is pinned is adopted (now, or at
    /// the next scroll rest); a fix while one is pinned is ignored.
    func noteFix(_ fix: UserFix?) {
        guard let fix else {
            pendingAdoption = nil
            orderingFix = nil
            return
        }
        guard orderingFix == nil else { return }
        if isScrollIdle {
            adopt(fix)
        } else {
            pendingAdoption = fix
        }
    }

    /// The list's scroll phase, reported by `BodegaListView` (idle also when
    /// the list leaves the screen). Applies a held adoption at rest.
    func scrollPhaseDidChange(isIdle: Bool) {
        isScrollIdle = isIdle
        guard isIdle, let pending = pendingAdoption else { return }
        pendingAdoption = nil
        adopt(pending)
    }

    private func adopt(_ fix: UserFix) {
        let previousFirstID = filteredBodegas.first?.id
        orderingFix = fix
        guard order == .nearest else { return }
        lastAutomaticReorder = AutomaticReorder(
            serial: (lastAutomaticReorder?.serial ?? 0) + 1,
            previousFirstID: previousFirstID
        )
    }

    /// `bodegas` in `order`. `.newest`, or `.nearest` without a fix, returns
    /// the array unchanged: the fetch order with local additions in front
    /// (eng F1). `.nearest` with a fix sorts by straight-line distance, then
    /// `createdAt` descending, then `id`, each distance computed once;
    /// `sorted` is not stable, so the key carries the whole tie-break.
    static func ordered(_ bodegas: [Bodega], by order: ListOrder, from fix: UserFix?) -> [Bodega] {
        guard order == .nearest, let fix else { return bodegas }
        return bodegas
            .map { (bodega: $0, meters: $0.coordinate.distance(to: fix.coordinate)) }
            .sorted { lhs, rhs in
                if lhs.meters != rhs.meters { return lhs.meters < rhs.meters }
                if lhs.bodega.createdAt != rhs.bodega.createdAt { return lhs.bodega.createdAt > rhs.bodega.createdAt }
                return lhs.bodega.id.uuidString < rhs.bodega.id.uuidString
            }
            .map(\.bodega)
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
