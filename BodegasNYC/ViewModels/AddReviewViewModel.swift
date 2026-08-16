import Foundation
import Observation

/// Drives the Add/Edit-review submit flow from `BodegaDetailView`. When
/// `existingReview` is non-nil (the signed-in user already has a review for
/// this bodega — `reviews`' DB-level `unique (bodega_id, author_id)`
/// constraint means a second insert would fail), `submit()` calls
/// `reviewService.update` instead of `.insert`; `BodegaDetailView` decides
/// which by looking up the current user's review before constructing this
/// view model. Otherwise mirrors `AddBodegaViewModel`'s sign-in-gated
/// `SubmissionState` pattern exactly.
@MainActor
@Observable
final class AddReviewViewModel: Identifiable {
    enum SubmissionState: Equatable {
        case idle
        case submitting
        case submitted(Review)
        /// No signed-in user at submit time — `AddReviewView` reacts to this
        /// by presenting `SignInView` inline, same as `AddBodegaViewModel`.
        case signInRequired
        case failed(String)
    }

    let id = UUID()
    let bodegaId: UUID
    let existingReview: Review?

    var rating: Int
    var body: String

    private(set) var submissionState: SubmissionState = .idle

    private let reviewService: ReviewService
    private let sessionStore: SessionStore
    private var submitTask: Task<Void, Never>?

    var isRatingValid: Bool { (1...5).contains(rating) }

    init(bodegaId: UUID, existingReview: Review?, reviewService: ReviewService, sessionStore: SessionStore) {
        self.bodegaId = bodegaId
        self.existingReview = existingReview
        self.reviewService = reviewService
        self.sessionStore = sessionStore
        self.rating = existingReview?.rating ?? 0
        self.body = existingReview?.body ?? ""
    }

    func submit() {
        guard isRatingValid else {
            submissionState = .failed("Please choose a star rating.")
            return
        }
        guard let userID = sessionStore.currentUserID else {
            submissionState = .signInRequired
            return
        }
        submitTask?.cancel()
        submissionState = .submitting
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        submitTask = Task { [reviewService, bodegaId, existingReview, rating, trimmedBody, userID] in
            do {
                let saved: Review
                if let existingReview {
                    saved = try await reviewService.update(
                        id: existingReview.id,
                        ReviewUpdate(rating: rating, body: trimmedBody.isEmpty ? nil : trimmedBody)
                    )
                } else {
                    saved = try await reviewService.insert(
                        NewReview(
                            bodegaId: bodegaId,
                            authorId: userID,
                            rating: rating,
                            body: trimmedBody.isEmpty ? nil : trimmedBody
                        )
                    )
                }
                guard !Task.isCancelled else { return }
                submissionState = .submitted(saved)
            } catch {
                guard !Task.isCancelled else { return }
                submissionState = .failed(error.localizedDescription)
            }
        }
    }

    /// Called when the nested `SignInView` sheet is dismissed — resets state
    /// back to `.idle` so a subsequent Submit tap is a fresh transition. See
    /// `AddBodegaViewModel.dismissSignInPrompt()` for the full rationale.
    func dismissSignInPrompt() {
        guard submissionState == .signInRequired else { return }
        submissionState = .idle
    }

#if DEBUG
    func waitForPendingSubmitForTesting() async {
        await submitTask?.value
    }
#endif
}
