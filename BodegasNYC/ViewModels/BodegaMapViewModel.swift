import CoreLocation
import MapKit
import Observation

/// Owns the map screen's bodega data: which browse mode is active
/// (`.all`/`.nearby`), the fetched bodegas, and the clustered
/// `MapDisplayItem`s actually rendered. Deliberately does not know about the
/// streets-walked heatmap (see `StreetsWalkedViewModel`) — the two are
/// composed at the view layer, sharing only camera/region state, since they
/// have entirely different data sources and lifecycles (an async Supabase
/// fetch here vs. background `CLLocationManager`/SwiftData there).
@MainActor
@Observable
final class BodegaMapViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var displayItems: [MapDisplayItem] = []
    /// Which pins show their name at block zoom (#67), written only by
    /// `updatePinLabels` (`BodegaMapViewModel+PinLabels.swift`).
    let pinLabels = PinLabelState()
    /// Bumped on every recluster: a cheap change signal for `displayItems`
    /// (#67), so the map does not compare the whole array on every update.
    private(set) var displayItemsVersion = 0
    /// Starts in `.all` so the screen has something to show with no
    /// location permission required — matches the PRD's "no upfront
    /// permission wall" requirement. Only switches to `.nearby` via an
    /// explicit call from `browseModeDidChange`, driven by a user action
    /// (the map's locate-me button), never automatically.
    private(set) var browseMode: BrowseMode = .all
    /// Narrows which of `loadedBodegas` get clustered into `displayItems` —
    /// pushed in from `BrowseView`, which owns the shared filter state.
    /// Changing it only reclusters what's already loaded; it never triggers
    /// a refetch, and `loadedBodegas` itself always holds the full,
    /// unfiltered fetch result so clearing the filter is instant.
    var filter: BodegaFilter = .none {
        didSet {
            guard filter != oldValue, let lastRegion else { return }
            recluster(region: lastRegion)
        }
    }

    /// The just-added bodega while its drop plays (eng review R7), set and
    /// cleared by `AddCompletionCoordinator`. `recluster` keeps it out of
    /// the filter and the clustering input and appends it as its own
    /// `.pin`, so a filter that doesn't match it, or a neighbour in the same
    /// grid cell, can't hide the pin the camera just flew to.
    var highlightedBodegaID: Bodega.ID? {
        didSet {
            guard highlightedBodegaID != oldValue, let lastRegion else { return }
            recluster(region: lastRegion)
        }
    }

    /// True only when a fetch has landed and returned no bodegas at all,
    /// before any filtering — the map's "nothing here" banners
    /// (`MapBottomCard`). False during the initial load, after a failure,
    /// and when a filter is what hides everything (that is
    /// `isFilteredEmpty`). Stays true while a later refetch (a `.nearby`
    /// pan, a mode change) is in flight — see `hasSettledData` — so the
    /// card doesn't slide out and back in on every pan. Computed so it can
    /// never drift from `loadState`/`loadedBodegas`.
    var isLoadedEmpty: Bool {
        hasSettledData && loadedBodegas.isEmpty
    }

    /// True when bodegas did load but the active filter matches none of
    /// them (design DD7). Decided by filtering alone, not by
    /// `displayItems`, so clustering or the visible region can't change it.
    /// Like `isLoadedEmpty`, it holds through a refetch after a completed
    /// load instead of flickering off while the fetch is in flight.
    var isFilteredEmpty: Bool {
        hasSettledData
            && !loadedBodegas.isEmpty
            && filter.isActive
            && !loadedBodegas.contains(where: filter.matches)
    }

    /// The filter the map card's Clear Filters should apply (#57), judged
    /// against everything loaded: see `BodegaFilter.clearingForMapCard(in:)`.
    func clearedFilterForMapCard(from filter: BodegaFilter) -> BodegaFilter {
        filter.clearingForMapCard(in: loadedBodegas)
    }

    private let bodegaService: BodegaService
    private var loadedBodegas: [Bodega] = []
    private var lastRegion: MKCoordinateRegion?
    private var fetchTask: Task<Void, Never>?
    /// Monotonic counter guarding against a stale fetch's result overwriting
    /// a newer one that happens to finish first — `Task.cancel()` alone
    /// only requests cooperative cancellation, it doesn't guarantee an
    /// already-in-flight response can't still land after a subsequent
    /// fetch's response does.
    private var currentFetchGeneration = 0
    /// Whether any fetch has succeeded yet. Until one has, local changes
    /// are buffered in `pendingLocalChanges` rather than superseding the
    /// in-flight fetch — see `isFirstFetchInFlight`.
    private var hasLoadedOnce = false
    private var pendingLocalChanges = PendingBodegaChanges()

    private static let nearbyRadiusRange: ClosedRange<Double> = 200...5000

    init(bodegaService: BodegaService) {
        self.bodegaService = bodegaService
    }

    /// Fetches once in `.all` mode if nothing has loaded yet. Safe to call
    /// on every view appearance — a no-op once `loadState` has moved past
    /// `.idle`. Takes the view's current camera region explicitly, rather
    /// than relying solely on `regionDidSettle` having already run at least
    /// once by the time this fetch resolves — `.task` and
    /// `.onMapCameraChange`'s initial callback aren't ordering-guaranteed
    /// relative to each other, and without this, a fetch that resolves
    /// first would have no region to recluster against and silently show
    /// no pins at all.
    func loadInitialIfNeeded(region: MKCoordinateRegion) {
        guard loadState == .idle else { return }
        if lastRegion == nil {
            lastRegion = region
        }
        refetch(mode: .all, region: lastRegion)
    }

    /// Called whenever the map's visible region settles (see
    /// `.onMapCameraChange(frequency: .onEnd)` in `MapScreenView`).
    /// Reclusters against whatever data is already loaded regardless of
    /// mode, and — only in `.nearby` mode — kicks off a fresh
    /// region-radius-scaled refetch.
    func regionDidSettle(_ region: MKCoordinateRegion) {
        lastRegion = region
        recluster(region: region)
        guard browseMode == .nearby else { return }
        refetch(mode: .nearby, region: region)
    }

    /// Driven by an explicit user action (locate-me tap), never by
    /// incidental panning — see `MapScreenView`.
    func browseModeDidChange(_ mode: BrowseMode, currentRegion: MKCoordinateRegion?) {
        guard mode != browseMode else { return }
        browseMode = mode
        if let currentRegion {
            lastRegion = currentRegion
        }
        refetch(mode: mode, region: lastRegion)
    }

    /// Locate Me's landing (#84): `.nearby` from now on, with no fetch around
    /// the old centre; the landing's settle (`regionDidSettle`) fetches
    /// around the block, so the bottom card changes once.
    func enterNearbyAtNextSettle() {
        browseMode = .nearby
    }

    private func refetch(mode: BrowseMode, region: MKCoordinateRegion?) {
        fetchTask?.cancel()
        currentFetchGeneration += 1
        let generation = currentFetchGeneration
        // Set synchronously, not inside the Task body: `loadInitialIfNeeded`
        // guards on `loadState == .idle` to stay a no-op on a second
        // back-to-back call, which only works if the state has already
        // moved off `.idle` by the time that second call's guard runs —
        // before the Task has had any chance to start executing.
        loadState = .loading
        // This fetch starts after every change buffered so far, so its
        // result already reflects them.
        pendingLocalChanges = PendingBodegaChanges()

        fetchTask = Task { [bodegaService] in
            do {
                let bodegas: [Bodega]
                if mode == .nearby, let region {
                    bodegas = try await bodegaService.fetchNearby(
                        latitude: region.center.latitude,
                        longitude: region.center.longitude,
                        radiusMeters: Self.radiusMeters(for: region)
                    )
                } else {
                    bodegas = try await bodegaService.fetchAll()
                }

                guard generation == currentFetchGeneration else { return }
                loadedBodegas = pendingLocalChanges.applied(to: bodegas)
                pendingLocalChanges = PendingBodegaChanges()
                hasLoadedOnce = true
                loadState = .loaded
                if let lastRegion {
                    recluster(region: lastRegion)
                }
            } catch {
                guard generation == currentFetchGeneration else { return }
                pendingLocalChanges = PendingBodegaChanges()
                loadState = .failed(error.localizedDescription)
            }
        }
    }

    /// Filters *before* clustering, so a cluster's count only ever reflects
    /// bodegas that actually match — clustering first and then hiding
    /// clusters would leave badges counting bodegas the user filtered out.
    ///
    /// The highlighted bodega (R7) skips both steps and goes last, so it is
    /// always its own pin. Going last does not put it above a neighbour to
    /// its south (MapKit stacks by screen position, see `drawOrdered`);
    /// `BodegaPinView` puts its label above the circle for that (#59).
    private func recluster(region: MKCoordinateRegion) {
        let highlighted = highlightedBodegaID.flatMap { id in loadedBodegas.first { $0.id == id } }
        let candidates = highlighted.map { pinned in loadedBodegas.filter { $0.id != pinned.id } } ?? loadedBodegas
        let visible = filter.isActive ? candidates.filter(filter.matches) : candidates
        var items = Self.cluster(visible, visibleRegion: region)
        if let highlighted {
            items.append(.pin(highlighted))
        }
        displayItems = items
        displayItemsVersion &+= 1
    }

    /// Optimistically reflects a just-inserted bodega without a full
    /// refetch — see `AddCompletionCoordinator`. Prepended to match
    /// `fetchAll`'s `created_at desc` ordering. Idempotent (eng review R6):
    /// if a refetch already landed with this row (a `.nearby` refetch after
    /// the camera settles on it), it is replaced in place, never doubled. Safe regardless of
    /// `loadState`: `MapScreenView` renders `displayItems` unconditionally,
    /// not gated on `loadState`.
    ///
    /// Bumps `currentFetchGeneration` for the same reason `refetch` does:
    /// placement mode can leave a `.nearby` refetch in flight (panning
    /// re-triggers one on every settle), and without this, that fetch's
    /// response landing after this prepend would silently overwrite
    /// `loadedBodegas`, discarding the just-added pin. The exception is the
    /// *first* fetch: with nothing loaded yet, dropping it would leave only
    /// this pin, so the row is buffered and merged into that fetch's result
    /// when it lands instead (issue #35).
    func bodegaWasAdded(_ bodega: Bodega) {
        if isFirstFetchInFlight {
            pendingLocalChanges.recordAdded(bodega)
        } else {
            supersedeInFlightFetch()
        }
        if let index = loadedBodegas.firstIndex(where: { $0.id == bodega.id }) {
            loadedBodegas[index] = bodega
        } else {
            loadedBodegas.insert(bodega, at: 0)
        }
        if let lastRegion {
            recluster(region: lastRegion)
        }
    }

    /// Reflects an Edit Bodega save without a full refetch: replaces the
    /// loaded bodega with the same id in place (keeping its position, since
    /// `created_at` ordering doesn't change on edit) and reclusters, which
    /// also re-applies any active filter to the edited data points. A no-op
    /// if that bodega isn't currently loaded (e.g. outside the `.nearby`
    /// radius) — it isn't on the map to update.
    ///
    /// Bumps `currentFetchGeneration` like `bodegaWasAdded`, so a fetch
    /// already in flight from before the save can't land afterward and put
    /// the pre-edit row back. Only when the bodega was found, so an
    /// unrelated in-flight fetch isn't discarded for nothing. During the
    /// first fetch the edit is buffered instead, so it wins over that
    /// fetch's (possibly pre-edit) copy of the row when it lands.
    func bodegaWasUpdated(_ bodega: Bodega) {
        let index = loadedBodegas.firstIndex(where: { $0.id == bodega.id })
        if isFirstFetchInFlight {
            pendingLocalChanges.recordUpdated(bodega)
        } else {
            guard index != nil else { return }
            supersedeInFlightFetch()
        }
        guard let index else { return }
        loadedBodegas[index] = bodega
        if let lastRegion {
            recluster(region: lastRegion)
        }
    }

    /// Whether `loadedBodegas` holds a real result to judge emptiness by:
    /// after a successful load, and during any refetch that follows one.
    /// `loadedBodegas` is only replaced when a fetch succeeds, so while a
    /// refetch is in flight it still holds the last result. False during
    /// the first load and after a failure.
    private var hasSettledData: Bool {
        loadState == .loaded || (loadState == .loading && hasLoadedOnce)
    }

    /// True while the fetch in flight would be the first dataset this view
    /// model holds, so there's nothing valid to fall back on if it were
    /// dropped.
    private var isFirstFetchInFlight: Bool {
        loadState == .loading && !hasLoadedOnce
    }

    /// Bumps `currentFetchGeneration` so any in-flight fetch is dropped when
    /// it lands, and moves `.loading` to `.loaded`. The dropped fetch fails
    /// its generation check before it can set `loadState`, so without this
    /// the state would stay `.loading` forever. Setting `.loaded` here
    /// assumes we already hold a valid dataset. In practice the dropped
    /// fetch is a `.nearby` refetch after a pan, layered on data that is
    /// already loaded. Never used during the first fetch, where that
    /// assumption doesn't hold — see `PendingBodegaChanges`.
    private func supersedeInFlightFetch() {
        currentFetchGeneration += 1
        if loadState == .loading {
            loadState = .loaded
        }
    }

    /// Derives a fetch radius from the visible region's span rather than a
    /// fixed constant, so "nearby" widens/narrows with zoom; clamped so
    /// extreme zoom levels don't request an absurdly small or large radius.
    private static func radiusMeters(for region: MKCoordinateRegion) -> Double {
        let center = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
        let northEdge = CLLocation(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude
        )
        let distance = center.distance(from: northEdge)
        return min(max(distance, nearbyRadiusRange.lowerBound), nearbyRadiusRange.upperBound)
    }

    /// `items` with the given bodega ids moved to the end, in their
    /// existing relative order. Pure, for `MapScreenView`.
    ///
    /// Weaker than its DD3 intent: MapKit stacks annotation views by screen
    /// position (lower on screen draws in front), not by declaration order,
    /// so this cannot lift a pin above a neighbour to its south (#59). The
    /// only effect seen live is at equal screen height, where the later
    /// annotation (the highlighted pin) drew on top; that test could not
    /// tell this ordering apart from MapKit adding the new pin last. Kept
    /// for those ties; removing it is a separate cleanup.
    nonisolated static func drawOrdered(_ items: [MapDisplayItem], frontIDs: Set<Bodega.ID>) -> [MapDisplayItem] {
        guard !frontIDs.isEmpty else { return items }
        func isFront(_ item: MapDisplayItem) -> Bool {
            if case .pin(let bodega) = item { return frontIDs.contains(bodega.id) }
            return false
        }
        return items.filter { !isFront($0) } + items.filter(isFront)
    }

#if DEBUG
    /// Test-only determinism hook: awaits the most recently started fetch so
    /// tests don't need to poll/sleep for the background `Task` to finish.
    /// Safe regardless of completion order between a superseded fetch and
    /// the one that replaced it — see `currentFetchGeneration`.
    func waitForPendingFetchForTesting() async {
        await fetchTask?.value
    }
#endif
}
