import Foundation
import SwiftData

/// Import of walk history from a file (#180 PR 2): `inspect` reads,
/// validates and previews a file and holds its new fixes; `commit` inserts
/// them. Both run on the transfer, never on the main actor (AC 10). Import
/// merges by fix id and never replaces or deletes a stored fix (O2).
extension WalkHistoryTransfer {
    /// What a file would add, for the import sheet (design DS1).
    nonisolated struct ImportPreview: Equatable, Sendable {
        /// The request this preview answers; `commit` takes it back.
        let request: Int
        /// The file's name without its extension (design D2).
        let fileName: String
        /// Valid, distinct fixes in the file.
        let fileFixCount: Int
        /// How many of those this phone does not have.
        let newFixCount: Int
        /// Entries that were not a readable fix.
        let skippedFixCount: Int
        /// The walk days (4 am New York) of the earliest and latest valid
        /// fix, new or not; `nil` with no valid fix.
        let firstDay: WalkedDayKey?
        let lastDay: WalkedDayKey?
        /// Distinct walk days with a valid fix (DS1: "84 days of recording").
        let dayCount: Int
        /// A new fix carries no ride evidence (0 or 3), so its day will be an
        /// estimate (design D3).
        let newFixesLackEvidence: Bool
    }

    nonisolated enum ImportError: Error, Equatable {
        case notWalkHistory
        case newerVersion
        case tooLarge
        /// The file could not be read at all.
        case unreadable
    }

    nonisolated enum CommitOutcome: Equatable, Sendable {
        /// Saved: `inserted` fixes stamped with `batch` (eng E3).
        case committed(inserted: Int, batch: UUID)
        /// Clear History landed after the confirm tap (eng A7): rolled
        /// back, nothing inserted, the pending import dropped.
        case cleared
        /// No pending import for this request (replaced or dropped).
        case stale
    }

    /// An inspected file's new fixes, held until commit, cancel or a newer
    /// request (eng A4).
    nonisolated struct PendingImport: Sendable {
        let request: Int
        let fixes: [WalkHistoryFile.Fix]
    }

    /// Reads, validates and previews the file at `url`, and holds its new
    /// fixes for `commit` under `request` (the caller's increasing count:
    /// an older request finishing late never replaces a newer one).
    ///
    /// The size is checked from the file's attributes before reading (eng
    /// A2: `maxFixCount` × 160 bytes). A picked file is read inside its
    /// security scope. With `removingAfterRead` (a copy the system put in
    /// this app's Inbox when the file was opened from outside, eng A5) the
    /// copy is deleted once read, whatever the outcome.
    func inspect(
        _ url: URL,
        request: Int,
        removingAfterRead: Bool = false,
        now: Date = Date()
    ) throws -> ImportPreview {
        let data = try read(url, removingAfterRead: removingAfterRead)
        let validated: WalkHistoryFile.Validated
        do {
            validated = try WalkHistoryFile.validate(data, now: now, maxFixCount: maxFixCount)
        } catch WalkHistoryFile.DecodeError.newerVersion {
            throw ImportError.newerVersion
        } catch WalkHistoryFile.DecodeError.tooLarge {
            throw ImportError.tooLarge
        } catch {
            throw ImportError.notWalkHistory
        }
        let stored = try storedIDs(ModelContext(container))
        let new = validated.fixes.filter { !stored.contains($0.id) }
        if request >= (pendingImport?.request ?? .min) {
            pendingImport = PendingImport(request: request, fixes: new)
        }
        let days = Self.walkDays(validated.fixes)
        return ImportPreview(
            request: request,
            fileName: url.deletingPathExtension().lastPathComponent,
            fileFixCount: validated.fixes.count,
            newFixCount: new.count,
            skippedFixCount: validated.skippedCount,
            firstDay: days.first,
            lastDay: days.last,
            dayCount: days.count,
            newFixesLackEvidence: new.contains(where: Self.lacksEvidence)
        )
    }

    /// Inserts the pending import's fixes this phone still lacks (re-checked
    /// here, so a fix that arrived meanwhile is not duplicated), as
    /// unmatched, each with its file's evidence (0 becomes `.imported`, eng
    /// E2) and one new `importBatch` (E3), and deletes the match state in
    /// the same save so the next pass rebuilds everything (A1). Asks
    /// `shouldCommit` (the matcher's generation is unchanged since the
    /// confirm tap, A7) right before the one save. A failed save rolls back
    /// and keeps the pending import for a retry.
    func commit(_ request: Int, shouldCommit: @Sendable () -> Bool) async throws -> CommitOutcome {
        guard let pending = pendingImport, pending.request == request else { return .stale }
        let context = ModelContext(container)
        let stored = try storedIDs(context)
        let batch = UUID()
        var inserted = 0
        for fix in pending.fixes where !stored.contains(fix.id) {
            let point = WalkedPoint(
                id: fix.id,
                latitude: fix.latitude,
                longitude: fix.longitude,
                recordedAt: fix.recordedAt
            )
            point.storedRide = fix.ride == RideEvidence.unknown.rawValue ? RideEvidence.imported.rawValue : fix.ride
            point.importBatch = batch
            context.insert(point)
            inserted += 1
        }
        guard inserted > 0 else {
            pendingImport = nil
            return .committed(inserted: 0, batch: batch)
        }
        // Each row deleted on this context, so a rollback restores it.
        for state in try context.fetch(FetchDescriptor<WalkedMatchState>()) {
            context.delete(state)
        }
        do {
            try await willSaveImport()
            guard shouldCommit() else {
                context.rollback()
                pendingImport = nil
                return .cleared
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        pendingImport = nil
        return .committed(inserted: inserted, batch: batch)
    }

    /// The sheet closed before a commit, or the file was replaced: the
    /// held fixes go, if they are still `request`'s.
    func cancelImport(_ request: Int) {
        if pendingImport?.request == request { pendingImport = nil }
    }

    // MARK: Files

    /// The file's bytes, within its security scope, after the size check.
    private func read(_ url: URL, removingAfterRead: Bool) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            if removingAfterRead { Self.removeInboxCopy(url) }
        }
        let size: Int
        do {
            size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw ImportError.unreadable
        }
        guard size <= WalkHistoryFile.maxFileBytes(maxFixCount: maxFixCount) else { throw ImportError.tooLarge }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ImportError.unreadable
        }
    }

    /// No ride evidence in the file: unknown, or imported once already.
    private static func lacksEvidence(_ fix: WalkHistoryFile.Fix) -> Bool {
        fix.ride == RideEvidence.unknown.rawValue || fix.ride == RideEvidence.imported.rawValue
    }

    /// Every stored fix id, fetching only the id (eng performance note).
    private func storedIDs(_ context: ModelContext) throws -> Set<UUID> {
        var descriptor = FetchDescriptor<WalkedPoint>()
        descriptor.propertiesToFetch = [\.id]
        return Set(try context.fetch(descriptor).map(\.id))
    }

    /// The distinct walk days of `fixes`, in order. Sorted first, so the
    /// calendar is asked about once per day, not once per fix.
    private static func walkDays(_ fixes: [WalkHistoryFile.Fix]) -> [WalkedDayKey] {
        var days: [WalkedDayKey] = []
        var current: DateInterval?
        for time in fixes.map(\.recordedAt).sorted() {
            if let current, current.start <= time, time < current.end { continue }
            let key = WalkedDayKey(date: time)
            days.append(key)
            current = key.interval
        }
        return days
    }

    // MARK: The Inbox (eng A5)

    /// Where the system copies a file opened from outside, since the app
    /// does not open documents in place.
    nonisolated static var inboxDirectory: URL {
        URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory)
    }

    /// Whether `url` is a copy the system made for this app (in its Inbox
    /// or its temporary directory), which import may delete. A file picked
    /// in Files is never one.
    nonisolated static func isInboxCopy(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.resolvingSymlinksInPath().path
        return [inboxDirectory, URL.temporaryDirectory].contains { root in
            path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
        }
    }

    /// Deletes `url` if it is an Inbox copy; anything else is left alone.
    nonisolated static func removeInboxCopy(_ url: URL) {
        guard isInboxCopy(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// At launch: removes walk history files left in the Inbox by an earlier
    /// run (a crash, or a file never claimed), and nothing else. A file
    /// added in the last `inboxGrace` is kept: on a cold open it is the one
    /// being delivered, and its import deletes it once read.
    nonisolated static func sweepInbox(_ inbox: URL = inboxDirectory, now: Date = Date()) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .isDirectoryKey]
        guard let files = try? manager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: keys) else { return }
        for file in files where file.pathExtension.lowercased() == WalkHistoryFile.fileExtension {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory != true else { continue }
            let added = values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast
            if now.timeIntervalSince(added) > inboxGrace {
                try? manager.removeItem(at: file)
            }
        }
    }

    /// How long a file in the Inbox is left for its import to claim.
    nonisolated static let inboxGrace: TimeInterval = 10 * 60
}
