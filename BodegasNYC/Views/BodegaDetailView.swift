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
    /// The gallery's `PhotosPicker` selection (up to 10, in selection
    /// order). Only a hand-off slot: `.onChange` below turns it into an
    /// `AddPhotoViewModel`, which loads the picks, then clears it so picking
    /// the same photos again still registers as a change.
    @State private var pickedPhotoItems: [PhotosPickerItem] = []
    /// Photos that went up while the sheet is open. They join the gallery
    /// when it closes, so the insert is seen (design D16).
    @State private var uploadedWhileSheetOpen: [Photo] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @State private var openedFixtureUploadSheet = false
    #endif
    /// Set by `FlagIssueView`'s `onSubmitted`, but only turned into the
    /// visible confirmation alert from the flag sheet's `onDismiss` —
    /// presenting an alert while the sheet is still animating away is
    /// dropped by SwiftUI ("already presenting").
    @State private var flagSubmittedPendingConfirmation = false
    @State private var showingFlagConfirmation = false
    @State private var editBodegaViewModel: AddBodegaViewModel?
    /// The open photo viewer's snapshot (eng O3), `nil` while it is closed.
    @State private var photoViewerSession: PhotoViewerSession?
    /// The viewer's current photo, the return zoom's source.
    @State private var viewerPhotoID: Photo.ID?
    /// The gallery's scroll target: set only when the page changes inside
    /// the viewer, never at open (the tapped thumbnail is already on screen,
    /// and a scroll there would move the opening zoom's source; QA P3), so
    /// the thumbnail the return zoom lands on is on screen before it runs.
    @State private var galleryScrollTarget: Photo.ID?
    @Namespace private var photoNamespace
    /// VoiceOver focus goes back to the current photo's thumbnail when the
    /// viewer closes (design D19).
    @AccessibilityFocusState private var focusedPhotoID: Photo.ID?
    /// Set once the load has run `spinnerDelaySeconds`; see the overlay.
    @State private var showsSpinner = false
    private static let spinnerDelaySeconds: TimeInterval = 0.5
    private let bodegaService: BodegaService
    private let reviewService: ReviewService
    private let photoService: PhotoService
    private let flagService: FlagService
    let sessionStore: SessionStore
    /// The user's fix for the header's distance line (#68). `BrowseView`'s
    /// provider itself rather than a snapshot, so a fix that lands while the
    /// page is open fills the line in; `nil` (the default) shows no line.
    private let userLocation: UserLocationProvider?
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
        userLocation: UserLocationProvider? = nil,
        onBodegaUpdated: @escaping (Bodega) -> Void
    ) {
        self.userLocation = userLocation
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
                    pickedItems: $pickedPhotoItems,
                    namespace: photoNamespace,
                    scrollTarget: galleryScrollTarget,
                    insertTransition: PhotoMotion.insertStyle(reduceMotion: reduceMotion).transition,
                    focusedPhotoID: $focusedPhotoID,
                    onOpen: openPhotoViewer(at:)
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
                DetailButtonRow {
                    reviewActionButton
                    Button("Flag an Issue", systemImage: "flag") {
                        presentFlagSheet(for: .bodega(viewModel.bodega.id))
                    }
                    .buttonStyle(.bordered)
                }
                if case .failed(let message) = viewModel.loadState {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.primary)
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
            } onOpenExisting: { _ in }
        }
        .onChange(of: pickedPhotoItems) { _, items in presentAddPhotos(for: items) }
        #if DEBUG
        .task { openFixtureUploadSheetIfRequested() }
        #endif
        .sheet(item: $addPhotoViewModel, onDismiss: insertUploadedPhotos) { addPhotoViewModel in
            AddPhotoView(
                viewModel: addPhotoViewModel,
                bodegaName: viewModel.bodega.name,
                sessionStore: addPhotoViewModel.sessionStore
            ) { _ in
                self.addPhotoViewModel = nil
            }
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
        .alert(AppCopy.flagSubmittedTitle.copy.text, isPresented: $showingFlagConfirmation) {
            Button(AppCopy.okAction.copy.text, role: .cancel) {}
        } message: {
            Text(AppCopy.flagSubmittedBody.copy.text)
        }
        .fullScreenCover(item: $photoViewerSession, onDismiss: {
            focusedPhotoID = viewerPhotoID
        }, content: { session in
            PhotoViewer(
                items: PhotoViewerItem.gallery(session.photos, urlFor: viewModel.photoURL(for:)),
                currentID: Binding(
                    get: { viewerPhotoID ?? session.initialID },
                    set: { newID in
                        guard newID != viewerPhotoID else { return }
                        viewerPhotoID = newID
                        galleryScrollTarget = newID
                    }
                ),
                makeFlagViewModel: { photoID in
                    FlagIssueViewModel(target: .photo(photoID), flagService: flagService, sessionStore: sessionStore)
                },
                sessionStore: sessionStore
            )
            // The source follows the page, so closing zooms back into the
            // current photo's thumbnail. Under Reduce Motion the system
            // zoom is a crossfade.
            .navigationTransition(.zoom(sourceID: viewerPhotoID ?? session.initialID, in: photoNamespace))
        })
    }

    private func openPhotoViewer(at photo: Photo) {
        viewerPhotoID = photo.id
        // Cleared (the gallery ignores nil) so a page change back to the
        // last session's target still registers as a change.
        galleryScrollTarget = nil
        photoViewerSession = PhotoViewerSession(photos: viewModel.photos, initialID: photo.id)
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
                    .foregroundStyle(Color.textMuted)
            }
            distanceLine
        }
    }

    /// "2 blocks from you." under the address, or under the name when there
    /// is none, 4pt either way (#68). While location is authorized with full
    /// accuracy the line is reserved as an empty `.subheadline` line so the sections below
    /// never shift when the fix lands; the sentence fades in over it (design
    /// D2). Its own VoiceOver element after the address, not a header, and
    /// no monospaced digits on a sentence. Reads `viewModel.bodega`, so an
    /// Edit that moves the pin updates it.
    @ViewBuilder
    private var distanceLine: some View {
        let distance = viewModel.bodega.coordinate.blockDistance(from: userLocation?.usableFix)
        if distance != nil || userLocation?.reservesDistanceSlot == true {
            DistanceSlot(
                text: distance.map { AppCopy.distanceFromYou($0).text },
                placeholders: [" "],
                alignment: .leading
            )
            .font(.subheadline)
            .foregroundStyle(Color.textMuted)
        }
    }
}

// MARK: - Add Photos (#107 PR 2)

extension BodegaDetailView {
    /// Opens the Add Photos sheet the moment the picker closes (design D11),
    /// with one source per pick; the sheet's view model loads them one at a
    /// time (eng C1). No sign-in check here — that happens on Upload, same as
    /// Submit in the review/flag flows. `loadTransferable` does its work out
    /// of process, so awaiting it doesn't block the main actor.
    private func presentAddPhotos(for items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let sources: [AddPhotoViewModel.PhotoSource] = items.map { item in
            { try await item.loadTransferable(type: Data.self) }
        }
        pickedPhotoItems = []
        presentAddPhotos(sources: sources, sessionStore: sessionStore)
    }

    private func presentAddPhotos(
        sources: [AddPhotoViewModel.PhotoSource],
        sessionStore: SessionStore,
        itemIDs: [UUID]? = nil
    ) {
        uploadedWhileSheetOpen = []
        addPhotoViewModel = AddPhotoViewModel(
            bodegaId: viewModel.bodega.id,
            sources: sources,
            itemIDs: itemIDs,
            photoService: photoService,
            sessionStore: sessionStore
        ) { photo in
            uploadedWhileSheetOpen.append(photo)
        }
    }

    /// Photos join the gallery front in upload order, matching the server's
    /// `created_at desc`. A first pass uploads in reverse selection order,
    /// so the batch reads in selection order, unless a retry reorders it: a
    /// retried photo gets a newer `created_at` and comes first (accepted in
    /// the eng review). Then the row scrolls to its leading edge (design
    /// D16). Opacity only under Reduce Motion.
    private func insertUploadedPhotos() {
        let photos = uploadedWhileSheetOpen
        uploadedWhileSheetOpen = []
        guard !photos.isEmpty else { return }
        withAnimation(PhotoMotion.insertAnimation) {
            for photo in photos {
                viewModel.photoWasAdded(photo)
            }
        }
        // Through the gallery's one scroll target (set here and by page
        // changes in the viewer, never at open).
        galleryScrollTarget = viewModel.photos.first?.id
    }

    #if DEBUG
    /// `-UITestAddPhotos` (#107 eng O4): opens the sheet on the fixture
    /// bodega with three fixture photos and a signed-in fixture session, so
    /// a UI test can drive captions, removal, a failed upload and its retry
    /// without the system picker.
    private func openFixtureUploadSheetIfRequested() {
        guard UITestFixtures.opensAddPhotos, !openedFixtureUploadSheet else { return }
        openedFixtureUploadSheet = true
        presentAddPhotos(
            sources: UITestFixtures.addPhotoSources(),
            sessionStore: UITestFixtures.makeSignedInSessionStore(),
            itemIDs: UITestFixtures.addPhotoItemIDs
        )
    }
    #endif
}

// `DataPointsSection`, `HoursSection`, `ReviewRow` and `DetailButtonRow` live in
// `BodegaDetailSections.swift`.

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
                    .foregroundStyle(Color.textMuted)
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
                .foregroundStyle(Color.textMuted)
            Text(message.copy.text)
                .font(.footnote)
                .foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The open photo viewer's input (eng O3): the gallery as it was when a
/// thumbnail was tapped, and that thumbnail's photo.
private struct PhotoViewerSession: Identifiable {
    let id = UUID()
    let photos: [Photo]
    let initialID: Photo.ID
}

/// Always rendered (unlike before Add-a-Photo existed, when it hid itself
/// with no photos) so the "Add a Photo" picker is reachable on a bodega
/// with an empty gallery. Each thumbnail opens the full-screen viewer and
/// is its zoom transition's source (#107).
private struct PhotoGallerySection: View {
    /// DESIGN.md Shapes: `{rounded.md}` for photo thumbnails (design D20).
    private static let thumbnailRadius: CGFloat = 12
    private static let thumbnailSize: CGFloat = 120

    /// The picker's limit (#107 spec D1).
    static let maxPickCount = 10

    let photos: [Photo]
    let urlFor: (Photo) -> URL?
    @Binding var pickedItems: [PhotosPickerItem]
    let namespace: Namespace.ID
    /// Scrolled into view on change: the viewer's page (no animation: the
    /// gallery is under the cover while it changes), or the first photo
    /// after an upload, to the leading edge (design D16).
    let scrollTarget: Photo.ID?
    /// New thumbnails' insert transition (`PhotoMotion.InsertStyle`).
    let insertTransition: AnyTransition
    var focusedPhotoID: AccessibilityFocusState<Photo.ID?>.Binding
    let onOpen: (Photo) -> Void
    let onFlag: (Photo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailButtonRow {
                Text(AppCopy.photosSectionLabel.copy.text).font(.headline)
            } buttons: {
                PhotosPicker(
                    selection: $pickedItems,
                    maxSelectionCount: Self.maxPickCount,
                    selectionBehavior: .ordered,
                    matching: .images
                ) {
                    Label(AppCopy.addPhotoAction.copy.text, systemImage: "photo.badge.plus")
                }
                .buttonStyle(.bordered)
            }
            if photos.isEmpty {
                SectionEmptyState(title: .emptyNoPhotosTitle, message: .emptyNoPhotosBody)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                                thumbnail(photo, index: index)
                                    .transition(insertTransition)
                            }
                        }
                    }
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        if target == photos.first?.id {
                            // The leading edge: after an upload (design D16)
                            // this runs on screen, so it moves with the insert;
                            // under the viewer's cover the animation is unseen.
                            withAnimation(PhotoMotion.insertAnimation) { proxy.scrollTo(target, anchor: .leading) }
                        } else {
                            withoutAnimation { proxy.scrollTo(target, anchor: .center) }
                        }
                    }
                }
            }
        }
    }

    private func thumbnail(_ photo: Photo, index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.thumbnailRadius)
        return Button { onOpen(photo) } label: {
            AsyncImage(url: urlFor(photo)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: photo.id, in: namespace) { source in
            source.clipShape(shape)
        }
        .id(photo.id)
        .accessibilityLabel(AppCopy.photoPositionLabel(index: index, count: photos.count).text)
        .accessibilityValue(photo.caption ?? "")
        .accessibilityHint(AppCopy.photoOpensFullScreenHint.copy.text)
        .accessibilityFocused(focusedPhotoID, equals: photo.id)
        .contextMenu {
            Button(AppCopy.flagPhotoAction.copy.text, systemImage: "flag") { onFlag(photo) }
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
