//
//  WalkHistoryTransferTests.swift
//  BodegasNYCTests
//
//  #180 PR 1: export through `WalkHistoryTransfer` against an in-memory
//  store and a per-test directory (AC 1, AC 11, eng A2, A3, A6), and the
//  view model's export state, disabled states, progress signal and
//  telemetry (AC 9 export half, AC 12, design D7, DS3).
//

import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

@MainActor
struct WalkHistoryTransferTests {
    private typealias Fix = WalkHistoryFile.Fix

    /// A fresh export root under the test's temporary directory.
    private static func makeRoot() -> URL {
        URL.temporaryDirectory.appending(
            path: "WalkHistoryTransferTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private static let base = Date(timeIntervalSince1970: 1_790_000_000.123_456)

    /// Inserts `count` fixes a second apart from `start`, with ride values
    /// cycling 0 to 3, and returns them as the file would carry them.
    @discardableResult
    private static func seed(
        _ count: Int,
        from start: Date = base,
        in context: ModelContext
    ) throws -> [Fix] {
        let fixes = (0 ..< count).map { index in
            Fix(
                id: UUID(),
                latitude: 40.7 + Double(index) * 1e-5,
                longitude: -74 - Double(index) * 1e-5,
                recordedAt: start.addingTimeInterval(Double(index) + 0.000_1 * Double(index % 7)),
                ride: index % 4
            )
        }
        for fix in fixes {
            let point = Self.point(fix)
            point.storedRide = fix.ride
            context.insert(point)
        }
        try context.save()
        return fixes
    }

    private nonisolated static func point(_ fix: Fix) -> WalkedPoint {
        WalkedPoint(id: fix.id, latitude: fix.latitude, longitude: fix.longitude, recordedAt: fix.recordedAt)
    }

    private static func read(_ export: WalkHistoryTransfer.Export) throws -> [Fix] {
        try export.files.flatMap { try WalkHistoryFile.decode(Data(contentsOf: $0)).fixes }
    }

    // MARK: The transfer

    /// protects=AC 1 and the tap-time cutoff: an export holds every fix
    /// recorded up to the confirm tap and none after it, in history order
    /// (time, then id for a tie), each with its id, coordinates, exact time
    /// and stored ride value, in one file named for the day;
    /// fails_when=a fix is missing, repeated, reordered, rounded, or one
    /// after the tap is included; no_claim=the share sheet (manual).
    @Test func exportHoldsEveryFixUpToTheTapInHistoryOrder() async throws {
        let container = try makeInMemoryModelContainer()
        var expected = try Self.seed(50, in: container.mainContext)
        // A tie on time, settled by id.
        let tieTime = Self.base.addingTimeInterval(10.000_5)
        let tied = [UUID(), UUID()].map { id in
            Fix(id: id, latitude: 40.75, longitude: -73.99, recordedAt: tieTime, ride: 1)
        }
        for fix in tied.reversed() {
            let point = Self.point(fix)
            point.storedRide = fix.ride
            container.mainContext.insert(point)
        }
        let tapTime = Self.base.addingTimeInterval(100)
        try Self.seed(3, from: tapTime.addingTimeInterval(1), in: container.mainContext) // after the tap
        expected = (expected + tied).sorted(by: Fix.sortsBefore)

        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = WalkHistoryTransfer(container: container, exportRoot: root, appVersion: "1.0.0 (3)")
        let exportedAt = Self.base.addingTimeInterval(200)
        let export = try await transfer.export(through: tapTime, now: exportedAt)

        let name = WalkHistoryFile.fileName(exportedAt: exportedAt, part: 1, of: 1)
        #expect(export.files.map(\.lastPathComponent) == [name])
        #expect(export.fixCount == expected.count)
        #expect(try Self.read(export) == expected)
    }

    /// protects=eng A2 with an injected small cap: an over-cap history
    /// exports as consecutive part files ("part 1 of 3" …), none over the
    /// cap, which together are the whole history in order, so merge-only
    /// import of each part restores it; the dialog's part count agrees;
    /// fails_when=a part exceeds the cap, a fix lands in two parts or none,
    /// the names lack "part i of n", or the count disagrees;
    /// no_claim=import of the parts (PR 2) and the cap's final value.
    @Test func overCapHistoryExportsAsParts() async throws {
        let container = try makeInMemoryModelContainer()
        let fixes = try Self.seed(7, in: container.mainContext)
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = WalkHistoryTransfer(container: container, exportRoot: root, maxFixCount: 3)
        let tapTime = Self.base.addingTimeInterval(100)

        let export = try await transfer.export(through: tapTime, now: Self.base)
        #expect(export.files.map(\.lastPathComponent) == (1 ... 3).map {
            WalkHistoryFile.fileName(exportedAt: Self.base, part: $0, of: 3)
        })
        let parts = try export.files.map { try WalkHistoryFile.decode(Data(contentsOf: $0)).fixes }
        #expect(parts.map(\.count) == [3, 3, 1])
        #expect(parts.flatMap { $0 } == fixes)
        #expect(try await transfer.fixCount(through: tapTime) == 7)
        #expect(WalkHistoryFile.partCount(fixCount: 7, maxFixCount: transfer.maxFixCount) == 3)
    }

    /// protects=eng A3: the history is read in one fetch, so inserts and
    /// deletes saved while an export runs (on another context) leave a
    /// file that is exactly the history before them or exactly after them,
    /// never one with gaps or repeats; and once read, the file is the
    /// history as read; fails_when=the export pages by offset (a delete
    /// between pages skips fixes, an insert repeats one), or reads again
    /// after the seam; no_claim=SQLite's own snapshot isolation, which the
    /// single fetch relies on.
    @Test func exportUnderConcurrentWritesIsOneSnapshot() async throws {
        let container = try makeInMemoryModelContainer()
        let before = try Self.seed(3_000, in: container.mainContext)
        let tapTime = Self.base.addingTimeInterval(10_000)
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Deleted: every third fix. Inserted: as many, interleaved in time.
        let deleted = Set(before.enumerated().filter { $0.offset % 3 == 0 }.map(\.element.id))
        let inserted = (0 ..< deleted.count).map { index in
            Fix(
                id: UUID(),
                latitude: 40.71,
                longitude: -74.01,
                recordedAt: Self.base.addingTimeInterval(Double(index * 3) + 0.5),
                ride: 0
            )
        }
        let after = (before.filter { !deleted.contains($0.id) } + inserted).sorted(by: Fix.sortsBefore)

        let transfer = WalkHistoryTransfer(container: container, exportRoot: root)
        async let exported = transfer.export(through: tapTime)
        try await Task.detached {
            let context = ModelContext(container)
            let ids = Array(deleted)
            try context.delete(model: WalkedPoint.self, where: #Predicate { ids.contains($0.id) })
            for fix in inserted {
                context.insert(Self.point(fix))
            }
            try context.save()
        }.value
        let file = try Self.read(try await exported)
        #expect(file == before || file == after, "a mixed file: \(file.count) fixes")

        // After the read, writes cannot reach the file.
        let held = WalkHistoryTransfer(container: container, exportRoot: root, willWrite: {
            let context = ModelContext(container)
            try? context.delete(model: WalkedPoint.self)
            try? context.save()
        })
        #expect(try Self.read(try await held.export(through: tapTime)) == after)
    }

    /// protects=AC 11 and eng A6: a cancelled share deletes its files and
    /// their directory at once; the sweep (at launch and before each
    /// export) removes leftover `.mybodegas` files and the directories they
    /// leave empty, and nothing else; fails_when=a cancelled export stays
    /// on disk, a completed one survives the next export, or the sweep
    /// deletes another file; no_claim=that the share sheet reports cancel
    /// (manual check).
    @Test func cancelledExportIsDeletedAndTheSweepKeepsOtherFiles() async throws {
        let container = try makeInMemoryModelContainer()
        try Self.seed(5, in: container.mainContext)
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = WalkHistoryTransfer(container: container, exportRoot: root)
        let tapTime = Self.base.addingTimeInterval(100)

        let cancelled = try await transfer.export(through: tapTime)
        #expect(FileManager.default.fileExists(atPath: cancelled.files[0].path))
        await transfer.discard(cancelled)
        #expect(!FileManager.default.fileExists(atPath: cancelled.directory.path))

        let completed = try await transfer.export(through: tapTime)
        let other = root.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: other)
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: nested.appending(path: "keep.json"))

        let next = try await transfer.export(through: tapTime) // sweeps first
        #expect(!FileManager.default.fileExists(atPath: completed.directory.path))
        #expect(FileManager.default.fileExists(atPath: next.files[0].path))
        await transfer.sweepExports()
        #expect(!FileManager.default.fileExists(atPath: next.directory.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: nested.appending(path: "keep.json").path))
    }

    /// protects=the failure rule: an export that cannot write throws and
    /// leaves no directory or file behind; fails_when=a half-written export
    /// stays on disk or the error is swallowed; no_claim=which errors
    /// iOS raises on a full disk.
    @Test func failedExportLeavesNothing() async throws {
        let container = try makeInMemoryModelContainer()
        try Self.seed(5, in: container.mainContext)
        let scratch = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // The root is a file, so no export directory can be made under it.
        let root = scratch.appending(path: "not-a-directory")
        try Data().write(to: root)
        let transfer = WalkHistoryTransfer(container: container, exportRoot: root)

        await #expect(throws: (any Error).self) {
            try await transfer.export(through: Self.base.addingTimeInterval(100))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == ["not-a-directory"])
    }
}
