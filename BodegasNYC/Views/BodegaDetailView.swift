import PhotosUI
import SwiftUI

/// Bodega detail: data points, hours, address, photo gallery, reviews, and
/// aggregate rating — plus an Add/Edit-review action, an Add-a-Photo
/// library picker in the gallery, and Flag-an-Issue (the bodega via a
/// button, a review or photo via its context menu).
///
/// Unlike `MapScreenView`/`BodegaListView`, this view legitimately owns its
/// `@State private var viewModel` rather than receiving one already-built —
/// each detail visit is a fresh `.navigationDestination` push with no
/// toggle-and-back scenario, so re-fetching current reviews/photos on every
/// fresh visit is the correct behavior, not stale-data reuse to avoid.
struct BodegaDetailView: View {
    @State private var viewModel: BodegaDetailViewModel
    @State private var addReviewViewModel: AddReviewViewModel?
    @State private var flagIssueViewModel: FlagIssueViewModel?
    @State private var addPhotoViewModel: AddPhotoViewModel?
    /// The gallery's `PhotosPicker` selection. Only a hand-off slot: the
    /// `.task(id:)` below loads its bytes into an `AddPhotoViewModel`, then
    /// clears it so picking the same photo again still registers as a change.
    @State private var pickedPhotoItem: PhotosPickerItem?
    @State private var photoLoadErrorMessage: String?
    /// Set by `FlagIssueView`'s `onSubmitted`, but only turned into the
    /// visible confirmation alert from the flag sheet's `onDismiss` —
    /// presenting an alert while the sheet is still animating away is
    /// dropped by SwiftUI ("already presenting").
    @State private var flagSubmittedPendingConfirmation = false
    @State private var showingFlagConfirmation = false
    @State private var editBodegaViewModel: AddBodegaViewModel?
    /// Set once the load has run `spinnerDelaySeconds`; see the overlay.
    @State private var showsSpinner = false
    private static let spinnerDelaySeconds: TimeInterval = 0.5
    private let bodegaService: BodegaService
    private let reviewService: ReviewService
    private let photoService: PhotoService
    private let flagService: FlagService
    let sessionStore: SessionStore
    /// Fired after an Edit Bodega save so `BrowseView` can update the same
    /// row on the map and list. This screen updates itself first, via its
    /// own view model — it never re-reads the `Bodega` it was pushed with.
    private let onBodegaUpdated: (Bodega) -> Void

    init(
        bodega: Bodega,
        bodegaService: BodegaService,
        reviewService: ReviewService,
        photoService: PhotoService,
        flagService: FlagService,
        sessionStore: SessionStore,
        onBodegaUpdated: @escaping (Bodega) -> Void
    ) {
        self.bodegaService = bodegaService
        self.reviewService = reviewService
        self.photoService = photoService
        self.flagService = flagService
        self.sessionStore = sessionStore
        self.onBodegaUpdated = onBodegaUpdated
        _viewModel = State(
            initialValue: BodegaDetailViewModel(
                bodega: bodega,
                reviewService: reviewService,
                photoService: photoService
            )
        )
    }

    /// The signed-in user's own review for this bodega, if any — `nil` both
    /// when signed out and when signed in with no review yet. Determines
    /// whether tapping the review button routes to Add vs. Edit; the DB's
    /// `unique (bodega_id, author_id)` constraint is what actually makes a
    /// second insert impossible, this is just picking the right request.
    private var myReview: Review? {
        guard let userID = sessionStore.currentUserID else { return nil }
        return viewModel.reviews.first { $0.authorId == userID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                DataPointsSection(bodega: viewModel.bodega)
                RatingSummaryView(averageRating: viewModel.averageRating, reviewCount: viewModel.reviews.count)
                if let hours = viewModel.bodega.hours {
                    HoursSection(hours: hours)
                }
                PhotoGallerySection(
                    photos: viewModel.photos,
                    urlFor: viewModel.photoURL(for:),
                    pickedItem: $pickedPhotoItem
                ) { photo in
                    presentFlagSheet(for: .photo(photo.id))
                }
                ReviewsSection(
                    reviews: viewModel.reviews,
                    hasCat: viewModel.bodega.hasCat,
                    currentUserID: sessionStore.currentUserID
                ) { review in
                    presentFlagSheet(for: .review(review.id))
                }
                HStack(spacing: 12) {
                    reviewActionButton
                    Button("Flag an Issue", systemImage: "flag") {
                        presentFlagSheet(for: .bodega(viewModel.bodega.id))
                    }
                    .buttonStyle(.bordered)
                }
                if case .failed(let message) = viewModel.loadState {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(viewModel.bodega.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // No sign-in check here — that happens on Save, same as
                // Submit in the review/flag/photo flows.
                Button("Edit") { presentEditBodegaSheet() }
            }
        }
        .task { viewModel.loadIfNeeded() }
        // Only a load still running after 0.5s shows the spinner, so the
        // page zooms out of its pin showing its content (#23 design 6A).
        .task {
            guard (try? await Task.sleep(for: .seconds(Self.spinnerDelaySeconds))) != nil else { return }
            showsSpinner = true
        }
        .overlay {
            if showsSpinner, viewModel.loadState == .loading {
                ProgressView()
            }
        }
        .sheet(item: $addReviewViewModel) { addReviewViewModel in
            AddReviewView(viewModel: addReviewViewModel, sessionStore: sessionStore) { review in
                viewModel.reviewWasSubmitted(review)
                self.addReviewViewModel = nil
            }
        }
        .sheet(item: $editBodegaViewModel) { editBodegaViewModel in
            AddBodegaView(viewModel: editBodegaViewModel, sessionStore: sessionStore) { updated in
                viewModel.bodegaWasUpdated(updated)
                onBodegaUpdated(updated)
                self.editBodegaViewModel = nil
            }
        }
        .task(id: pickedPhotoItem) { await loadPickedPhoto() }
        .sheet(item: $addPhotoViewModel) { addPhotoViewModel in
            AddPhotoView(viewModel: addPhotoViewModel, sessionStore: sessionStore) { photo in
                viewModel.photoWasAdded(photo)
                self.addPhotoViewModel = nil
            }
        }
        .alert(
            "Couldn't Load Photo",
            isPresented: Binding(
                get: { photoLoadErrorMessage != nil },
                set: { if !$0 { photoLoadErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoLoadErrorMessage ?? "")
        }
        .sheet(item: $flagIssueViewModel, onDismiss: {
            if flagSubmittedPendingConfirmation {
                flagSubmittedPendingConfirmation = false
                showingFlagConfirmation = true
            }
        }, content: { flagIssueViewModel in
            FlagIssueView(viewModel: flagIssueViewModel, sessionStore: sessionStore) { _ in
                flagSubmittedPendingConfirmation = true
                self.flagIssueViewModel = nil
            }
        })
        .alert("Thanks for the heads-up", isPresented: $showingFlagConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your flag was submitted.")
        }
    }

    /// Loads the picked library item's raw bytes and hands them to a fresh
    /// `AddPhotoViewModel`, which presents the confirm-and-upload sheet. No
    /// sign-in check here — that happens on Upload, same as Submit in the
    /// review/flag flows. `loadTransferable` does its work out of process,
    /// so awaiting it here doesn't block the main actor.
    private func loadPickedPhoto() async {
        guard let item = pickedPhotoItem else { return }
        do {
            let data = try await item.loadTransferable(type: Data.self)
            guard !Task.isCancelled else { return }
            if let data {
                addPhotoViewModel = AddPhotoViewModel(
                    bodegaId: viewModel.bodega.id,
                    imageData: data,
                    photoService: photoService,
                    sessionStore: sessionStore
                )
            } else {
                photoLoadErrorMessage = "That photo isn't available."
            }
        } catch {
            guard !Task.isCancelled else { return }
            photoLoadErrorMessage = error.localizedDescription
        }
        pickedPhotoItem = nil
    }

    /// Reuses the Add Bodega form, pre-filled from the bodega as currently
    /// shown (so a second edit starts from the first edit's result).
    private func presentEditBodegaSheet() {
        editBodegaViewModel = AddBodegaViewModel(
            coordinate: viewModel.bodega.coordinate,
            existingBodega: viewModel.bodega,
            bodegaService: bodegaService,
            sessionStore: sessionStore
        )
    }

    private func presentFlagSheet(for target: FlagTarget) {
        flagIssueViewModel = FlagIssueViewModel(target: target, flagService: flagService, sessionStore: sessionStore)
    }

    private var reviewActionButton: some View {
        Button(myReview == nil ? "Add a Review" : "Edit Your Review") {
            addReviewViewModel = AddReviewViewModel(
                bodegaId: viewModel.bodega.id,
                existingReview: myReview,
                reviewService: reviewService,
                sessionStore: sessionStore
            )
        }
        .buttonStyle(.bordered)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.bodega.name)
                .font(.display(.title))
            if let address = viewModel.bodega.address {
                Text(address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// `DataPointsSection` and `HoursSection` live in `BodegaDetailSections.swift`.

private struct RatingSummaryView: View {
    let averageRating: Double?
    let reviewCount: Int

    /// Renders nothing without a rating (design DD9): the reviews section
    /// owns the empty state, so "No reviews yet." isn't said twice.
    var body: some View {
        if let averageRating {
            HStack(spacing: 6) {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
                Text(String(format: "%.1f", averageRating))
                    .font(.headline)
                Text("(\(reviewCount) review\(reviewCount == 1 ? "" : "s"))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A detail section's empty state (design DD9): quiet title and body,
/// leading, no symbol, inside the section's own stack under its header and
/// actions.
private struct SectionEmptyState: View {
    let title: AppCopy
    let message: AppCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.copy.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(message.copy.text)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Always rendered (unlike before Add-a-Photo existed, when it hid itself
/// with no photos) so the "Add a Photo" picker is reachable on a bodega
/// with an empty gallery.
private struct PhotoGallerySection: View {
    let photos: [Photo]
    let urlFor: (Photo) -> URL?
    @Binding var pickedItem: PhotosPickerItem?
    let onFlag: (Photo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Photos").font(.headline)
                Spacer()
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label("Add a Photo", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.bordered)
            }
            if photos.isEmpty {
                SectionEmptyState(title: .emptyNoPhotosTitle, message: .emptyNoPhotosBody)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(photos) { photo in
                            AsyncImage(url: urlFor(photo)) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Color.secondary.opacity(0.2)
                            }
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contextMenu {
                                Button("Flag Photo", systemImage: "flag") { onFlag(photo) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ReviewsSection: View {
    let reviews: [Review]
    let hasCat: Bool
    let currentUserID: UUID?
    let onFlag: (Review) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reviews").font(.headline)
            if reviews.isEmpty {
                let empty = AppCopy.noReviews(hasCat: hasCat)
                SectionEmptyState(title: empty.title, message: empty.body)
            } else {
                ForEach(reviews) { review in
                    // No flag option on your own review — edit it instead
                    // (the "Edit Your Review" button below).
                    if review.authorId == currentUserID {
                        ReviewRow(review: review)
                    } else {
                        ReviewRow(review: review)
                            .contextMenu {
                                Button("Flag Review", systemImage: "flag") { onFlag(review) }
                            }
                    }
                }
            }
        }
    }
}

private struct ReviewRow: View {
    let review: Review

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: index < review.rating ? "star.fill" : "star")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
                Text(review.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let body = review.body {
                Text(body).font(.body)
            }
        }
    }
}
