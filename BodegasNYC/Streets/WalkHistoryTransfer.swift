import Foundation
import SwiftData

/// Moves walk history in and out of files (#180). One for the whole app,
/// created by `AppDelegate` beside the recorder (eng A4); its state is
/// published on the shared `StreetsWalkedViewModel`, so every window sees
/// it. It is the only thing that reads or writes for this feature: nothing
/// fetches, encodes or writes a file on the main actor (AC 10).
///
/// Export is here; import (`inspect`, `commit`) is in
/// `WalkHistoryTransfer+Import.swift`.
actor WalkHistoryTransfer {
    /// One export's files, in part order, in a directory of their own.
    nonisolated struct Export: Equatable, Sendable {
        let directory: URL
        let files: [URL]
        let fixCount: Int
    }

    let container: ModelContainer
    private let exportRoot: URL
    nonisolated let maxFixCount: Int
    private let appVersion: String
    /// Test seam: runs after the history is read and before the first file
    /// is written.
    private let willWrite: @Sendable () async -> Void
    /// Test seam (import): runs after a commit has staged its inserts and
    /// before its generation check and save; a throw is a failed save.
    let willSaveImport: @Sendable () async throws -> Void
    /// Export directories handed out and not yet finished or discarded: a
    /// share sheet in some window may still be offering their files.
    private var liveDirectories: Set<URL> = []
    /// The one import inspected and not yet committed or dropped (eng A4:
    /// at most one app-wide). A newer request replaces it.
    var pendingImport: PendingImport?

    /// - Parameters:
    ///   - exportRoot: where export directories go, under the temporary
    ///     directory by default (eng A6).
    ///   - maxFixCount: the per-file cap (eng A2), export and import alike;
    ///     injected small in tests.
    init(
        container: ModelContainer,
        exportRoot: URL = WalkHistoryTransfer.defaultExportRoot,
        maxFixCount: Int = WalkHistoryFile.maxFixCount,
        appVersion: String = WalkHistoryTransfer.bundleAppVersion,
        willWrite: @escaping @Sendable () async -> Void = {},
        willSaveImport: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.container = container
        self.exportRoot = exportRoot
        self.maxFixCount = maxFixCount
        self.appVersion = appVersion
        self.willWrite = willWrite
        self.willSaveImport = willSaveImport
    }

    nonisolated static let defaultExportRoot = URL.temporaryDirectory.appending(
        path: "WalkHistoryExport",
        directoryHint: .isDirectory
    )

    /// "1.0.0 (3)": the marketing version and build, informational
    /// (`AppVersion.display`, #191).
    nonisolated static var bundleAppVersion: String {
        Bundle.main.appVersion.display
    }

    // MARK: Export

    /// How many fixes an export at `tapTime` would hold, under the same
    /// rule as `readHistory` (no non-finite coordinates): the export
    /// dialog's part count (design D12). Only the coordinates are fetched.
    func fixCount(through tapTime: Date) throws -> Int {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<WalkedPoint>(predicate: Self.through(tapTime))
        descriptor.propertiesToFetch = [\.latitude, \.longitude]
        return try context.fetch(descriptor).count(where: Self.isPlace)
    }

    /// Writes every fix recorded up to `tapTime` (the confirm tap) into
    /// files of at most `maxFixCount` fixes, in history order, and returns
    /// them. One fetch on this actor's own context (eng A3): no offset
    /// paging, so concurrent inserts and deletes can never leave a gap or a
    /// repeat. The fetch reads one committed state of the store, the one at
    /// the moment it runs, and materialises it before anything else runs on
    /// this actor. A writer whose change spans more than one transaction is
    /// seen at whichever of its states was committed: SwiftData's
    /// `delete(model:where:)` commits its batch delete apart from the
    /// inserts of the same `save()` (measured for #180 PR 2). The app's
    /// writers are the recorder (inserts only) and Clear History (deletes
    /// only, one batch), so each export is the history before or after any
    /// of them. Earlier exports are swept first (eng A6), except those still
    /// live: handed out and not yet finished or discarded, which another
    /// window's share sheet may be offering. Each file is
    /// written under a temporary name and renamed (`.atomic`), with default
    /// file protection (eng A6: `.complete` would lock the file mid-AirDrop
    /// when the phone locks). On any failure the new directory is removed:
    /// nothing partial is left.
    func export(through tapTime: Date, now: Date = Date()) async throws -> Export {
        sweepExports()
        let fixes = try readHistory(through: tapTime)
        await willWrite()
        let directory = exportRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let parts = WalkHistoryFile.parts(of: fixes, maxFixCount: maxFixCount)
            var files: [URL] = []
            for (index, part) in parts.enumerated() {
                let name = WalkHistoryFile.fileName(exportedAt: now, part: index + 1, of: parts.count)
                let url = directory.appending(path: name, directoryHint: .notDirectory)
                let data = try WalkHistoryFile.encode(part, exportedAt: now, appVersion: appVersion)
                try data.write(to: url, options: .atomic)
                files.append(url)
            }
            liveDirectories.insert(directory)
            return Export(directory: directory, files: files, fixCount: fixes.count)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The share sheet was cancelled: the files go at once (eng A6). A
    /// completed share leaves them for the destination, which may read them
    /// lazily, until the next sweep.
    func discard(_ export: Export) {
        liveDirectories.remove(export.directory)
        try? FileManager.default.removeItem(at: export.directory)
    }

    /// The share sheet completed: the files stay for the destination, but
    /// are no longer live, so the next sweep removes them.
    func finish(_ export: Export) {
        liveDirectories.remove(export.directory)
    }

    /// Removes every walk history file left under the export root, and the
    /// directories that held them, and nothing else (eng A6): at launch
    /// (nothing is live yet, so everything goes) and before each export
    /// (live exports are kept).
    func sweepExports() {
        Self.sweep(exportRoot, keeping: liveDirectories)
    }

    nonisolated static func sweep(_ root: URL, keeping live: Set<URL> = []) {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        var directories: [URL] = []
        let livePaths = Set(live.map { $0.resolvingSymlinksInPath().path })
        for case let url as URL in enumerator {
            if livePaths.contains(url.resolvingSymlinksInPath().path) {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                directories.append(url)
            } else if url.pathExtension == WalkHistoryFile.fileExtension {
                try? manager.removeItem(at: url)
            }
        }
        // Deepest first, so a parent empties before it is checked.
        for directory in directories.sorted(by: { $0.path.count > $1.path.count })
            where (try? manager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try? manager.removeItem(at: directory)
        }
    }

    /// Every fix up to `tapTime` in history order, in one fetch.
    private func readHistory(through tapTime: Date) throws -> [WalkHistoryFile.Fix] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<WalkedPoint>(
            predicate: Self.through(tapTime),
            sortBy: [SortDescriptor(\.recordedAt)]
        )
        return try context.fetch(descriptor)
            .filter(Self.isPlace)
            .map { point in
                WalkHistoryFile.Fix(
                    id: point.id,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    recordedAt: point.recordedAt,
                    ride: point.storedRide
                )
            }
            // The store sorts by time; ties settle by id exactly as
            // `sortsBefore` defines them.
            .sorted(by: WalkHistoryFile.Fix.sortsBefore)
    }

    /// A non-finite coordinate is no place: nothing can match it, and JSON
    /// cannot carry it. Real fixes never have one.
    private static func isPlace(_ point: WalkedPoint) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite
    }

    private static func through(_ tapTime: Date) -> Predicate<WalkedPoint> {
        #Predicate { $0.recordedAt <= tapTime }
    }
}
