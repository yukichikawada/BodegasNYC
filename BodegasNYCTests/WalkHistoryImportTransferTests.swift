//
//  WalkHistoryImportTransferTests.swift
//  BodegasNYCTests
//
//  #180 PR 2: import through `WalkHistoryTransfer` against an in-memory
//  store and per-test files: the preview's counts (DS1), merge by id (O2,
//  AC 3 to 5), the evidence and batch written (eng E2, E3), the forced
//  rebuild (A1), the generation check (A7), a failed save and a replaced
//  request (A4), and the Inbox rules (A5).
//

import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

@MainActor
struct WalkHistoryImportTransferTests {
    private typealias Fix = WalkHistoryFile.Fix
    private typealias F = StreetFixtures

    /// The fixture walks are dated in 2027 (`F.baseDate`); this clock reads
    /// a day later, so none is "in the future".
    private static let now = F.baseDate.addingTimeInterval(86_400)

    /// A directory of its own under the temporary directory.
    private static func makeDirectory() throws -> URL {
        let url = URL.temporaryDirectory.appending(
            path: "WalkHistoryImportTransferTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `count` fixes a minute apart from `start`, ride values as given.
    private static func fixes(_ count: Int, from start: Date = F.baseDate, ride: Int = 0) -> [Fix] {
        (0 ..< count).map { index in
            Fix(
                id: UUID(),
                latitude: 40.75 + Double(index) * 1e-5,
                longitude: -73.99,
                recordedAt: start.addingTimeInterval(Double(index) * 60),
                ride: ride
            )
        }
    }

    private static func write(_ fixes: [Fix], in directory: URL, name: String = "My Bodegas Walks 2027-01-16") throws -> URL {
        let url = directory.appending(path: "\(name).mybodegas")
        try WalkHistoryFile.encode(fixes, exportedAt: now, appVersion: "test").write(to: url)
        return url
    }

    private static func store(_ fixes: [Fix], in context: ModelContext, matched: Bool = false) throws {
        for fix in fixes {
            let point = WalkedPoint(id: fix.id, latitude: fix.latitude, longitude: fix.longitude, recordedAt: fix.recordedAt)
            point.storedRide = fix.ride
            point.isMatched = matched
            context.insert(point)
        }
        try context.save()
    }

    private static func points(_ container: ModelContainer) throws -> [WalkedPoint] {
        try ModelContext(container).fetch(FetchDescriptor<WalkedPoint>(sortBy: [SortDescriptor(\.recordedAt)]))
    }

    // MARK: Preview

    /// protects=DS1 and the spec's preview: the counts of valid, new and
    /// skipped fixes, the first and last walk day of every valid fix (new or
    /// not), the distinct day count and whether a new fix lacks evidence
    /// (D3); the file's name without its extension; fails_when=points stand
    /// in for days, a stored fix is counted as new, or the day range ignores
    /// fixes already here; no_claim=the sheet's rendering.
    @Test func inspectPreviewsCountsDaysAndEvidence() async throws {
        let container = try makeInMemoryModelContainer()
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dayOne = Self.fixes(3, from: F.baseDate, ride: 1)
        let dayTwo = Self.fixes(2, from: F.baseDate.addingTimeInterval(86_400 * 3), ride: 0)
        try Self.store(Array(dayOne.prefix(2)), in: container.mainContext)
        var data = String(decoding: try WalkHistoryFile.encode(dayOne + dayTwo, exportedAt: Self.now, appVersion: "t"), as: UTF8.self)
        data = data.replacingOccurrences(of: "\"fixes\":[", with: "\"fixes\":[7,")
        let url = directory.appending(path: "Someone's Walks.mybodegas")
        try Data(data.utf8).write(to: url)

        let transfer = WalkHistoryTransfer(container: container)
        let later = F.baseDate.addingTimeInterval(86_400 * 10) // day two is not in the future
        let preview = try await transfer.inspect(url, request: 1, now: later)
        #expect(preview.request == 1)
        #expect(preview.fileName == "Someone's Walks")
        #expect(preview.fileFixCount == 5)
        #expect(preview.newFixCount == 3)
        #expect(preview.skippedFixCount == 1)
        #expect(preview.firstDay == WalkedDayKey(date: dayOne[0].recordedAt))
        #expect(preview.lastDay == WalkedDayKey(date: dayTwo[1].recordedAt))
        #expect(preview.dayCount == 2)
        #expect(preview.newFixesLackEvidence)

        let walked = try Self.write(Self.fixes(2, from: F.baseDate.addingTimeInterval(9_000), ride: 1), in: directory)
        #expect(try await transfer.inspect(walked, request: 2, now: later).newFixesLackEvidence == false)
    }

    /// protects=AC 7, the refusals and the size rule (eng A2): a file over
    /// cap × 160 bytes is refused from its attributes, a wrong file, a newer
    /// file and a missing file each map to their error, and none stores
    /// anything; fails_when=a refused file writes, or a read failure is
    /// called a wrong file; no_claim=the messages (view model tests).
    @Test func refusalsWriteNothing() async throws {
        let container = try makeInMemoryModelContainer()
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = WalkHistoryTransfer(container: container, maxFixCount: 2)
        let big = try Self.write(Self.fixes(3), in: directory, name: "big")
        await #expect(throws: WalkHistoryTransfer.ImportError.tooLarge) { try await transfer.inspect(big, request: 1, now: Self.now) }
        let wrong = directory.appending(path: "wrong.mybodegas")
        try Data(#"{"type":"FeatureCollection"}"#.utf8).write(to: wrong)
        await #expect(throws: WalkHistoryTransfer.ImportError.notWalkHistory) { try await transfer.inspect(wrong, request: 2, now: Self.now) }
        let newer = directory.appending(path: "newer.mybodegas")
        try Data(#"{"format":"my-bodegas-walk-history","version":2,"fixes":[]}"#.utf8).write(to: newer)
        await #expect(throws: WalkHistoryTransfer.ImportError.newerVersion) { try await transfer.inspect(newer, request: 3, now: Self.now) }
        let missing = directory.appending(path: "missing.mybodegas")
        await #expect(throws: WalkHistoryTransfer.ImportError.unreadable) { try await transfer.inspect(missing, request: 4, now: Self.now) }
        #expect(try await transfer.commit(4) { true } == .stale)
        #expect(try Self.points(container).isEmpty)
    }

    // MARK: Merge

    /// protects=O2 and AC 3 to 5: a commit inserts exactly the file's fixes
    /// this phone lacks, keeps every stored fix (one recorded after the
    /// export included), and a second import of the same file inserts
    /// nothing; fails_when=a fix is duplicated by id, a stored fix is
    /// replaced or deleted, or a re-import adds rows; no_claim=the blocks
    /// derived from the union (WalkHistoryImportRoundTripTests).
    @Test func commitMergesByIDAndIsIdempotent() async throws {
        let container = try makeInMemoryModelContainer()
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exported = Self.fixes(6, ride: 1)
        let later = Self.fixes(2, from: F.baseDate.addingTimeInterval(7_200), ride: 2)
        try Self.store(Array(exported.prefix(3)) + later, in: container.mainContext)
        let url = try Self.write(exported, in: directory)
        let transfer = WalkHistoryTransfer(container: container)

        #expect(try await transfer.inspect(url, request: 1, now: Self.now).newFixCount == 3)
        guard case .committed(let inserted, _) = try await transfer.commit(1, shouldCommit: { true }) else {
            Issue.record("the commit did not save")
            return
        }
        #expect(inserted == 3)
        let stored = try Self.points(container)
        #expect(stored.count == 8)
        #expect(Set(stored.map(\.id)) == Set((exported + later).map(\.id)))
        #expect(stored.filter { later.map(\.id).contains($0.id) }.allSatisfy { $0.storedRide == 2 })

        let again = try await transfer.inspect(url, request: 2, now: Self.now)
        #expect(again.newFixCount == 0 && again.fileFixCount == 6)
        guard case .committed(0, _) = try await transfer.commit(2, shouldCommit: { true }) else {
            Issue.record("a re-import inserted fixes")
            return
        }
        #expect(try Self.points(container).count == 8)
    }

    /// protects=the spec's "re-check before save": a fix that reaches the
    /// store between inspect and commit (another import, or the recorder) is
    /// not inserted again; fails_when=the commit trusts the preview's id set
    /// and duplicates it; no_claim=a fix arriving during the save itself
    /// (one SwiftData save; ids are fresh UUIDs).
    @Test func commitRechecksStoredIDs() async throws {
        let container = try makeInMemoryModelContainer()
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = Self.fixes(4)
        let transfer = WalkHistoryTransfer(container: container)
        _ = try await transfer.inspect(try Self.write(file, in: directory), request: 1, now: Self.now)
        try Self.store([file[1]], in: container.mainContext)
        #expect(try await transfer.commit(1) { true } != .stale)
        let stored = try Self.points(container)
        #expect(stored.count == 4)
        #expect(Set(stored.map(\.id)).count == 4)
    }

    /// protects=eng E2 and E3 on the stored rows: a file fix with no
    /// evidence is stored `.imported`, 1, 2 and 3 as written, unmatched;
    /// every inserted fix carries one batch UUID per commit, a second commit
    /// a different one, and recorded fixes none; fails_when=an imported
    /// unknown stays unknown (CoreMotion would then certify it), a ride is
    /// remapped, or batches are shared or missing; no_claim=how the matcher
    /// treats `.imported` (ImportedEvidenceTests).
    @Test func commitStoresEvidenceAndOneBatchPerCommit() async throws {
        let container = try makeInMemoryModelContainer()
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorded = Self.fixes(1, from: F.baseDate.addingTimeInterval(-600))
        try Self.store(recorded, in: container.mainContext, matched: true)
        let first = (0 ... 3).flatMap { ride in Self.fixes(1, from: F.baseDate.addingTimeInterval(Double(ride) * 60), ride: ride) }
        let second = Self.fixes(2, from: F.baseDate.addingTimeInterval(3_600))
        let transfer = WalkHistoryTransfer(container: container)
        _ = try await transfer.inspect(try Self.write(first, in: directory, name: "a"), request: 1, now: Self.now)
        guard case .committed(4, let batchA) = try await transfer.commit(1, shouldCommit: { true }) else {
            Issue.record("first commit")
            return
        }
        _ = try await transfer.inspect(try Self.write(second, in: directory, name: "b"), request: 2, now: Self.now)
        guard case .committed(2, let batchB) = try await transfer.commit(2, shouldCommit: { true }) else {
            Issue.record("second commit")
            return
        }
        #expect(batchA != batchB)
        let byID = Dictionary(uniqueKeysWithValues: try Self.points(container).map { ($0.id, $0) })
        #expect(byID[recorded[0].id]?.importBatch == nil)
        #expect(first.map { byID[$0.id]?.storedRide } == [3, 1, 2, 3])
        #expect(first.allSatisfy { byID[$0.id]?.importBatch == batchA && byID[$0.id]?.isMatched == false })
        #expect(second.allSatisfy { byID[$0.id]?.importBatch == batchB && byID[$0.id]?.ride == .imported })
    }

    // MARK: Rebuild, abort, failure, replacement

    /// protects=eng A1: the commit deletes the match state in its save, so
    /// the next plan is a rebuild even when every imported fix sorts after
    /// the newest matched one, and that rebuild records the imported day as
    /// an estimate (`estimatedThroughDay`), however recent; fails_when=the
    /// import is matched incrementally (no estimate label) or the state
    /// survives; no_claim=the view model's recount (view model tests).
    @Test func commitForcesARebuildThatLabelsImportedDays() async throws {
        let container = try makeInMemoryModelContainer()
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grid = F.cornerGrid()
        let walk = F.walk(from: (0, 12), to: (100, 12))
        try F.seed(walk, in: container.mainContext)
        let store = WalkedBlockStore(container: container, grid: grid, now: { [now = Self.now] in now })
        #expect(try store.apply(try #require(try store.plan()), activity: .unavailable) { true })
        #expect(try store.plan() == nil)

        // A later walk on block 300, imported from another phone, a day
        // before `now`: inside CoreMotion's 7 days, an estimate all the same.
        let imported = F.walk(from: (0, 68), to: (100, 68), startTime: 3_600).map { snapshot in
            Fix(id: snapshot.id, latitude: snapshot.coordinate.latitude, longitude: snapshot.coordinate.longitude,
                recordedAt: snapshot.recordedAt, ride: 0)
        }
        let transfer = WalkHistoryTransfer(container: container)
        _ = try await transfer.inspect(try Self.write(imported, in: directory), request: 1, now: Self.now)
        #expect(try await transfer.commit(1) { true } != .stale)
        #expect(try ModelContext(container).fetch(FetchDescriptor<WalkedMatchState>()).isEmpty)

        let plan = try #require(try store.plan())
        #expect(plan.kind == .rebuild)
        #expect(try store.apply(plan, activity: .unavailable) { true })
        let state = try #require(try ModelContext(container).fetch(FetchDescriptor<WalkedMatchState>()).first)
        #expect(state.estimatedThroughDay == WalkedDayKey(date: imported.last!.recordedAt).value)
        #expect(BlockMatcher.isWalked(mask: try #require(try savedMask(300, container))))
    }

    private func savedMask(_ id: UInt32, _ container: ModelContainer) throws -> UInt16? {
        try ModelContext(container).fetch(FetchDescriptor<WalkedBlock>()).first { $0.physicalID == id }?.mask
    }

    /// protects=eng A7: when the generation moved after the confirm tap (a
    /// Clear History landed), the commit rolls back: nothing inserted, the
    /// match state kept, the pending import dropped; fails_when=the cleared
    /// history comes back, or the stale import can still be committed;
    /// no_claim=the menu's disabling (view model tests).
    @Test func commitAbortsWhenTheGenerationMoved() async throws {
        let container = try makeInMemoryModelContainer()
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        container.mainContext.insert(WalkedMatchState(datasetStamp: 1))
        try container.mainContext.save()
        let transfer = WalkHistoryTransfer(container: container)
        _ = try await transfer.inspect(try Self.write(Self.fixes(3), in: directory), request: 1, now: Self.now)
        #expect(try await transfer.commit(1) { false } == .cleared)
        #expect(try Self.points(container).isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<WalkedMatchState>()).count == 1)
        #expect(try await transfer.commit(1) { true } == .stale)
    }

    /// protects=the spec's failure rule: a failed save writes nothing
    /// partial (one save, rolled back) and leaves the pending import for a
    /// retry, which then saves; fails_when=a partial insert survives, or the
    /// retry has nothing to commit; no_claim=the sheet's failure line (view
    /// model tests).
    @Test func aFailedSaveRollsBackAndKeepsTheImportForRetry() async throws {
        let container = try makeInMemoryModelContainer()
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        struct SaveFailed: Error {}
        let failures = Counter(1)
        let transfer = WalkHistoryTransfer(container: container, willSaveImport: {
            if failures.take() { throw SaveFailed() }
        })
        _ = try await transfer.inspect(try Self.write(Self.fixes(3), in: directory), request: 1, now: Self.now)
        await #expect(throws: SaveFailed.self) { try await transfer.commit(1) { true } }
        #expect(try Self.points(container).isEmpty)
        guard case .committed(3, _) = try await transfer.commit(1, shouldCommit: { true }) else {
            Issue.record("the retry did not save")
            return
        }
        #expect(try Self.points(container).count == 3)
    }

    /// protects=eng A4: one pending import app-wide; a newer request
    /// replaces it and the older token cannot commit, an older request that
    /// finishes late never replaces a newer one, and cancel drops it;
    /// fails_when=two imports are held, a stale preview saves, or a late
    /// read clobbers the newer file; no_claim=the sheets (view model tests).
    @Test func aNewerRequestReplacesThePendingImport() async throws {
        let container = try makeInMemoryModelContainer()
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileA = try Self.write(Self.fixes(2), in: directory, name: "a")
        let fileB = try Self.write(Self.fixes(3, from: F.baseDate.addingTimeInterval(9_000)), in: directory, name: "b")
        let transfer = WalkHistoryTransfer(container: container)
        _ = try await transfer.inspect(fileA, request: 1, now: Self.now)
        _ = try await transfer.inspect(fileB, request: 3, now: Self.now)
        _ = try await transfer.inspect(fileA, request: 2, now: Self.now) // late, older
        #expect(try await transfer.commit(1) { true } == .stale)
        #expect(try await transfer.commit(2) { true } == .stale)
        guard case .committed(3, _) = try await transfer.commit(3, shouldCommit: { true }) else {
            Issue.record("the newest request did not commit")
            return
        }
        _ = try await transfer.inspect(fileA, request: 4, now: Self.now)
        await transfer.cancelImport(4)
        #expect(try await transfer.commit(4) { true } == .stale)
        #expect(try Self.points(container).count == 3)
    }

    // MARK: The Inbox (eng A5)

    /// protects=eng A5: an Inbox copy is deleted once read, whether it
    /// imports or is refused, and a picked file (not removing) is left
    /// where it is; fails_when=plain location history piles up in the app's
    /// container, or the person's own file in Files is deleted;
    /// no_claim=where iOS puts the copy on a device (A12, manual).
    @Test func inboxCopiesAreDeletedOnceReadAndPickedFilesAreNot() async throws {
        let container = try makeInMemoryModelContainer()
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = WalkHistoryTransfer(container: container)
        let copy = try Self.write(Self.fixes(2), in: directory, name: "copy")
        #expect(WalkHistoryTransfer.isInboxCopy(copy))
        _ = try await transfer.inspect(copy, request: 1, removingAfterRead: true, now: Self.now)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        let refused = directory.appending(path: "refused.mybodegas")
        try Data("nope".utf8).write(to: refused)
        _ = try? await transfer.inspect(refused, request: 2, removingAfterRead: true, now: Self.now)
        #expect(!FileManager.default.fileExists(atPath: refused.path))
        let picked = try Self.write(Self.fixes(2), in: directory, name: "picked")
        _ = try await transfer.inspect(picked, request: 3, removingAfterRead: false, now: Self.now)
        #expect(FileManager.default.fileExists(atPath: picked.path))
        #expect(!WalkHistoryTransfer.isInboxCopy(URL(fileURLWithPath: "/private/var/mobile/Documents/walks.mybodegas")))
        #expect(!WalkHistoryTransfer.isInboxCopy(URL(string: "https://example.com/a.mybodegas")!))
    }

    /// protects=eng A5's launch sweep, and QA item 3: a walk history file
    /// added to the Inbox longer than the grace ago is removed; one added
    /// within the grace (a cold open being delivered), one whose added date
    /// is unknown (creation date is no signal), the waiting incoming file
    /// even when old, and every other file are kept; on this file system,
    /// a file just written reads as added now; fails_when=the sweep deletes
    /// the file a cold launch is opening, falls back to a creation date, or
    /// removes anything that is not a walk history file; no_claim=the
    /// system's own Inbox housekeeping, or the added date iOS gives a copy
    /// on a device (A12).
    @Test func theInboxSweepRemovesOnlyOldWalkFiles() throws {
        let inbox = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: inbox) }
        let now = Date()
        let longAgo = now.addingTimeInterval(-WalkHistoryTransfer.inboxGrace - 60)
        let old = inbox.appending(path: "old.mybodegas")
        let young = inbox.appending(path: "young.mybodegas")
        let unknown = inbox.appending(path: "unknown.mybodegas")
        let waiting = inbox.appending(path: "waiting.mybodegas")
        let other = inbox.appending(path: "photo.jpg")
        for url in [old, young, unknown, waiting, other] { try Data("x".utf8).write(to: url) }
        let added: [String: Date] = [
            "old.mybodegas": longAgo, "young.mybodegas": now, "waiting.mybodegas": longAgo, "photo.jpg": longAgo
        ]
        WalkHistoryTransfer.sweepInbox(inbox, keeping: [waiting], now: now) { added[$0.lastPathComponent] }
        #expect(!FileManager.default.fileExists(atPath: old.path), "an old walk file stayed")
        #expect(FileManager.default.fileExists(atPath: young.path), "a file added just now was swept")
        #expect(FileManager.default.fileExists(atPath: unknown.path), "a file with no added date was swept")
        #expect(FileManager.default.fileExists(atPath: waiting.path), "the waiting incoming file was swept")
        #expect(FileManager.default.fileExists(atPath: other.path), "a file that is not a walk file was swept")

        // The real lookup: a file written now is inside the grace.
        WalkHistoryTransfer.sweepInbox(inbox, now: now)
        #expect(FileManager.default.fileExists(atPath: young.path), "the real added date swept a new file")
    }
}

/// A thread-safe countdown for seams: `take()` is true `count` times.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(_ count: Int) { remaining = count }

    func take() -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}
