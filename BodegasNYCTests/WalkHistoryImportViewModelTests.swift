//
//  WalkHistoryImportViewModelTests.swift
//  BodegasNYCTests
//
//  #180 PR 2: the shared view model's import: the sheet's phases (design
//  state table, D6, DS4), the busy states that disable Export, Import and
//  Clear in every window (D7, D13, eng A7), replacement and takeover (D9,
//  D13), the generation abort (A7), a failed save and its retry, the first
//  count after an import (D10), `walk_history_imported` (AC 12), and the
//  incoming-URL holder's dispatch (eng A10). Real view model, in-memory
//  store, the fixture corner grid, per-test files.
//

import CoreLocation
import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

@MainActor
struct WalkHistoryImportViewModelTests {
    private typealias F = StreetFixtures
    private typealias Fix = WalkHistoryFile.Fix
    private typealias Token = StreetsWalkedViewModel.SceneToken

    /// After the fixture walks, which are dated in 2027.
    private static let now = F.baseDate.addingTimeInterval(86_400)

    private struct Harness {
        let viewModel: StreetsWalkedViewModel
        let container: ModelContainer
        let sink: RecordingSink
        let directory: URL
    }

    private static func makeHarness(
        willSaveImport: @escaping @Sendable () async throws -> Void = {}
    ) throws -> Harness {
        let container = try makeInMemoryModelContainer()
        let defaults = try #require(UserDefaults(suiteName: "WalkHistoryImportViewModelTests.\(UUID().uuidString)"))
        let directory = URL.temporaryDirectory.appending(
            path: "WalkHistoryImportViewModelTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sink = RecordingSink()
        let motion = FakeMotionProvider()
        let viewModel = StreetsWalkedViewModel(
            locationPermissionClient: LocationPermissionClient(),
            modelContainer: container,
            recorder: WalkRecorder(
                modelContainer: container,
                userDefaults: defaults,
                access: { AuthorizationBox(.authorizedAlways).access },
                backend: FakeWalkBackend(),
                now: { Date() }
            ),
            userDefaults: defaults,
            motion: motion,
            matcher: BlockMatchingActor(container: container, activityProvider: motion, loadGrid: { F.cornerGrid() }),
            announce: { _ in },
            telemetry: Telemetry(sinks: [sink], userDefaults: defaults),
            historyTransfer: WalkHistoryTransfer(container: container, willSaveImport: willSaveImport)
        )
        return Harness(viewModel: viewModel, container: container, sink: sink, directory: directory)
    }

    /// Block 100 walked, as a file's fixes with no evidence.
    private static let walkFixes: [Fix] = F.walk(from: (0, 12), to: (100, 12)).map { snapshot in
        Fix(id: snapshot.id, latitude: snapshot.coordinate.latitude, longitude: snapshot.coordinate.longitude,
            recordedAt: snapshot.recordedAt, ride: 0)
    }

    private static func write(_ fixes: [Fix], in directory: URL, name: String = "walks") throws -> IncomingHistoryFile {
        let url = directory.appending(path: "\(name).mybodegas")
        try WalkHistoryFile.encode(fixes, exportedAt: now, appVersion: "test").write(to: url)
        return .picked(url)
    }

    private static func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func isPreview(_ phase: HistoryImportPhase?) -> Bool {
        if case .preview = phase { return true }
        return false
    }

    /// protects=the state table end to end and DS4, D10, AC 12: reading,
    /// then the preview with the transfer `previewing` and Export, Import
    /// and Clear disabled in every window; Add Walks saves, the next count
    /// is shown as a first count (Your Blocks "counting", Your Walks
    /// "loading"), then done with the block counted; one
    /// `walk_history_imported`, no properties; fails_when=a phase is
    /// skipped, the menu stays enabled mid-import, stale counts show after
    /// the save, or the event repeats or carries data; no_claim=the
    /// sheet's rendering (UI test).
    @Test func anImportReadsPreviewsSavesCountsAndEnds() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let viewModel = harness.viewModel
        #expect(viewModel.canImportHistory && !viewModel.hasHistory)
        let owner = Token.make()
        viewModel.openHistoryFile(try Self.write(Self.walkFixes, in: harness.directory), owner: owner, now: Self.now)
        #expect(viewModel.historyImport?.phase == .reading)
        #expect(viewModel.historyTransferState == .reading)
        #expect(await Self.waitUntil { Self.isPreview(viewModel.historyImport?.phase) })
        let request = try #require(viewModel.historyImport?.request)
        #expect(viewModel.historyTransferState == .previewing(request))
        #expect(!viewModel.canImportHistory && !viewModel.canClearHistory && !viewModel.canExportHistory)

        await viewModel.commitHistoryImport()
        #expect(viewModel.historyImport?.phase == .done)
        #expect(viewModel.historyTransferState == .idle)
        #expect(viewModel.hasHistory && viewModel.hasCounted)
        #expect(viewModel.walkedBlockIDs.contains(100))
        #expect(harness.sink.events == [.walkHistoryImported])
        #expect(TelemetryEvent.walkHistoryImported.properties.isEmpty)
        #expect(viewModel.canImportHistory && viewModel.canClearHistory)

        viewModel.importDidSave()
        #expect(viewModel.yourBlocks.phase == .counting)
        #expect(viewModel.yourWalks(now: Self.now).phase == .loading)

        viewModel.endHistoryImport(owner: owner)
        #expect(viewModel.historyImport == nil)
    }

    /// protects=D6 and the copy table's refusals: nothing new, no walks,
    /// nothing readable, a wrong file and a newer one each end on their own
    /// phase, with the transfer idle and nothing stored; fails_when=two
    /// cases share a line, or a refusal leaves the menu disabled;
    /// no_claim=the text (AppCopyVoiceTests, the copy table test).
    @Test func eachNothingToAddCaseHasItsOwnPhase() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let viewModel = harness.viewModel
        let owner = Token.make()
        let cases: [(IncomingHistoryFile, HistoryImportPhase)] = [
            (try Self.write([], in: harness.directory, name: "empty"), .message(.noWalks)),
            (try Self.raw(#"{"format":"my-bodegas-walk-history","version":1,"fixes":[1,"x"]}"#, harness, "junk"),
             .message(.nothingReadable)),
            (try Self.raw(#"{"format":"gpx"}"#, harness, "gpx"), .message(.wrongFile)),
            (try Self.raw(#"{"format":"my-bodegas-walk-history","version":2,"fixes":[]}"#, harness, "v2"),
             .message(.newerFormat)),
            (.picked(harness.directory.appending(path: "missing.mybodegas")), .message(.readFailure))
        ]
        for (file, expected) in cases {
            viewModel.openHistoryFile(file, owner: owner, now: Self.now)
            #expect(await Self.waitUntil { viewModel.historyImport?.phase == expected }, "\(expected)")
            #expect(viewModel.historyTransferState == .idle)
            viewModel.endHistoryImport(owner: owner)
        }
        // Everything already here: nothing new.
        try F.seed(F.walk(from: (0, 12), to: (100, 12)), in: harness.container.mainContext)
        let stored = try ModelContext(harness.container).fetch(FetchDescriptor<WalkedPoint>()).map { point in
            Fix(id: point.id, latitude: point.latitude, longitude: point.longitude, recordedAt: point.recordedAt, ride: 0)
        }
        viewModel.openHistoryFile(try Self.write(stored, in: harness.directory, name: "same"), owner: owner, now: Self.now)
        #expect(await Self.waitUntil { viewModel.historyImport?.phase == .nothingNew(hasSkipped: false) })
        #expect(harness.sink.events.isEmpty)
    }

    private static func raw(_ json: String, _ harness: Harness, _ name: String) throws -> IncomingHistoryFile {
        let url = harness.directory.appending(path: "\(name).mybodegas")
        try Data(json.utf8).write(to: url)
        return .picked(url)
    }

    /// protects=D9 and D13: a second file in the same window returns the
    /// sheet to reading with one more replacement; a file claimed by another
    /// window takes the import over (the first window's sheet closes) and
    /// the first window can no longer end it; the old request cannot
    /// commit; fails_when=a preview is swapped silently, two imports run,
    /// or the first window's close cancels the second's import;
    /// no_claim=the sheets' presentation (views).
    @Test func aSecondFileReplacesOrTakesOver() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let viewModel = harness.viewModel
        let first = Token.make()
        let second = Token.make()
        viewModel.openHistoryFile(try Self.write(Self.walkFixes, in: harness.directory, name: "a"), owner: first, now: Self.now)
        #expect(await Self.waitUntil { Self.isPreview(viewModel.historyImport?.phase) })
        let oldRequest = try #require(viewModel.historyImport?.request)

        viewModel.openHistoryFile(try Self.write(Self.walkFixes, in: harness.directory, name: "b"), owner: first, now: Self.now)
        #expect(viewModel.historyImport?.phase == .reading)
        #expect(viewModel.historyImport?.replacements == 1)
        #expect(await Self.waitUntil { Self.isPreview(viewModel.historyImport?.phase) })

        viewModel.openHistoryFile(try Self.write(Self.walkFixes, in: harness.directory, name: "c"), owner: second, now: Self.now)
        #expect(viewModel.historyImport?.owner == second)
        #expect(viewModel.historyImport?.replacements == 0)
        viewModel.endHistoryImport(owner: first)
        #expect(viewModel.historyImport?.owner == second)
        #expect(await Self.waitUntil { Self.isPreview(viewModel.historyImport?.phase) })
        #expect(try await viewModel.historyTransfer.commit(oldRequest) { true } == .stale)
    }

    /// protects=eng A7 and D8: while an import saves, a file cannot start
    /// another and Export, Import and Clear are disabled; a Clear History
    /// that lands after the confirm tap (the generation moves) makes the
    /// commit roll back and end on "History was cleared"; fails_when=the
    /// cleared history comes back, or a file interrupts a save;
    /// no_claim=the order of a real Clear tap (the menu is disabled).
    @Test func aClearDuringTheSaveAbortsIt() async throws {
        let viewModelBox = WeakBox<StreetsWalkedViewModel>()
        let observed = ObservedFlags()
        let harness = try Self.makeHarness(willSaveImport: {
            await MainActor.run {
                guard let viewModel = viewModelBox.value else { return }
                observed.couldReceive = viewModel.canReceiveHistoryFile
                observed.couldClear = viewModel.canClearHistory
                viewModel.matcher.invalidate() // a Clear History landed
            }
        })
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let viewModel = harness.viewModel
        viewModelBox.value = viewModel
        viewModel.openHistoryFile(try Self.write(Self.walkFixes, in: harness.directory), owner: .main, now: Self.now)
        #expect(await Self.waitUntil { Self.isPreview(viewModel.historyImport?.phase) })
        await viewModel.commitHistoryImport()
        #expect(observed.couldReceive == false && observed.couldClear == false)
        #expect(viewModel.historyImport?.phase == .message(.clearedMeanwhile))
        #expect(try ModelContext(harness.container).fetchCount(FetchDescriptor<WalkedPoint>()) == 0)
        #expect(harness.sink.events.isEmpty)
    }

    /// protects=the state table's "Save failed": a failed save returns to
    /// the preview with the failure line, recorded under
    /// `walk_history.import`, the transfer back to `previewing`, and Add
    /// Walks again saves; fails_when=the failure is terminal, silent or
    /// loses the file; no_claim=the red line's rendering.
    @Test func aFailedSaveShowsThePreviewAgainAndRetries() async throws {
        struct SaveFailed: Error {}
        let failures = Counter(1)
        let harness = try Self.makeHarness(willSaveImport: { if failures.take() { throw SaveFailed() } })
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let viewModel = harness.viewModel
        viewModel.openHistoryFile(try Self.write(Self.walkFixes, in: harness.directory), owner: .main, now: Self.now)
        #expect(await Self.waitUntil { Self.isPreview(viewModel.historyImport?.phase) })
        await viewModel.commitHistoryImport()
        guard case .preview(_, saveFailed: true) = viewModel.historyImport?.phase else {
            Issue.record("no save-failed preview: \(String(describing: viewModel.historyImport?.phase))")
            return
        }
        #expect(harness.sink.reports.map(\.context) == ["walk_history.import"])
        await viewModel.commitHistoryImport()
        #expect(viewModel.historyImport?.phase == .done)
        #expect(try ModelContext(harness.container).fetchCount(FetchDescriptor<WalkedPoint>()) == Self.walkFixes.count)
    }

    /// protects=Cancel before the save: closing the sheet drops the held
    /// fixes and frees the menu; fails_when=a cancelled preview can still
    /// be committed, or the menu stays disabled; no_claim=swipe-down (the
    /// same `endHistoryImport`, from the view).
    @Test func cancellingDropsTheHeldFixes() async throws {
        let harness = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let viewModel = harness.viewModel
        viewModel.openHistoryFile(try Self.write(Self.walkFixes, in: harness.directory), owner: .main, now: Self.now)
        #expect(await Self.waitUntil { Self.isPreview(viewModel.historyImport?.phase) })
        let request = try #require(viewModel.historyImport?.request)
        viewModel.endHistoryImport(owner: .main)
        #expect(viewModel.historyImport == nil && viewModel.canImportHistory && viewModel.historyTransferState == .idle)
        try await Task.sleep(for: .milliseconds(200)) // the cancel runs on the transfer
        #expect(try await viewModel.historyTransfer.commit(request) { true } == .stale)
    }

    // MARK: The incoming-URL holder (eng A10)

    /// protects=A10: one `receive` dispatches by URL kind: a file URL
    /// ending in `.mybodegas` waits as the history file (no
    /// `shared_walk_opened`), a newer one replaces it, a walk link still
    /// opens the shared walk, and anything else is ignored; `takeHistoryFile`
    /// hands the file over once; fails_when=a file is decoded as a link, a
    /// link is taken for a file, or a file is claimed twice;
    /// no_claim=delivery by the system (A12, manual).
    @Test func theInboxDispatchesByURLKind() throws {
        var captured: [TelemetryEvent] = []
        let inbox = SharedWalkInbox { captured.append($0) }
        inbox.receive(URL(fileURLWithPath: "/tmp/elsewhere/My Bodegas Walks 2026-11-19.mybodegas"))
        let first = try #require(inbox.pendingHistoryFile)
        #expect(inbox.pending == nil && captured.isEmpty)
        inbox.receive(URL(fileURLWithPath: "/tmp/elsewhere/Other.MYBODEGAS"))
        #expect(inbox.pendingHistoryFile?.url.lastPathComponent == "Other.MYBODEGAS")
        #expect(inbox.pendingHistoryFile?.id != first.id)
        inbox.receive(URL(fileURLWithPath: "/tmp/elsewhere/notes.json"))
        inbox.receive(try #require(URL(string: "https://example.com/a.mybodegas")))
        #expect(inbox.pendingHistoryFile?.url.lastPathComponent == "Other.MYBODEGAS")
        #expect(inbox.pending == nil && captured.isEmpty)
        #expect(inbox.takeHistoryFile() != nil)
        #expect(inbox.takeHistoryFile() == nil)
    }
}

/// A weak reference a `@Sendable` seam can read on the main actor.
@MainActor
final class WeakBox<Value: AnyObject> {
    weak var value: Value?
}

@MainActor
final class ObservedFlags {
    var couldReceive: Bool?
    var couldClear: Bool?
}
