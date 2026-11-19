#if DEBUG
import Foundation

// A walk history file for `BodegasNYCUITests` (#180 PR 2): written at launch
// and handed to the inbox the way `.onOpenURL` hands a file opened from
// outside. It bypasses document registration and URL delivery, which are
// checked by hand (eng A12).
nonisolated extension UITestFixtures {
    /// With `-UITestFixtures`, Streets Walked runs on an empty in-memory
    /// store and a file holding `walkedBlockFixture` (one Manhattan block,
    /// one walk day) is opened at launch, after `-UITestOpenURLDelay` when
    /// given.
    static let importFixtureArgument = "-UITestImportFixture"

    static var importsFixtureFile: Bool {
        isEnabled && CommandLine.arguments.contains(importFixtureArgument)
    }

    /// Writes the fixture file under the temporary directory (where import
    /// treats it as an Inbox copy and deletes it once read) and feeds it to
    /// `inbox`.
    @MainActor
    static func openImportFixture(in inbox: SharedWalkInbox, now: Date = Date()) {
        guard importsFixtureFile, let grid = try? StreetGridLoader.shared.grid() else { return }
        let fixes = walkedBlockFixture(grid: grid, now: now).map { snapshot in
            WalkHistoryFile.Fix(
                id: snapshot.id,
                latitude: snapshot.coordinate.latitude,
                longitude: snapshot.coordinate.longitude,
                recordedAt: snapshot.recordedAt,
                ride: 0
            )
        }
        let directory = URL.temporaryDirectory.appending(
            path: "UITestImport-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let url = directory.appending(path: WalkHistoryFile.fileName(exportedAt: now, part: 1, of: 1))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try WalkHistoryFile.encode(fixes, exportedAt: now, appVersion: "UI test").write(to: url, options: .atomic)
        } catch {
            return
        }
        let delay = argumentValue(after: openURLDelayArgument).flatMap(Double.init) ?? 0
        guard delay > 0 else {
            inbox.receive(url)
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            inbox.receive(url)
        }
    }
}
#endif
