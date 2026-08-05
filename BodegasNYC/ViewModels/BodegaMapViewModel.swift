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

    private func recluster(region: MKCoordinateRegion) {
        displayItems = Self.cluster(loadedBodegas, visibleRegion: region)
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
        currentFetchGeneration += 1
        loadedBodegas.insert(bodega, at: 0)
        if let lastRegion {
            recluster(region: lastRegion)
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
