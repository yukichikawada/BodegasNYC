import Foundation
import SwiftData

/// Moves walk history in and out of files (#180). One for the whole app,
/// created by `AppDelegate` beside the recorder (eng A4); its state is
/// published on the shared `StreetsWalkedViewModel`, so every window sees
/// it. It is the only thing that reads or writes for this feature: nothing
/// fetches, encodes or writes a file on the main actor (AC 10).
///
/// PR 1 is the export half. PR 2 adds `inspect` and `commit` for import.
actor WalkHistoryTransfer {
    /// One export's files, in part order, in a directory of their own.
    nonisolated struct Export: Equatable, Sendable {
        let directory: URL
        let files: [URL]
        let fixCount: Int
    }

    private let container: ModelContainer
    private let exportRoot: URL
    nonisolated let maxFixCount: Int
    private let appVersion: String
    /// Test seam: runs after the history is read and before the first file
    /// is written.
    private let willWrite: @Sendable () async -> Void

    /// - Parameters:
    ///   - exportRoot: where export directories go, under the temporary
    ///     directory by default (eng A6).
    ///   - maxFixCount: the per-file cap (eng A2); injected small in tests.
    init(
        container: ModelContainer,
        exportRoot: URL = WalkHistoryTransfer.defaultExportRoot,
        maxFixCount: Int = WalkHistoryFile.maxFixCount,
        appVersion: String = WalkHistoryTransfer.bundleAppVersion,
        willWrite: @escaping @Sendable () async -> Void = {}
    ) {
        self.container = container
        self.exportRoot = exportRoot
        self.maxFixCount = maxFixCount
        self.appVersion = appVersion
        self.willWrite = willWrite
    }

    nonisolated static let defaultExportRoot = URL.temporaryDirectory.appending(
        path: "WalkHistoryExport",
        directoryHint: .isDirectory
    )

    /// "1.0.0 (3)": the marketing version and build, informational.
    nonisolated static var bundleAppVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    // MARK: Export

    /// How many fixes an export at `tapTime` would hold: the export
    /// dialog's part count (design D12).
    func fixCount(through tapTime: Date) throws -> Int {
        let context = ModelContext(container)
        return try context.fetchCount(FetchDescriptor<WalkedPoint>(predicate: Self.through(tapTime)))
    }

    /// Writes every fix recorded up to `tapTime` (the confirm tap) into
    /// files of at most `maxFixCount` fixes, in history order, and returns
    /// them. One fetch on this actor's own context (eng A3): no offset
    /// paging, so concurrent inserts and deletes can never leave a gap or a
    /// repeat. Earlier exports are swept first (eng A6). Each file is
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
        try? FileManager.default.removeItem(at: export.directory)
    }

    /// Removes every walk history file left under the export root, and the
    /// directories that held them, and nothing else (eng A6): at launch and
    /// before each export.
    func sweepExports() {
        Self.sweep(exportRoot)
    }

    nonisolated static func sweep(_ root: URL) {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        var directories: [URL] = []
        for case let url as URL in enumerator {
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
            // A non-finite coordinate is no place: nothing can match it, and
            // JSON cannot carry it. Real fixes never have one.
            .filter { $0.latitude.isFinite && $0.longitude.isFinite }
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

    private static func through(_ tapTime: Date) -> Predicate<WalkedPoint> {
        #Predicate { $0.recordedAt <= tapTime }
    }
}
