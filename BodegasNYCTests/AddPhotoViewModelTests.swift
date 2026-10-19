//
//  AddPhotoViewModelTests.swift
//  BodegasNYCTests
//
//  Follows AddReviewViewModelTests's pattern (MockURLProtocol-backed
//  PostgREST + Storage clients, makeTestAuthClient/makeTestSession for the
//  SessionStore side) and PhotoServiceTests's two-stub upload ordering.
//

import Auth
import Foundation
import Testing
import UIKit

@testable import BodegasNYC

extension NetworkingTests {

@Suite
@MainActor
struct AddPhotoViewModelTests {
    private static let bodegaID = UUID(uuidString: "8f14e45f-ceea-467e-adc9-15476f4eaa15")!
    private static let uploaderID = UUID(uuidString: "3fa85f64-5717-4562-b3fc-2c963f66afa6")!
    private static let photoID = UUID(uuidString: "c56a4180-65aa-42ec-a945-5fd21dec0538")!

    private static let storageJSON = """
    {"Key": "photos/placeholder.jpg", "Id": "some-object-id"}
    """

    private static let photoJSON = """
    {
      "id": "\(photoID.uuidString)",
      "bodega_id": "\(bodegaID.uuidString)",
      "uploaded_by": "\(uploaderID.uuidString)",
      "storage_path": "\(bodegaID.uuidString)/front-door.jpg",
      "is_hidden": false,
      "created_at": "2026-07-21T18:31:12.500000+00:00"
    }
    """

    /// A real, decodable PNG so `PhotoImageEncoder` succeeds inside submit().
    private static func makePNG() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return try #require(image.pngData())
    }

    private func makeViewModel(imageData: Data? = nil, session: Session?) throws -> AddPhotoViewModel {
        AddPhotoViewModel(
            bodegaId: Self.bodegaID,
            imageData: try imageData ?? Self.makePNG(),
            photoService: PhotoService(postgrest: makeTestPostgrestClient(), storage: makeTestStorageClient()),
            sessionStore: SessionStore(auth: try makeTestAuthClient(session: session))
        )
    }

    @Test func submitRequiresSignInWhenNoSessionAndSendsNoRequest() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeViewModel(session: nil)

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(viewModel.submissionState == .signInRequired)
        #expect(capturedRequest.get() == nil)
    }

    @Test func dismissSignInPromptResetsToIdleSoASecondSubmitReasksForSignIn() throws {
        let viewModel = try makeViewModel(session: nil)

        viewModel.submit()
        #expect(viewModel.submissionState == .signInRequired)

        viewModel.dismissSignInPrompt()
        #expect(viewModel.submissionState == .idle)

        viewModel.submit()
        #expect(viewModel.submissionState == .signInRequired)
    }

    @Test func dismissSignInPromptIsANoOpWhenNotCurrentlySignInRequired() throws {
        let viewModel = try makeViewModel(session: makeTestSession())

        viewModel.dismissSignInPrompt()

        #expect(viewModel.submissionState == .idle)
    }

    @Test func submitUploadsAJPEGToStorageThenInsertsTheRowAndLandsSubmitted() async throws {
        MockURLProtocol.reset()
        let capturedRequests = Captured<[URLRequest]>([])
        let record: @Sendable (URLRequest) -> Void = { request in
            capturedRequests.set(capturedRequests.get() + [request])
        }
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8), onRequest: record)
        MockURLProtocol.stub(body: Data(Self.photoJSON.utf8), onRequest: record)
        let viewModel = try makeViewModel(session: makeTestSession(userID: Self.uploaderID))

        viewModel.submit()
        #expect(viewModel.submissionState == .submitting)
        await viewModel.waitForPendingSubmitForTesting()

        guard case .submitted(let photo) = viewModel.submissionState else {
            Issue.record("expected .submitted, got \(viewModel.submissionState)")
            return
        }
        #expect(photo.id == Self.photoID)
        let requests = capturedRequests.get()
        #expect(requests.count == 2)
        let storagePath = try #require(requests.first?.url?.path)
        #expect(storagePath.contains("/storage/v1/object/photos/\(Self.bodegaID.uuidString)/"))
        #expect(storagePath.hasSuffix(".jpg"))
        #expect(requests.last?.url?.path == "/rest/v1/photos")
        #expect(requests.last?.httpMethod == "POST")
        let body = try #require(requests.last?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["bodega_id"] as? String == Self.bodegaID.uuidString)
        #expect(json["uploaded_by"] as? String == Self.uploaderID.uuidString)
        #expect((json["storage_path"] as? String)?.hasSuffix(".jpg") == true)
    }

    @Test func aFailedStorageUploadDrivesSubmissionStateToFailedWithoutInsertingARow() async throws {
        MockURLProtocol.reset()
        let capturedRequests = Captured<[URLRequest]>([])
        let record: @Sendable (URLRequest) -> Void = { request in
            capturedRequests.set(capturedRequests.get() + [request])
        }
        MockURLProtocol.stub(statusCode: 500, body: Data("{\"message\":\"boom\"}".utf8), onRequest: record)
        MockURLProtocol.stub(body: Data(Self.photoJSON.utf8), onRequest: record)
        let viewModel = try makeViewModel(session: makeTestSession())

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        guard case .failed = viewModel.submissionState else {
            Issue.record("expected .failed, got \(viewModel.submissionState)")
            return
        }
        #expect(capturedRequests.get().count == 1)
    }

    @Test func undecodableImageDataFailsWithoutSendingARequest() async throws {
        MockURLProtocol.reset()
        let capturedRequest = Captured<URLRequest?>(nil)
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8)) { request in
            capturedRequest.set(request)
        }
        let viewModel = try makeViewModel(imageData: Data("not an image".utf8), session: makeTestSession())

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(viewModel.submissionState == .failed(AddPhotoViewModel.unreadableImageMessage))
        #expect(capturedRequest.get() == nil)
    }
}

}
