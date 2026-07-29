import Foundation
import Observation

/// Owns the list screen's bodega data: a flat, unclustered fetch of
/// bodegas, decoupled from `BodegaMapViewModel` the same way the two are
/// already decoupled at the view layer — this one has no camera/region
/// concept to react to.
///
/// `.all`-only for now. Unlike the map, which never actually asks
/// `LocationPermissionClient` for a location fix — it piggybacks entirely on
/// MapKit's own camera-follow to get a region to derive a fetch radius from
/// — a list has no such mechanism, and `LocationPermissionClient` today only
/// bridges authorization status, not an actual coordinate. Building a real
/// "nearby" mode here needs a genuine new one-shot location-fix capability
/// there first (e.g. a `CLLocationManager.requestLocation()` bridge), which
/// is out of proportion for this slice. Follow-up: add that capability,
/// then give this a `BrowseMode` toggle mirroring `BodegaMapViewModel`'s.
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
    private(set) var bodegas: [Bodega] = []

    private let bodegaService: BodegaService
    private var fetchTask: Task<Void, Never>?
    /// Guards against a stale fetch's result overwriting a newer one — same
    /// rationale as `BodegaMapViewModel.currentFetchGeneration`, kept even
    /// though there's currently only one call site (`loadInitialIfNeeded`),
    /// as cheap insurance against a future manual-refresh action racing it.
    private var currentFetchGeneration = 0

    init(bodegaService: BodegaService) {
        self.bodegaService = bodegaService
    }

    /// Safe to call on every view appearance — a no-op once `loadState` has
    /// moved past `.idle`.
    func loadInitialIfNeeded() {
        guard loadState == .idle else { return }
        refetch()
    }

    private func refetch() {
        fetchTask?.cancel()
        currentFetchGeneration += 1
        let generation = currentFetchGeneration
        loadState = .loading

        fetchTask = Task { [bodegaService] in
            do {
                let fetched = try await bodegaService.fetchAll()
                guard generation == currentFetchGeneration else { return }
                bodegas = fetched
                loadState = .loaded
            } catch {
                guard generation == currentFetchGeneration else { return }
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
