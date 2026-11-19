//
//  WalkHistoryExportViewModelTests.swift
//  BodegasNYCTests
//
//  #180 PR 1: the shared view model's export: its state, the disabled
//  states of Export and Clear History (AC 9 export half, design D7, DS3),
//  the 0.5 s progress signal and announcement (D7), failure recording and
//  `walk_history_exported` (AC 11, AC 12). Real view model, in-memory store,
//  a per-test export directory, the fixture corner grid.
//

import CoreLocation
import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

/// Holds an export between reading the history and writing its files.
actor ExportGate {
    private(set) var isEntered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func park() async {
        isEntered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct WalkHistoryExportViewModelTests {
    private typealias F = StreetFixtures

    /// A tap after the fixture walk, which is dated in 2027 (`F.baseDate`).
    private static let afterFixture = F.baseDate.addingTimeInterval(86_400)

    private struct Harness {
        let viewModel: StreetsWalkedViewModel
        let sink: RecordingSink
        let announcements: AnnouncementLog
        let root: URL
    }

    private static func makeHarness(
        container: ModelContainer? = nil,
        exportRoot: URL? = nil,
        willWrite: @escaping @Sendable () async -> Void = {},
        clearSeam: @escaping @Sendable (BlockMatchingActor.CommitPoint) -> Void = { _ in }
    ) throws -> Harness {
        let container = try container ?? makeInMemoryModelContainer()
        let defaults = try #require(UserDefaults(suiteName: "WalkHistoryExportViewModelTests.\(UUID().uuidString)"))
        let root = exportRoot ?? URL.temporaryDirectory.appending(
            path: "WalkHistoryExportViewModelTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let sink = RecordingSink()
        let announcements = AnnouncementLog()
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
            matcher: BlockMatchingActor(
                container: container,
                activityProvider: motion,
                loadGrid: { F.cornerGrid() },
                willCommit: { clearSeam($0) }
            ),
            announce: { announcements.texts.append($0) },
            telemetry: Telemetry(sinks: [sink], userDefaults: defaults),
            historyTransfer: WalkHistoryTransfer(container: container, exportRoot: root, willWrite: willWrite)
        )
        return Harness(viewModel: viewModel, sink: sink, announcements: announcements, root: root)
    }

    private static func seededContainer() throws -> ModelContainer {
        let container = try makeInMemoryModelContainer()
        try F.seed(F.walk(from: (0, 12), to: (100, 12)), in: container.mainContext)
        return container
    }

    /// Polls `condition` every 10 ms for at most `seconds`.
    private static func waitUntil(_ seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// protects=AC 9, export half: Export History is disabled with no
    /// history and an export then does nothing; with history it is enabled
    /// and an export writes its files and returns to idle; fails_when=Export
    /// is offered on an empty store, or a finished export stays busy;
    /// no_claim=the menu's rendering (UI test) or Import (PR 2).
    @Test func exportIsDisabledWithoutHistory() async throws {
        let empty = try Self.makeHarness()
        defer { try? FileManager.default.removeItem(at: empty.root) }
        #expect(!empty.viewModel.hasHistory)
        #expect(!empty.viewModel.canExportHistory)
        #expect(await empty.viewModel.exportHistory(at: Self.afterFixture) == .unavailable)
        #expect(!FileManager.default.fileExists(atPath: empty.root.path))

        let seeded = try Self.makeHarness(container: Self.seededContainer())
        defer { try? FileManager.default.removeItem(at: seeded.root) }
        #expect(seeded.viewModel.canExportHistory)
        guard case .exported(let export) = await seeded.viewModel.exportHistory(at: Self.afterFixture) else {
            Issue.record("the export did not write")
            return
        }
        #expect(export.fixCount > 0)
        #expect(FileManager.default.fileExists(atPath: export.files[0].path))
        #expect(seeded.viewModel.historyTransferState == .idle)
        #expect(seeded.viewModel.canExportHistory)
    }

    /// protects=design D7 and eng A4/A7: while an export runs, the shared
    /// view model reads `exporting`, Export and Clear History are disabled
    /// (so Export First is hidden too, DS3), a second export is refused;
    /// from 0.5 s the menu pulses and "Making the file." is announced once;
    /// all of it ends with the export; fails_when=Clear or Export stay
    /// enabled mid-export, two exports overlap, the pulse or announcement is
    /// missing, repeated or outlives the export; no_claim=the symbol effect
    /// itself and Reduce Motion (views, captures).
    @Test func exportInProgressDisablesExportAndClearAndPulses() async throws {
        let gate = ExportGate()
        let harness = try Self.makeHarness(container: Self.seededContainer(), willWrite: { await gate.park() })
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let viewModel = harness.viewModel

        let running = Task { await viewModel.exportHistory(at: Self.afterFixture) }
        #expect(await Self.waitUntil { await gate.isEntered })
        #expect(viewModel.historyTransferState == .exporting)
        #expect(viewModel.isHistoryFileBusy)
        #expect(!viewModel.canExportHistory)
        #expect(!viewModel.canClearHistory)
        #expect(await viewModel.exportHistory(at: Self.afterFixture) == .unavailable)

        #expect(await Self.waitUntil { viewModel.showsHistoryExportProgress })
        #expect(harness.announcements.texts == ["Making the file."])

        await gate.release()
        guard case .exported = await running.value else {
            Issue.record("the held export did not finish")
            return
        }
        #expect(viewModel.historyTransferState == .idle)
        #expect(!viewModel.showsHistoryExportProgress)
        #expect(viewModel.canExportHistory && viewModel.canClearHistory)
        #expect(harness.announcements.texts == ["Making the file."])
    }

    /// protects=design D7's 0.5 s threshold: an export that finishes sooner
    /// neither pulses nor announces, then or later; fails_when=a quick
    /// export announces "Making the file." after it is done;
    /// no_claim=device timing.
    @Test func quickExportNeitherPulsesNorAnnounces() async throws {
        let harness = try Self.makeHarness(container: Self.seededContainer())
        defer { try? FileManager.default.removeItem(at: harness.root) }
        _ = await harness.viewModel.exportHistory(at: Self.afterFixture)
        try await Task.sleep(for: StreetsWalkedViewModel.historyExportProgressDelay + .milliseconds(300))
        #expect(!harness.viewModel.showsHistoryExportProgress)
        #expect(harness.announcements.texts.isEmpty)
    }

    /// protects=design D7: while Clear History is deleting, Export is
    /// disabled and refused, and it comes back after; fails_when=an export
    /// can start mid-Clear, or Export stays disabled; no_claim=the menu's
    /// rendering.
    @Test func clearInProgressDisablesExport() async throws {
        let park = PassPark(at: .clear)
        let harness = try Self.makeHarness(container: Self.seededContainer(), clearSeam: { park.hook($0) })
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let viewModel = harness.viewModel

        let clearing = Task { try await viewModel.clearHistory(at: F.baseDate) }
        #expect(await Self.waitUntil { park.isParked })
        #expect(viewModel.isClearingHistory)
        #expect(!viewModel.canExportHistory)
        #expect(await viewModel.exportHistory(at: Self.afterFixture) == .unavailable)
        park.release()
        try await clearing.value
        #expect(!park.timedOut)
        #expect(!viewModel.isClearingHistory)
        #expect(viewModel.canExportHistory) // fixes after the tap remain
    }

    /// protects=AC 11 and AC 12: a completed share records one
    /// `walk_history_exported` with no properties and leaves the files for
    /// the destination; a cancelled one records nothing and deletes them;
    /// fails_when=a cancel is counted, the event carries a property, or a
    /// cancelled export stays on disk; no_claim=that the share sheet
    /// reports `completed` truthfully (manual).
    @Test func onlyACompletedShareIsCountedAndACancelDeletes() async throws {
        #expect(TelemetryEvent.walkHistoryExported.name == "walk_history_exported")
        #expect(TelemetryEvent.walkHistoryExported.properties.isEmpty)

        let harness = try Self.makeHarness(container: Self.seededContainer())
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let viewModel = harness.viewModel
        guard case .exported(let cancelled) = await viewModel.exportHistory(at: Self.afterFixture) else {
            Issue.record("the export did not write")
            return
        }
        await viewModel.historyExportFinished(cancelled, completed: false)
        #expect(harness.sink.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cancelled.directory.path))

        guard case .exported(let shared) = await viewModel.exportHistory(at: Self.afterFixture) else {
            Issue.record("the second export did not write")
            return
        }
        await viewModel.historyExportFinished(shared, completed: true)
        #expect(harness.sink.events == [.walkHistoryExported])
        #expect(FileManager.default.fileExists(atPath: shared.files[0].path))
    }

    /// protects=the failure path: a write error returns `.failed` (the alert
    /// with Retry), is recorded with context `walk_history.export`, and
    /// leaves the transfer idle for a retry; fails_when=the error is
    /// swallowed, mislabelled, or leaves Export disabled; no_claim=the
    /// alert's rendering.
    @Test func failedExportIsRecordedAndRetryable() async throws {
        let scratch = URL.temporaryDirectory.appending(path: "WalkHistoryFail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appending(path: "not-a-directory")
        try Data().write(to: root)
        let harness = try Self.makeHarness(container: Self.seededContainer(), exportRoot: root)

        #expect(await harness.viewModel.exportHistory(at: Self.afterFixture) == .failed)
        #expect(harness.sink.reports.map(\.context) == ["walk_history.export"])
        #expect(harness.sink.events.isEmpty)
        #expect(harness.viewModel.historyTransferState == .idle)
        #expect(harness.viewModel.canExportHistory)
    }
}
