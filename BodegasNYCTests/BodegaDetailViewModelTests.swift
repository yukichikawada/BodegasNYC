//
//  BodegaDetailViewModelTests.swift
//  BodegasNYCTests
//
//  Networking-touching cases are nested under NetworkingTests (shared
//  MockURLProtocol stub queue, serialized suite). The pure
//  computeAverageRating(from:) logic is covered separately below as a
//  standalone top-level suite, since it touches no networking.
//

import Foundation
import Testing

@testable import BodegasNYC

extension NetworkingTests {

@Suite
@MainActor
struct BodegaDetailViewModelTests {
    private static let bodegaID = UUID(uuidString: "8f14e45f-ceea-467e-adc9-15476f4eaa15")!
    private static let authorID = UUID(uuidString: "3fa85f64-5717-4562-b3fc-2c963f66afa6")!

    private static func reviewJSON(rating: Int, isHidden: Bool = false) -> String {
        """
        {
          "id": "\(UUID().uuidString)",
          "bodega_id": "\(bodegaID.uuidString)",
          "author_id": "\(authorID.uuidString)",
          "rating": \(rating),
          "body": "Great spot",
          "is_hidden": \(isHidden),
          "created_at": "2026-07-21T18:30:00+00:00",
          "updated_at": "2026-07-21T18:30:00+00:00"
        }
        """
    }

    private static func photoJSON(isHidden: Bool = false) -> String {
        """
        {
          "id": "\(UUID().uuidString)",
          "bodega_id": "\(bodegaID.uuidString)",
          "uploaded_by": "\(authorID.uuidString)",
          "storage_path": "\(bodegaID.uuidString)/front-door.jpg",
          "is_hidden": \(isHidden),
          "created_at": "2026-07-21T18:31:12.500000+00:00"
        }
        """
    }

    private func makeViewModel() throws -> BodegaDetailViewModel {
        let bodega = try makeTestBodega(id: Self.bodegaID, latitude: 40.7291, longitude: -73.9965)
        return BodegaDetailViewModel(
            bodega: bodega,
            reviewService: ReviewService(postgrest: makeTestPostgrestClient()),
            photoService: PhotoService(postgrest: makeTestPostgrestClient(), storage: makeTestStorageClient())
        )
    }

    @Test func loadIfNeededFetchesReviewsThenPhotosAndComputesAverageRating() async throws {
        MockURLProtocol.reset()
        let capturedRequests = Captured<[URLRequest]>([])
        let record: @Sendable (URLRequest) -> Void = { request in
            capturedRequests.set(capturedRequests.get() + [request])
        }
        // Queued in fetch order: reviews first, then photos — see the
        // sequential-fetch note on BodegaDetailViewModel.loadIfNeeded().
        MockURLProtocol.stub(body: Data("[\(Self.reviewJSON(rating: 3)), \(Self.reviewJSON(rating: 5))]".utf8), onRequest: record)
        MockURLProtocol.stub(body: Data("[\(Self.photoJSON())]".utf8), onRequest: record)
        let viewModel = try makeViewModel()

        viewModel.loadIfNeeded()
        #expect(viewModel.loadState == .loading)
        await viewModel.waitForPendingLoadForTesting()

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.reviews.count == 2)
        #expect(viewModel.photos.count == 1)
        #expect(viewModel.averageRating == 4.0)
        let requests = capturedRequests.get()
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/rest/v1/reviews")
        #expect(requests[1].url?.path == "/rest/v1/photos")
    }

    @Test func loadIfNeededFiltersOutHiddenReviewsAndPhotos() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.reviewJSON(rating: 1, isHidden: true)), \(Self.reviewJSON(rating: 5))]".utf8))
        MockURLProtocol.stub(body: Data("[\(Self.photoJSON(isHidden: true)), \(Self.photoJSON())]".utf8))
        let viewModel = try makeViewModel()

        viewModel.loadIfNeeded()
        await viewModel.waitForPendingLoadForTesting()

        #expect(viewModel.reviews.count == 1)
        #expect(viewModel.photos.count == 1)
        #expect(viewModel.averageRating == 5.0)
    }

    @Test func aFailedReviewsFetchDrivesLoadStateToFailedWithoutFetchingPhotos() async throws {
        MockURLProtocol.reset()
        let capturedRequests = Captured<[URLRequest]>([])
        let record: @Sendable (URLRequest) -> Void = { request in
            capturedRequests.set(capturedRequests.get() + [request])
        }
        MockURLProtocol.stub(statusCode: 500, body: Data("{\"message\":\"boom\"}".utf8), onRequest: record)
        MockURLProtocol.stub(body: Data("[\(Self.photoJSON())]".utf8), onRequest: record)
        let viewModel = try makeViewModel()

        viewModel.loadIfNeeded()
        await viewModel.waitForPendingLoadForTesting()

        guard case .failed = viewModel.loadState else {
            Issue.record("expected .failed, got \(viewModel.loadState)")
            return
        }
        #expect(capturedRequests.get().count == 1)
    }

    @Test func loadIfNeededIsANoOpOnceAlreadyLoading() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[\(Self.reviewJSON(rating: 5))]".utf8))
        MockURLProtocol.stub(body: Data("[]".utf8))
        let viewModel = try makeViewModel()

        viewModel.loadIfNeeded()
        viewModel.loadIfNeeded()
        await viewModel.waitForPendingLoadForTesting()

        #expect(viewModel.loadState == .loaded)
    }

    @Test func reviewWasSubmittedInsertsANewReviewAtTheFront() throws {
        let viewModel = try makeViewModel()
        let existing = try Review(
            id: UUID(),
            bodegaId: Self.bodegaID,
            authorId: UUID(),
            rating: 3,
            body: nil,
            isHidden: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        viewModel.reviewWasSubmitted(existing)

        let newReview = Review(
            id: UUID(),
            bodegaId: Self.bodegaID,
            authorId: Self.authorID,
            rating: 5,
            body: "Great spot",
            isHidden: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        viewModel.reviewWasSubmitted(newReview)

        #expect(viewModel.reviews.count == 2)
        #expect(viewModel.reviews.first?.id == newReview.id)
        #expect(viewModel.averageRating == 4.0)
    }

    @Test func reviewWasSubmittedReplacesAnExistingReviewByID() throws {
        let viewModel = try makeViewModel()
        let original = Review(
            id: UUID(),
            bodegaId: Self.bodegaID,
            authorId: Self.authorID,
            rating: 2,
            body: "Meh",
            isHidden: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        viewModel.reviewWasSubmitted(original)

        let edited = Review(
            id: original.id,
            bodegaId: Self.bodegaID,
            authorId: Self.authorID,
            rating: 5,
            body: "Actually great",
            isHidden: false,
            createdAt: original.createdAt,
            updatedAt: Date()
        )
        viewModel.reviewWasSubmitted(edited)

        #expect(viewModel.reviews.count == 1)
        #expect(viewModel.reviews.first?.rating == 5)
        #expect(viewModel.reviews.first?.body == "Actually great")
    }

    @Test func photoWasAddedPrependsTheNewPhotoAndIgnoresADuplicate() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data("[]".utf8))
        MockURLProtocol.stub(body: Data("[\(Self.photoJSON())]".utf8))
        let viewModel = try makeViewModel()
        viewModel.loadIfNeeded()
        await viewModel.waitForPendingLoadForTesting()
        let existingID = try #require(viewModel.photos.first?.id)

        let newPhoto = Photo(
            id: UUID(),
            bodegaId: Self.bodegaID,
            uploadedBy: Self.authorID,
            storagePath: "\(Self.bodegaID.uuidString)/new.jpg",
            isHidden: false,
            createdAt: Date()
        )
        viewModel.photoWasAdded(newPhoto)
        viewModel.photoWasAdded(newPhoto)

        #expect(viewModel.photos.map(\.id) == [newPhoto.id, existingID])
    }

    @Test func bodegaWasUpdatedReplacesTheBodegaWithTheSameID() throws {
        let viewModel = try makeViewModel()
        var edited = viewModel.bodega
        edited.name = "Renamed Deli"
        edited.sellsBeer = true
        edited.hours = BodegaHours(mon: .init(open: "7:00", close: "23:00"))

        viewModel.bodegaWasUpdated(edited)

        #expect(viewModel.bodega == edited)
    }

    @Test func bodegaWasUpdatedIgnoresADifferentBodega() throws {
        let viewModel = try makeViewModel()
        let original = viewModel.bodega

        viewModel.bodegaWasUpdated(try makeTestBodega(name: "Some Other Deli"))

        #expect(viewModel.bodega == original)
    }
}

}

/// Pure logic, no networking — standalone top-level suite per this
/// codebase's convention (see `BodegaClusteringTests`).
@Suite
struct BodegaDetailViewModelAverageRatingTests {
    @Test func averageOfMultipleReviews() throws {
        let reviews = try [3, 4, 5].map {
            Review(
                id: UUID(),
                bodegaId: UUID(),
                authorId: UUID(),
                rating: $0,
                body: nil,
                isHidden: false,
                createdAt: Date(),
                updatedAt: Date()
            )
        }

        #expect(BodegaDetailViewModel.computeAverageRating(from: reviews) == 4.0)
    }

    @Test func nilForNoReviews() {
        #expect(BodegaDetailViewModel.computeAverageRating(from: []) == nil)
    }

    @Test func doesNotFilterHiddenReviewsItself() {
        // Filtering hidden reviews is loadIfNeeded()'s job, not this pure
        // function's — a hidden review passed in directly still counts.
        let hidden = Review(
            id: UUID(),
            bodegaId: UUID(),
            authorId: UUID(),
            rating: 1,
            body: nil,
            isHidden: true,
            createdAt: Date(),
            updatedAt: Date()
        )

        #expect(BodegaDetailViewModel.computeAverageRating(from: [hidden]) == 1.0)
    }
}
