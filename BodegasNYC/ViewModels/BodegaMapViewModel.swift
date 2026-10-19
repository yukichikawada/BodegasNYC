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
                loadedBodegas = bodegas
                loadState = .loaded
                if let lastRegion {
                    recluster(region: lastRegion)
                }
            } catch {
                guard generation == currentFetchGeneration else { return }
                loadState = .failed(error.localizedDescription)
            }
        }
    }

    /// Filters *before* clustering, so a cluster's count only ever reflects
    /// bodegas that actually match — clustering first and then hiding
    /// clusters would leave badges counting bodegas the user filtered out.
    private func recluster(region: MKCoordinateRegion) {
        let visible = filter.isActive ? loadedBodegas.filter(filter.matches) : loadedBodegas
        displayItems = Self.cluster(visible, visibleRegion: region)
    }

    /// Optimistically reflects a just-inserted bodega without a full
    /// refetch — see `AddBodegaViewModel`/`BrowseView`. Prepended to match
    /// `fetchAll`'s `created_at desc` ordering. Safe regardless of
    /// `loadState`: `MapScreenView` renders `displayItems` unconditionally,
    /// not gated on `loadState`.
    ///
    /// Bumps `currentFetchGeneration` for the same reason `refetch` does:
    /// placement mode can leave a `.nearby` refetch in flight (panning
    /// re-triggers one on every settle), and without this, that fetch's
    /// response landing after this prepend would silently overwrite
    /// `loadedBodegas`, discarding the just-added pin.
    func bodegaWasAdded(_ bodega: Bodega) {
        supersedeInFlightFetch()
        loadedBodegas.insert(bodega, at: 0)
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
    /// unrelated in-flight fetch isn't discarded for nothing.
    func bodegaWasUpdated(_ bodega: Bodega) {
        guard let index = loadedBodegas.firstIndex(where: { $0.id == bodega.id }) else { return }
        supersedeInFlightFetch()
        loadedBodegas[index] = bodega
        if let lastRegion {
            recluster(region: lastRegion)
        }
    }

    /// Bumps `currentFetchGeneration` so any in-flight fetch is dropped when
    /// it lands, and moves `.loading` to `.loaded`. The dropped fetch fails
    /// its generation check before it can set `loadState`, so without this
    /// the state would stay `.loading` forever. Setting `.loaded` here
    /// assumes we already hold a valid dataset. In practice the dropped
    /// fetch is a `.nearby` refetch after a pan, layered on data that is
    /// already loaded. (`BodegaListViewModel.supersedeInFlightFetch()`
    /// documents the one case where that assumption is weaker.)
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
