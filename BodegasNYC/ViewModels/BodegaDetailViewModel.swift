import Foundation
import Observation

/// Owns a single bodega detail screen's data: reviews, photos, and the
/// aggregate rating derived from them. Takes an already-loaded `Bodega`
/// rather than fetching one by ID — there is no `fetchByID` on
/// `BodegaService` (nor any need for one), since detail is always reached
/// from a value already in memory via a map pin or list row selection.
@MainActor
@Observable
final class BodegaDetailViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Replaced (same id) by `bodegaWasUpdated(_:)` after an Edit Bodega
    /// save, so the header, data points, and hours re-render.
    private(set) var bodega: Bodega
    private(set) var loadState: LoadState = .idle
    private(set) var reviews: [Review] = []
    private(set) var photos: [Photo] = []

    private let reviewService: ReviewService
    private let photoService: PhotoService
    private var loadTask: Task<Void, Never>?

    init(bodega: Bodega, reviewService: ReviewService, photoService: PhotoService) {
        self.bodega = bodega
        self.reviewService = reviewService
        self.photoService = photoService
    }

    var averageRating: Double? { Self.computeAverageRating(from: reviews) }

    /// Safe to call on every view appearance — a no-op once `loadState` has
    /// moved past `.idle`. No fetch-generation guard needed here (unlike
    /// `BodegaMapViewModel`/`BodegaListViewModel`): `bodega.id` is fixed
    /// for this ViewModel's lifetime (`bodegaWasUpdated(_:)` only swaps in
    /// a newer copy of the same row), so there's no re-triggerable parameter
    /// that could cause two overlapping fetches to race — the `loadState`
    /// guard alone is sufficient.
    func loadIfNeeded() {
        guard loadState == .idle else { return }
        loadState = .loading

        loadTask = Task { [reviewService, photoService, bodega] in
            do {
                // Sequential, not concurrent (`async let`): MockURLProtocol's
                // stub queue is strict FIFO with no path-based matching, so a
                // concurrent pair of requests here would race to consume
                // stubs in a nondeterministic order in tests. The real-world
                // cost is one extra round-trip on an already-loading screen.
                let fetchedReviews = try await reviewService.fetchAll(bodegaId: bodega.id)
                let fetchedPhotos = try await photoService.fetchAll(bodegaId: bodega.id)
                reviews = fetchedReviews.filter { !$0.isHidden }
                photos = Self.mergingLocalPhotos(photos, into: fetchedPhotos.filter { !$0.isHidden })
                loadState = .loaded
            } catch {
                loadState = .failed(error.localizedDescription)
            }
        }
    }

    func photoURL(for photo: Photo) -> URL? {
        try? photoService.publicURL(for: photo)
    }

    /// Merges a just-submitted review into `reviews` in place (replace by
    /// id, else insert at the front) instead of re-fetching — keeps
    /// `averageRating` and the reviews list current without an extra round
    /// trip. Front-insertion matches `fetchAll`'s `created_at desc` order.
    func reviewWasSubmitted(_ review: Review) {
        if let index = reviews.firstIndex(where: { $0.id == review.id }) {
            reviews[index] = review
        } else {
            reviews.insert(review, at: 0)
        }
    }

    /// Prepends a just-uploaded photo into `photos` instead of re-fetching,
    /// mirroring `reviewWasSubmitted(_:)` — front-insertion matches
    /// `PhotoService.fetchAll`'s `created_at desc` order. A photo already
    /// present by id is left alone (photos have no editable fields, so
    /// there's nothing to replace).
    func photoWasAdded(_ photo: Photo) {
        guard !photos.contains(where: { $0.id == photo.id }) else { return }
        photos.insert(photo, at: 0)
    }

    /// The initial load's photos, keeping any photo added locally while the
    /// fetch was in flight that the fetch lacks, ahead of the fetched ones
    /// (#107 eng O2): an upload that finishes before the first load must not
    /// vanish when the load lands.
    nonisolated static func mergingLocalPhotos(_ local: [Photo], into fetched: [Photo]) -> [Photo] {
        let fetchedIDs = Set(fetched.map(\.id))
        return local.filter { !fetchedIDs.contains($0.id) } + fetched
    }

    /// Swaps in the server's copy of this bodega after an Edit Bodega save
    /// (the PATCH's `select().single()` response), instead of re-fetching.
    /// Ignores a bodega with a different id — this screen is for one row.
    func bodegaWasUpdated(_ updated: Bodega) {
        guard updated.id == bodega.id else { return }
        bodega = updated
    }

    /// Pure and independently testable. `nil` for zero reviews. Does not
    /// filter hidden reviews itself — that's `loadIfNeeded()`'s job; this
    /// function just averages whatever it's handed. Named distinctly from
    /// the `averageRating` instance property above rather than overloading
    /// that name statically — `Self.averageRating` would otherwise collide
    /// with the instance property of the same base name.
    nonisolated static func computeAverageRating(from reviews: [Review]) -> Double? {
        guard !reviews.isEmpty else { return nil }
        let total = reviews.reduce(0) { $0 + $1.rating }
        return Double(total) / Double(reviews.count)
    }

#if DEBUG
    func waitForPendingLoadForTesting() async {
        await loadTask?.value
    }
#endif
}
