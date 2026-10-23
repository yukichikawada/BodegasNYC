import Foundation
import Observation
import UIKit

/// Drives the Add Photos sheet (#107 PR 2): up to 10 picks, one row each
/// with an optional caption, uploaded one at a time. Constructed as soon as
/// the picker closes, with one source per pick; the sheet opens at once with
/// a placeholder row per pick and `loadPickedPhotos()` fills them in.
///
/// The sign-in gate sits on Upload, as before (and as Submit in
/// `AddReviewViewModel`): a signed-out user picks, captions, then sees the
/// sign-in sheet; items and captions live on this object, so they survive it.
///
/// Item state machine (eng review diagram):
///
///     preparing ─▶ idle ─▶ uploading ─▶ uploaded(Photo)
///         │          ▲          │
///         │          │          └──▶ failed ─▶ uploading (retry)
///         └─▶ dropped (counted in `unloadableCount`)
///
/// A caption is editable only while its item is idle and has never started
/// an upload (eng O1): once the first attempt starts it is locked, even if
/// the attempt fails, because a retry may find the first attempt's row
/// (eng A1) and an edit would be silently lost. Idle and failed rows can be
/// removed while no pass is running.
@MainActor
@Observable
final class AddPhotoViewModel: Identifiable {
    /// Loads one pick's bytes (`PhotosPickerItem.loadTransferable` in the
    /// app). `nil` or a throw counts the pick as unloadable.
    typealias PhotoSource = @Sendable () async throws -> Data?

    enum ItemState: Equatable {
        /// Its bytes are loading or being encoded; a placeholder row.
        case preparing
        case idle
        case uploading
        case uploaded(Photo)
        case failed
    }

    struct Item: Identifiable {
        /// Made at pick time; also the Storage name and the `photos.id`
        /// (eng A1), so a retry never duplicates.
        let id: UUID
        /// The ≤1600px upload JPEG; `nil` while preparing (eng C1: the
        /// original bytes are dropped once this exists).
        var jpeg: Data?
        var thumbnail: UIImage?
        var caption = ""
        var state: ItemState = .preparing
        /// Set when its first upload attempt starts; locks the caption.
        var hasAttemptedUpload = false

        var isCaptionEditable: Bool { state == .idle && !hasAttemptedUpload }
        var isRemovable: Bool { state == .idle || state == .failed }
        /// Not uploaded (yet): what Cancel or Done would discard.
        var isUnsent: Bool {
            if case .uploaded = state { return false }
            return true
        }

        var uploadedPhoto: Photo? {
            if case .uploaded(let photo) = state { return photo }
            return nil
        }
    }

    enum SubmissionState: Equatable {
        case idle
        case submitting
        /// A pass ended with at least one failed item; Upload reads "Retry N".
        case partiallyFailed
        /// Nothing left to send: every remaining item uploaded (the photos,
        /// in selection order), or every item was removed before any upload
        /// (empty). The sheet dismisses.
        case submitted([Photo])
        /// No signed-in user at submit time — `AddPhotoView` reacts to this
        /// by presenting `SignInView` inline, same as `AddReviewViewModel`.
        case signInRequired
    }

    /// The sheet's leading button (design D10).
    enum LeadingAction: Equatable {
        case cancel
        case stop
        case done
    }

    /// "Uploading 3 of 8.": zero-based `index` within this pass's `count`.
    struct PassProgress: Equatable {
        let index: Int
        let count: Int
    }

    /// The DB check is `char_length(caption) between 1 and 140`.
    nonisolated static let captionLimit = 140
    /// The counter shows from here (design D9).
    nonisolated static let captionCounterThreshold = 120
    /// A row thumbnail is 64pt; a lone pick gets the large preview (design
    /// D12), up to 360pt tall at 3x.
    static let rowThumbnailLongEdge: CGFloat = PhotoImageEncoder.thumbnailLongEdge
    static let singlePreviewLongEdge: CGFloat = 1080

    /// The alert body when no pick could be read; the load step owns it now
    /// (eng C1), not submit.
    static var unreadableImageMessage: String { AppCopy.photoUnreadableBody.copy.text }

    let id = UUID()
    let bodegaId: UUID
    /// How many photos were picked. Exactly one shows the large preview
    /// layout, and stays that way; removing rows down to one keeps the list
    /// (design D12).
    let pickedCount: Int

    private(set) var items: [Item]
    private(set) var submissionState: SubmissionState = .idle
    /// Picks dropped because they couldn't be loaded or decoded.
    private(set) var unloadableCount = 0
    /// Set when the load step finished with nothing usable: the sheet shows
    /// the "Couldn't load" alert and closes.
    private(set) var loadFailedEntirely = false
    private(set) var passProgress: PassProgress?

    private let sources: [PhotoSource]
    private let photoService: PhotoService
    /// Also what the sheet's sign-in prompt signs in to.
    let sessionStore: SessionStore
    private let onUploaded: (Photo) -> Void
    private var hasStartedLoading = false
    private var stopRequested = false
    private var loadTask: Task<Void, Never>?
    private var submitTask: Task<Void, Never>?

    /// `onUploaded` fires once per photo as it goes up, so a partial batch
    /// reaches the gallery even if the user leaves with Done. `itemIDs`
    /// (one per source) fixes the ids for tests and the DEBUG upload fixture;
    /// otherwise each pick gets a fresh UUID.
    init(
        bodegaId: UUID,
        sources: [PhotoSource],
        itemIDs: [UUID]? = nil,
        photoService: PhotoService,
        sessionStore: SessionStore,
        onUploaded: @escaping (Photo) -> Void = { _ in }
    ) {
        precondition(itemIDs == nil || itemIDs?.count == sources.count, "one item id per source")
        self.bodegaId = bodegaId
        self.sources = sources
        self.pickedCount = sources.count
        self.items = (itemIDs ?? sources.map { _ in UUID() }).map { Item(id: $0) }
        self.photoService = photoService
        self.sessionStore = sessionStore
        self.onUploaded = onUploaded
    }

    // MARK: Derived state

    var isPreparing: Bool { items.contains { $0.state == .preparing } }
    var isSubmitting: Bool { submissionState == .submitting }
    var showsSinglePhotoLayout: Bool { pickedCount == 1 }
    var uploadedPhotos: [Photo] { items.compactMap(\.uploadedPhoto) }
    var failedCount: Int { items.filter { $0.state == .failed }.count }
    var unsentCount: Int { items.filter(\.isUnsent).count }

    var leadingAction: LeadingAction {
        if isSubmitting { return .stop }
        return uploadedPhotos.isEmpty ? .cancel : .done
    }

    /// Cancel or Done asks before throwing away typed captions (design D10).
    var needsDiscardConfirmation: Bool {
        items.contains { $0.isUnsent && Self.normalizedCaption($0.caption) != nil }
    }

    var canSubmit: Bool {
        !isSubmitting
            && !isPreparing
            && items.contains { $0.state == .idle || $0.state == .failed }
            && !items.contains { Self.isOverLimit($0.caption) }
    }

    // MARK: Captions

    /// Trimmed of whitespace and newlines; empty becomes `nil` (stored NULL).
    nonisolated static func normalizedCaption(_ caption: String) -> String? {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Counted in Unicode scalars after trimming, which is what Postgres
    /// `char_length` counts for UTF-8 text. The counter and the disabled
    /// state both use this.
    nonisolated static func captionLength(_ caption: String) -> Int {
        normalizedCaption(caption)?.unicodeScalars.count ?? 0
    }

    nonisolated static func isOverLimit(_ caption: String) -> Bool {
        captionLength(caption) > captionLimit
    }

    /// Classifies a caption field edit (design D14): a single Return
    /// keystroke (exactly one newline inserted, nothing else changed) keeps
    /// the old text and asks the sheet to move focus on; anything else,
    /// including a paste with newlines, passes through (`setCaption` joins
    /// its newlines with spaces) and keeps focus.
    nonisolated static func captionEdit(from old: String, to new: String) -> (caption: String, isReturnKey: Bool) {
        guard new.contains(where: \.isNewline) else { return (new, false) }
        if new.count == old.count + 1, let newline = new.firstIndex(where: \.isNewline) {
            var withoutNewline = new
            withoutNewline.remove(at: newline)
            if withoutNewline == old { return (old, true) }
        }
        return (new, false)
    }

    /// Ignored for a locked caption (eng O1). Newlines become spaces: the
    /// field wraps visually, and Return moves to the next field (design D14).
    func setCaption(_ caption: String, for itemID: Item.ID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }), items[index].isCaptionEditable else { return }
        // By Character, so "\r\n" is one break, not two.
        items[index].caption = caption
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .joined(separator: " ")
    }

    // MARK: Loading (eng C1)

    /// Loads the picks one at a time, in selection order: each pick's bytes
    /// go straight to `PhotoImageEncoder` off the main actor and are dropped
    /// once the upload JPEG and the thumbnail exist. A pick that can't be
    /// loaded or decoded drops out and is counted. Runs once.
    func loadPickedPhotos() async {
        guard !hasStartedLoading else {
            await loadTask?.value
            return
        }
        hasStartedLoading = true
        let task = Task { await prepareAll() }
        loadTask = task
        await task.value
    }

    private func prepareAll() async {
        let longEdge = showsSinglePhotoLayout ? Self.singlePreviewLongEdge : Self.rowThumbnailLongEdge
        for (source, itemID) in zip(sources, items.map(\.id)) {
            var prepared: PhotoImageEncoder.Prepared?
            if let data = try? await source() {
                prepared = await Task.detached(priority: .userInitiated) {
                    PhotoImageEncoder.prepare(data, thumbnailLongEdge: longEdge)
                }.value
            }
            guard !Task.isCancelled else { return }
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { continue }
            if let prepared {
                items[index].jpeg = prepared.jpeg
                items[index].thumbnail = prepared.thumbnail
                items[index].state = .idle
            } else {
                items.remove(at: index)
                unloadableCount += 1
            }
        }
        if items.isEmpty, unloadableCount > 0 {
            loadFailedEntirely = true
        }
    }

    // MARK: Upload

    /// Uploads every idle and failed item, one at a time, in reverse
    /// selection order, so `created_at desc` shows the batch in selection
    /// order. Already uploaded items are skipped.
    func submit() {
        guard canSubmit else { return }
        guard let userID = sessionStore.currentUserID else {
            submissionState = .signInRequired
            return
        }
        stopRequested = false
        submissionState = .submitting
        let queue = Array(items.filter { $0.state == .idle || $0.state == .failed }.map(\.id).reversed())
        let count = queue.count
        submitTask = Task { [photoService, bodegaId] in
            for (position, itemID) in queue.enumerated() {
                guard !stopRequested, !Task.isCancelled else { break }
                guard let index = items.firstIndex(where: { $0.id == itemID }),
                      let jpeg = items[index].jpeg else { continue }
                passProgress = PassProgress(index: position, count: count)
                let caption = Self.normalizedCaption(items[index].caption)
                items[index].hasAttemptedUpload = true
                items[index].state = .uploading
                let result: ItemState
                do {
                    let photo = try await photoService.upload(
                        id: itemID, bodegaId: bodegaId, uploadedBy: userID, data: jpeg, caption: caption
                    )
                    onUploaded(photo)
                    result = .uploaded(photo)
                } catch {
                    result = .failed
                }
                if let index = items.firstIndex(where: { $0.id == itemID }) {
                    items[index].state = result
                }
            }
            passProgress = nil
            finishPass()
        }
    }

    /// The current item finishes; nothing after it starts. Items that never
    /// started stay idle and editable (design D10).
    func stop() {
        guard isSubmitting else { return }
        stopRequested = true
    }

    /// Allowed for idle and failed items while no pass runs.
    func remove(itemID: Item.ID) {
        guard !isSubmitting,
              let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].isRemovable else { return }
        items.remove(at: index)
        guard !isPreparing else { return }
        if !items.contains(where: { $0.state == .idle || $0.state == .failed }) {
            // Nothing left to send: done with what went up, or with nothing.
            submissionState = .submitted(uploadedPhotos)
        } else if submissionState == .partiallyFailed, failedCount == 0 {
            submissionState = .idle
        }
    }

    private func finishPass() {
        if failedCount > 0 {
            submissionState = .partiallyFailed
        } else if !items.contains(where: { $0.state == .idle || $0.state == .preparing }), !uploadedPhotos.isEmpty {
            submissionState = .submitted(uploadedPhotos)
        } else {
            submissionState = .idle
        }
    }

    /// Called when the nested `SignInView` sheet is dismissed — resets state
    /// back to `.idle` so a subsequent Upload tap is a fresh transition. See
    /// `AddBodegaViewModel.dismissSignInPrompt()` for the full rationale.
    func dismissSignInPrompt() {
        guard submissionState == .signInRequired else { return }
        submissionState = failedCount > 0 ? .partiallyFailed : .idle
    }

#if DEBUG
    func waitForPendingSubmitForTesting() async {
        await submitTask?.value
    }
#endif
}
