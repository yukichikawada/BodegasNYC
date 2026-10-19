import Foundation
import Observation

/// Drives the Add-a-Photo confirm-and-upload flow from `BodegaDetailView`.
/// Constructed only once the user has already picked an image — the
/// `PhotosPicker` lives on the detail view and hands this view model the
/// picked bytes — so the sign-in gate sits on Upload, exactly like Submit
/// in `AddReviewViewModel`: a signed-out user sees the picker, then the
/// sign-in sheet. Otherwise mirrors `AddReviewViewModel`'s sign-in-gated
/// `SubmissionState` pattern exactly.
@MainActor
@Observable
final class AddPhotoViewModel: Identifiable {
    enum SubmissionState: Equatable {
        case idle
        case submitting
        case submitted(Photo)
        /// No signed-in user at submit time — `AddPhotoView` reacts to this
        /// by presenting `SignInView` inline, same as `AddReviewViewModel`.
        case signInRequired
        case failed(String)
    }

    /// Shown when `PhotoImageEncoder` can't decode the picked bytes.
    static let unreadableImageMessage = "Couldn't read that image. Try a different photo."

    let id = UUID()
    let bodegaId: UUID
    /// The picked photo exactly as the library handed it over (any format,
    /// full resolution). Downscaled and JPEG-encoded at submit time, off the
    /// main actor.
    let imageData: Data

    private(set) var submissionState: SubmissionState = .idle

    private let photoService: PhotoService
    private let sessionStore: SessionStore
    private var submitTask: Task<Void, Never>?

    init(bodegaId: UUID, imageData: Data, photoService: PhotoService, sessionStore: SessionStore) {
        self.bodegaId = bodegaId
        self.imageData = imageData
        self.photoService = photoService
        self.sessionStore = sessionStore
    }

    func submit() {
        guard let userID = sessionStore.currentUserID else {
            submissionState = .signInRequired
            return
        }
        submitTask?.cancel()
        submissionState = .submitting
        submitTask = Task { [photoService, bodegaId, imageData, userID] in
            // Detached so the decode/redraw/encode of a full-size photo runs
            // on the global executor, not on the main actor this Task
            // otherwise inherits.
            let jpeg = await Task.detached(priority: .userInitiated) {
                PhotoImageEncoder.encode(imageData)
            }.value
            guard !Task.isCancelled else { return }
            guard let jpeg else {
                submissionState = .failed(Self.unreadableImageMessage)
                return
            }
            do {
                let photo = try await photoService.upload(
                    bodegaId: bodegaId,
                    uploadedBy: userID,
                    data: jpeg,
                    fileExtension: "jpg",
                    contentType: "image/jpeg"
                )
                guard !Task.isCancelled else { return }
                submissionState = .submitted(photo)
            } catch {
                guard !Task.isCancelled else { return }
                submissionState = .failed(error.localizedDescription)
            }
        }
    }

    /// Called when the nested `SignInView` sheet is dismissed — resets state
    /// back to `.idle` so a subsequent Upload tap is a fresh transition. See
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
