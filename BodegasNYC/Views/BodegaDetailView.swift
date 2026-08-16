import SwiftUI

/// Bodega detail: data points, hours, address, photo gallery, reviews, and
/// aggregate rating — plus an Add/Edit-review action. Add-photo and
/// flag-an-issue remain separate follow-up slices, not built here.
///
/// Unlike `MapScreenView`/`BodegaListView`, this view legitimately owns its
/// `@State private var viewModel` rather than receiving one already-built —
/// each detail visit is a fresh `.navigationDestination` push with no
/// toggle-and-back scenario, so re-fetching current reviews/photos on every
/// fresh visit is the correct behavior, not stale-data reuse to avoid.
struct BodegaDetailView: View {
    @State private var viewModel: BodegaDetailViewModel
    @State private var addReviewViewModel: AddReviewViewModel?
    private let reviewService: ReviewService
    let sessionStore: SessionStore

    init(bodega: Bodega, reviewService: ReviewService, photoService: PhotoService, sessionStore: SessionStore) {
        self.reviewService = reviewService
        self.sessionStore = sessionStore
        _viewModel = State(
            initialValue: BodegaDetailViewModel(bodega: bodega, reviewService: reviewService, photoService: photoService)
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
                PhotoGallerySection(photos: viewModel.photos, urlFor: viewModel.photoURL(for:))
                ReviewsSection(reviews: viewModel.reviews)
                reviewActionButton
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
        .task { viewModel.loadIfNeeded() }
        .overlay {
            if viewModel.loadState == .loading {
                ProgressView()
            }
        }
        .sheet(item: $addReviewViewModel) { addReviewViewModel in
            AddReviewView(viewModel: addReviewViewModel, sessionStore: sessionStore) { review in
                viewModel.reviewWasSubmitted(review)
                self.addReviewViewModel = nil
            }
        }
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
                .font(.title2.bold())
            if let address = viewModel.bodega.address {
                Text(address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DataPointsSection: View {
    let bodega: Bodega

    private var points: [(label: String, systemImage: String, isPresent: Bool)] {
        [
            ("Cat", "cat", bodega.hasCat),
            ("Hot food", "flame", bodega.servesHotFood),
            ("Cigarettes", "smoke", bodega.sellsCigarettes),
            ("Beer", "mug", bodega.sellsBeer),
            ("Lotto", "ticket", bodega.sellsLotto)
        ]
    }

    var body: some View {
        HStack(spacing: 16) {
            ForEach(points, id: \.label) { point in
                VStack(spacing: 4) {
                    Image(systemName: point.systemImage)
                        .foregroundStyle(point.isPresent ? .primary : .secondary)
                        .opacity(point.isPresent ? 1 : 0.3)
                    Text(point.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct RatingSummaryView: View {
    let averageRating: Double?
    let reviewCount: Int

    var body: some View {
        HStack(spacing: 6) {
            if let averageRating {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
                Text(String(format: "%.1f", averageRating))
                    .font(.headline)
                Text("(\(reviewCount) review\(reviewCount == 1 ? "" : "s"))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No reviews yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HoursSection: View {
    let hours: BodegaHours

    private var orderedDays: [(label: String, dayHours: BodegaHours.DayHours?)] {
        [
            ("Mon", hours.mon), ("Tue", hours.tue), ("Wed", hours.wed), ("Thu", hours.thu),
            ("Fri", hours.fri), ("Sat", hours.sat), ("Sun", hours.sun)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hours").font(.headline)
            ForEach(orderedDays, id: \.label) { day in
                HStack {
                    Text(day.label).frame(width: 40, alignment: .leading)
                    Text(describe(day.dayHours))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }

    private func describe(_ dayHours: BodegaHours.DayHours?) -> String {
        guard let dayHours, !dayHours.isClosed else { return "Closed" }
        return "\(dayHours.open) – \(dayHours.close)"
    }
}

private struct PhotoGallerySection: View {
    let photos: [Photo]
    let urlFor: (Photo) -> URL?

    var body: some View {
        if !photos.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Photos").font(.headline)
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
                        }
                    }
                }
            }
        }
    }
}

private struct ReviewsSection: View {
    let reviews: [Review]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reviews").font(.headline)
            if reviews.isEmpty {
                Text("No reviews yet").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(reviews) { review in
                    ReviewRow(review: review)
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
