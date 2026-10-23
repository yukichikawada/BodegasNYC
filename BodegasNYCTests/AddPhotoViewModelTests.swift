//
//  AddPhotoViewModelTests.swift
//  BodegasNYCTests
//
//  The Add Photos sheet's view model (#107 PR 2). Follows
//  AddReviewViewModelTests's pattern (MockURLProtocol-backed PostgREST +
//  Storage clients, makeTestAuthClient/makeTestSession for the SessionStore
//  side). MockURLProtocol's queue is strict FIFO, and uploads are sequential
//  (storage then insert, per item), so stubs are queued in request order.
//
//  Picks are fed as `PhotoSource` closures returning generated PNG bytes, so
//  the real ImageIO load step (eng C1) runs. Item ids are fixed so the
//  request paths and insert bodies can be matched to items.
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
    private static let itemIDs = (1...3).map { UUID(uuidString: "c56a4180-65aa-42ec-a945-5fd21dec053\($0)")! }

    private static let storageJSON = """
    {"Key": "photos/placeholder.jpg", "Id": "some-object-id"}
    """

    private static func photoJSON(id: UUID, caption: String? = nil) -> String {
        let captionJSON = caption.map { "\"\($0)\"" } ?? "null"
        return """
        {
          "id": "\(id.uuidString)",
          "bodega_id": "\(bodegaID.uuidString)",
          "uploaded_by": "\(uploaderID.uuidString)",
          "storage_path": "\(bodegaID.uuidString)/\(id.uuidString).jpg",
          "is_hidden": false,
          "caption": \(captionJSON),
          "created_at": "2026-07-21T18:31:12.500000+00:00"
        }
        """
    }

    /// A real, decodable PNG so the load step's ImageIO encode succeeds.
    private static func makePNG() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return try #require(image.pngData())
    }

    private static func pngSource() throws -> AddPhotoViewModel.PhotoSource {
        let png = try makePNG()
        return { png }
    }

    private func makeViewModel(
        sources: [AddPhotoViewModel.PhotoSource],
        session: Session?,
        onUploaded: @escaping (Photo) -> Void = { _ in }
    ) throws -> AddPhotoViewModel {
        AddPhotoViewModel(
            bodegaId: Self.bodegaID,
            sources: sources,
            itemIDs: Array(Self.itemIDs.prefix(sources.count)),
            photoService: PhotoService(postgrest: makeTestPostgrestClient(), storage: makeTestStorageClient()),
            sessionStore: SessionStore(auth: try makeTestAuthClient(session: session)),
            onUploaded: onUploaded
        )
    }

    /// A loaded view model with `count` decodable picks.
    private func makeLoadedViewModel(
        count: Int,
        session: Session? = makeTestSession(userID: AddPhotoViewModelTests.uploaderID),
        onUploaded: @escaping (Photo) -> Void = { _ in }
    ) async throws -> AddPhotoViewModel {
        let sources = try (0..<count).map { _ in try Self.pngSource() }
        let viewModel = try makeViewModel(sources: sources, session: session, onUploaded: onUploaded)
        await viewModel.loadPickedPhotos()
        return viewModel
    }

    private static func recorder() -> (Captured<[URLRequest]>, @Sendable (URLRequest) -> Void) {
        let captured = Captured<[URLRequest]>([])
        return (captured, { request in captured.set(captured.get() + [request]) })
    }

    private static func insertBody(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: Load step (eng C1)

    /// protects: picks load in selection order into idle rows holding an upload JPEG and a thumbnail (eng C1, design D11).
    /// fails_when: rows reorder, stay preparing, or keep no JPEG/thumbnail after the load.
    /// no_claim: memory use with real 48MP picks (live QA).
    @Test func loadPickedPhotosFillsEveryRowInSelectionOrder() async throws {
        let viewModel = try makeViewModel(sources: [try Self.pngSource(), try Self.pngSource()], session: nil)
        #expect(viewModel.items.map(\.state) == [.preparing, .preparing])
        #expect(viewModel.isPreparing)
        #expect(!viewModel.canSubmit)

        await viewModel.loadPickedPhotos()

        #expect(viewModel.items.map(\.id) == Array(Self.itemIDs.prefix(2)))
        #expect(viewModel.items.map(\.state) == [.idle, .idle])
        #expect(viewModel.items.allSatisfy { $0.jpeg?.prefix(2) == Data([0xFF, 0xD8]) && $0.thumbnail != nil })
        #expect(viewModel.unloadableCount == 0)
        #expect(!viewModel.loadFailedEntirely)
    }

    /// protects: an unloadable pick (nil, a throw, or undecodable bytes) drops out and is counted; the rest stay (design D11).
    /// fails_when: a bad pick leaves a row, isn't counted, or takes the good picks with it.
    /// no_claim: the footer's wording (AppCopyVoiceTests).
    @Test func unloadablePicksDropOutAndAreCounted() async throws {
        struct LoadFailure: Error {}
        let viewModel = try makeViewModel(
            sources: [
                { nil },
                try Self.pngSource(),
                { throw LoadFailure() }
            ],
            session: nil
        )

        await viewModel.loadPickedPhotos()

        #expect(viewModel.items.map(\.id) == [Self.itemIDs[1]])
        #expect(viewModel.unloadableCount == 2)
        #expect(!viewModel.loadFailedEntirely)
        #expect(viewModel.canSubmit)
    }

    /// protects: when no pick can be read, the sheet learns to show the "Couldn't load" alert, and no request is sent
    /// (the old submit-time `unreadableImageMessage` coverage, moved to the load step).
    /// fails_when: undecodable bytes become a row, or Upload is possible.
    /// no_claim: the alert's presentation (live QA).
    @Test func undecodableImageDataFailsTheLoadWithoutSendingARequest() async throws {
        MockURLProtocol.reset()
        let (captured, record) = Self.recorder()
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8), onRequest: record)
        let viewModel = try makeViewModel(sources: [{ Data("not an image".utf8) }], session: makeTestSession())

        await viewModel.loadPickedPhotos()
        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(viewModel.items.isEmpty)
        #expect(viewModel.loadFailedEntirely)
        #expect(viewModel.unloadableCount == 1)
        #expect(AddPhotoViewModel.unreadableImageMessage == AppCopy.photoUnreadableBody.copy.text)
        #expect(viewModel.submissionState == .idle)
        #expect(captured.get().isEmpty)
    }

    // MARK: Captions

    /// protects: captions are trimmed and an empty or whitespace-only one becomes nil (stored NULL, AC 7).
    /// fails_when: whitespace or newlines survive the trim, or "" is sent instead of nil.
    /// no_claim: the DB check (migration; local Supabase QA).
    @Test func normalizedCaptionTrimsAndTurnsEmptyIntoNil() {
        #expect(AddPhotoViewModel.normalizedCaption("  The cat \n") == "The cat")
        #expect(AddPhotoViewModel.normalizedCaption(" \n\t ") == nil)
        #expect(AddPhotoViewModel.normalizedCaption("") == nil)
    }

    /// protects: the limit is 140 Unicode scalars after trimming, matching Postgres `char_length` (spec).
    /// fails_when: length counts grapheme clusters or UTF-16 units, or counts surrounding whitespace.
    /// no_claim: that the server agrees (local Supabase QA).
    @Test func captionLengthCountsUnicodeScalarsAfterTrimming() {
        #expect(AddPhotoViewModel.captionLength("  abc  ") == 3)
        // "é" as e + combining acute: one Character, two scalars.
        #expect(AddPhotoViewModel.captionLength("e\u{301}") == 2)
        // A family emoji: one Character, five scalars (three people, two joiners).
        #expect(AddPhotoViewModel.captionLength("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}") == 5)
        #expect(!AddPhotoViewModel.isOverLimit(String(repeating: "a", count: 140) + "   "))
        #expect(AddPhotoViewModel.isOverLimit(String(repeating: "a", count: 141)))
    }

    /// protects: a 141-scalar caption disables Upload; 140 allows it (AC 7).
    /// fails_when: Upload stays enabled over the limit or is disabled at exactly 140.
    /// no_claim: the counter's look (live QA).
    @Test func aCaptionOverTheLimitDisablesUpload() async throws {
        let viewModel = try await makeLoadedViewModel(count: 2)
        let first = Self.itemIDs[0]

        viewModel.setCaption(String(repeating: "x", count: 140), for: first)
        #expect(viewModel.canSubmit)

        viewModel.setCaption(String(repeating: "x", count: 141), for: first)
        #expect(!viewModel.canSubmit)
    }

    /// protects: newlines never reach a caption; they become spaces (design D14).
    /// fails_when: a pasted newline is stored.
    /// no_claim: the Return-to-next-field focus move (view; UI test types without Return).
    @Test func setCaptionReplacesNewlinesWithSpaces() async throws {
        let viewModel = try await makeLoadedViewModel(count: 1)

        viewModel.setCaption("Cat\non the\r\ncounter", for: Self.itemIDs[0])

        #expect(viewModel.items[0].caption == "Cat on the counter")
    }

    // MARK: Sign-in gate (regression contract, design D22)

    /// protects: signed out, Upload asks for sign-in and sends nothing; items and captions survive the sign-in sheet,
    /// and dismissing it lets the next Upload ask again (AC 9, design D22).
    /// fails_when: a request goes out signed out, rows or captions are lost, or a second Upload doesn't re-ask.
    /// no_claim: the SignInView flow itself (live QA).
    @Test func signedOutUploadAsksForSignInAndKeepsItemsAndCaptions() async throws {
        MockURLProtocol.reset()
        let (captured, record) = Self.recorder()
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8), onRequest: record)
        let viewModel = try await makeLoadedViewModel(count: 2, session: nil)
        viewModel.setCaption("Front door", for: Self.itemIDs[0])
        viewModel.setCaption("Counter", for: Self.itemIDs[1])

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()
        #expect(viewModel.submissionState == .signInRequired)
        #expect(captured.get().isEmpty)

        viewModel.dismissSignInPrompt()
        #expect(viewModel.submissionState == .idle)
        #expect(viewModel.items.map(\.caption) == ["Front door", "Counter"])
        #expect(viewModel.items.map(\.state) == [.idle, .idle])
        #expect(viewModel.items.allSatisfy { $0.isCaptionEditable })

        viewModel.submit()
        #expect(viewModel.submissionState == .signInRequired)
    }

    /// protects: dismissing the sign-in prompt is a no-op unless it is showing.
    /// fails_when: it resets a running or failed pass.
    /// no_claim: none beyond that.
    @Test func dismissSignInPromptIsANoOpWhenNotCurrentlySignInRequired() async throws {
        let viewModel = try await makeLoadedViewModel(count: 1)

        viewModel.dismissSignInPrompt()

        #expect(viewModel.submissionState == .idle)
    }

    // MARK: Upload

    /// protects: the one-photo path uploads the prepared JPEG to `<bodega>/<itemId>.jpg`, inserts the row with that id
    /// and the trimmed caption, reports it, and lands submitted (regression contract; eng A1).
    /// fails_when: the path or row id isn't the item id, the caption isn't trimmed, onUploaded isn't called, or the
    /// state isn't submitted with the photo.
    /// no_claim: the real server (local Supabase QA).
    @Test func submitUploadsTheJPEGThenInsertsTheRowAndLandsSubmitted() async throws {
        MockURLProtocol.reset()
        let (captured, record) = Self.recorder()
        let id = Self.itemIDs[0]
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8), onRequest: record)
        MockURLProtocol.stub(body: Data(Self.photoJSON(id: id, caption: "Front door").utf8), onRequest: record)
        let reported = Captured<[Photo.ID]>([])
        let viewModel = try await makeLoadedViewModel(count: 1) { reported.set(reported.get() + [$0.id]) }
        viewModel.setCaption("  Front door  ", for: id)

        viewModel.submit()
        #expect(viewModel.submissionState == .submitting)
        #expect(viewModel.leadingAction == .stop)
        await viewModel.waitForPendingSubmitForTesting()

        guard case .submitted(let photos) = viewModel.submissionState else {
            Issue.record("expected .submitted, got \(viewModel.submissionState)")
            return
        }
        #expect(photos.map(\.id) == [id])
        #expect(photos.first?.caption == "Front door")
        #expect(reported.get() == [id])
        let requests = captured.get()
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/storage/v1/object/photos/\(Self.bodegaID.uuidString)/\(id.uuidString).jpg")
        #expect(requests[1].url?.path == "/rest/v1/photos")
        #expect(requests[1].httpMethod == "POST")
        let json = try Self.insertBody(requests[1])
        #expect(json["id"] as? String == id.uuidString)
        #expect(json["bodega_id"] as? String == Self.bodegaID.uuidString)
        #expect(json["uploaded_by"] as? String == Self.uploaderID.uuidString)
        #expect(json["storage_path"] as? String == "\(Self.bodegaID.uuidString)/\(id.uuidString).jpg")
        #expect(json["caption"] as? String == "Front door")
    }

    /// protects: a batch uploads one item at a time in reverse selection order, so `created_at desc` shows it in
    /// selection order; an empty caption is omitted (NULL) (spec, AC 6, AC 7).
    /// fails_when: items upload in selection order, interleave, or send "" for an empty caption.
    /// no_claim: real timestamps (local Supabase QA).
    @Test func aBatchUploadsSequentiallyInReverseSelectionOrder() async throws {
        MockURLProtocol.reset()
        let (captured, record) = Self.recorder()
        for id in Self.itemIDs.reversed() {
            MockURLProtocol.stub(body: Data(Self.storageJSON.utf8), onRequest: record)
            MockURLProtocol.stub(body: Data(Self.photoJSON(id: id).utf8), onRequest: record)
        }
        let viewModel = try await makeLoadedViewModel(count: 3)
        viewModel.setCaption("First", for: Self.itemIDs[0])
        viewModel.setCaption("   ", for: Self.itemIDs[1])

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        let requests = captured.get()
        #expect(requests.count == 6)
        let storageIDs = stride(from: 0, to: requests.count, by: 2).map { requests[$0].url?.lastPathComponent }
        #expect(storageIDs == Self.itemIDs.reversed().map { "\($0.uuidString).jpg" })
        let inserts = try stride(from: 1, to: requests.count, by: 2).map { try Self.insertBody(requests[$0]) }
        #expect(inserts.map { $0["id"] as? String } == Self.itemIDs.reversed().map(\.uuidString))
        #expect(inserts[0]["caption"] == nil)
        #expect(inserts[1]["caption"] == nil)
        #expect(inserts[2]["caption"] as? String == "First")
        guard case .submitted(let photos) = viewModel.submissionState else {
            Issue.record("expected .submitted, got \(viewModel.submissionState)")
            return
        }
        #expect(photos.map(\.id) == Self.itemIDs)
    }

    /// protects: with a failure on photo 2 of 3, photos 1 and 3 upload, photo 2 fails, the pass ends partially
    /// failed with "Retry 1", and the retry uploads only photo 2 (AC 8).
    /// fails_when: a failure stops the pass, the state isn't partiallyFailed, the retry re-sends an uploaded
    /// item, or the end state isn't submitted with all three.
    /// no_claim: the in-voice footer's text (AppCopyVoiceTests) and the UI (UI test).
    @Test func aPartialFailureEndsPartiallyFailedAndRetrySkipsUploadedItems() async throws {
        MockURLProtocol.reset()
        let (captured, record) = Self.recorder()
        // Reverse order: 3, 2, 1. Photo 2's storage upload fails.
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8), onRequest: record)
        MockURLProtocol.stub(body: Data(Self.photoJSON(id: Self.itemIDs[2]).utf8), onRequest: record)
        MockURLProtocol.stub(statusCode: 500, body: Data(#"{"message":"boom"}"#.utf8), onRequest: record)
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8), onRequest: record)
        MockURLProtocol.stub(body: Data(Self.photoJSON(id: Self.itemIDs[0]).utf8), onRequest: record)
        let viewModel = try await makeLoadedViewModel(count: 3)

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(viewModel.submissionState == .partiallyFailed)
        #expect(viewModel.items[1].state == .failed)
        #expect(viewModel.uploadedPhotos.map(\.id) == [Self.itemIDs[0], Self.itemIDs[2]])
        #expect(viewModel.failedCount == 1)
        #expect(viewModel.leadingAction == .done)
        #expect(viewModel.canSubmit)
        #expect(captured.get().count == 5)

        let (retried, recordRetry) = Self.recorder()
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8), onRequest: recordRetry)
        MockURLProtocol.stub(body: Data(Self.photoJSON(id: Self.itemIDs[1]).utf8), onRequest: recordRetry)
        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(retried.get().count == 2)
        #expect(retried.get().first?.url?.lastPathComponent == "\(Self.itemIDs[1].uuidString).jpg")
        guard case .submitted(let photos) = viewModel.submissionState else {
            Issue.record("expected .submitted, got \(viewModel.submissionState)")
            return
        }
        #expect(photos.map(\.id) == Self.itemIDs)
    }

    /// protects: a caption locks once its item's first attempt starts and stays locked after a failure; a failed row
    /// can still be removed, and removing the last failed row with others uploaded ends submitted (eng O1, spec).
    /// fails_when: a failed item's caption can be edited, a failed row can't be removed, or removal leaves the
    /// sheet partially failed with nothing to retry.
    /// no_claim: how the locked caption renders (live QA, UI test).
    @Test func aCaptionLocksOnTheFirstAttemptAndAFailedRowCanBeRemoved() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8))
        MockURLProtocol.stub(body: Data(Self.photoJSON(id: Self.itemIDs[1]).utf8))
        MockURLProtocol.stub(statusCode: 500, body: Data(#"{"message":"boom"}"#.utf8))
        let viewModel = try await makeLoadedViewModel(count: 2)
        viewModel.setCaption("Before", for: Self.itemIDs[0])

        viewModel.submit()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(viewModel.items[0].state == .failed)
        #expect(!viewModel.items[0].isCaptionEditable)
        viewModel.setCaption("After", for: Self.itemIDs[0])
        #expect(viewModel.items[0].caption == "Before")
        #expect(viewModel.items[0].isRemovable)
        #expect(!viewModel.items[1].isRemovable)

        viewModel.remove(itemID: Self.itemIDs[0])

        guard case .submitted(let photos) = viewModel.submissionState else {
            Issue.record("expected .submitted, got \(viewModel.submissionState)")
            return
        }
        #expect(photos.map(\.id) == [Self.itemIDs[1]])
    }

    /// protects: removing every row before any upload closes the sheet with nothing uploaded (spec).
    /// fails_when: the sheet stays open empty or reports photos.
    /// no_claim: the swipe gesture (UI test removes one row).
    @Test func removingEveryRowBeforeUploadEndsWithNothing() async throws {
        let viewModel = try await makeLoadedViewModel(count: 2)

        viewModel.remove(itemID: Self.itemIDs[0])
        #expect(viewModel.submissionState == .idle)
        viewModel.remove(itemID: Self.itemIDs[1])

        #expect(viewModel.submissionState == .submitted([]))
    }

    /// protects: Stop lets the current item finish and starts nothing after it; the rest stay idle and editable,
    /// and the leading button becomes Done (design D10). Cancel is replaced only while a pass runs.
    /// fails_when: Stop cancels the in-flight item, later items still upload, or stopped items are locked.
    /// no_claim: Stop mid-request against a real server (live QA).
    @Test func stopFinishesTheCurrentItemAndStartsNoMore() async throws {
        MockURLProtocol.reset()
        let (captured, record) = Self.recorder()
        let gate = StubGate()
        MockURLProtocol.stub(body: Data(Self.storageJSON.utf8), gate: gate, onRequest: record)
        MockURLProtocol.stub(body: Data(Self.photoJSON(id: Self.itemIDs[1]).utf8), onRequest: record)
        let viewModel = try await makeLoadedViewModel(count: 2)
        #expect(viewModel.leadingAction == .cancel)

        viewModel.submit()
        #expect(viewModel.leadingAction == .stop)
        #expect(!viewModel.canSubmit)
        while captured.get().isEmpty { await Task.yield() }
        viewModel.stop()
        gate.open()
        await viewModel.waitForPendingSubmitForTesting()

        #expect(captured.get().count == 2)
        #expect(viewModel.items[1].uploadedPhoto?.id == Self.itemIDs[1])
        #expect(viewModel.items[0].state == .idle)
        #expect(viewModel.items[0].isCaptionEditable)
        #expect(viewModel.submissionState == .idle)
        #expect(viewModel.leadingAction == .done)
        #expect(viewModel.canSubmit)
    }

    /// protects: Cancel or Done asks before discarding only when an unsent row has a caption (design D10).
    /// fails_when: it asks with no captions typed, or doesn't ask with one.
    /// no_claim: the dialog itself (live QA).
    @Test func discardConfirmationOnlyWithAnUnsentCaption() async throws {
        let viewModel = try await makeLoadedViewModel(count: 2)
        #expect(!viewModel.needsDiscardConfirmation)

        viewModel.setCaption("   ", for: Self.itemIDs[0])
        #expect(!viewModel.needsDiscardConfirmation)

        viewModel.setCaption("Counter", for: Self.itemIDs[1])
        #expect(viewModel.needsDiscardConfirmation)
        #expect(viewModel.unsentCount == 2)
    }
}

}
