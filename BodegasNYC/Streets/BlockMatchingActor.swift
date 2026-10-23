import Foundation
import SwiftData
import Synchronization

/// Runs every Streets Walked match pass and cache clear, one at a time
/// (#108 spec Implementation 4). Owns the `StreetGrid` (loaded once, off the
/// main actor, on the first pass) and a `WalkedBlockStore` on its own
/// contexts.
///
/// Clear History bumps `generation` from the main actor at once; a pass
/// checks it right before its single `save()` and drops its work if it
/// changed, so a cancelled rebuild never resurrects masks (eng R9).
actor BlockMatchingActor {
    nonisolated enum Outcome: Sendable {
        /// The saved masks, current with history at the time of the pass.
        case updated(WalkedSummary, StreetGrid)
        /// Clear History landed during the pass; nothing was saved.
        case cancelled
        /// The street data did not load (eng R5); raw fixes keep recording.
        case unavailable
        /// SwiftData failed; the message is for the tracking-error banner.
        case failed(String)
    }

    private let container: ModelContainer
    private let loadGrid: @Sendable () throws -> StreetGrid
    private let onGridLoadFailure: @Sendable (Error) -> Void
    private let activityProvider: any MotionActivityProviding
    private let generationLock = Mutex(0)
    private var gridLoad: Result<StreetGrid, Error>?
    private var store: WalkedBlockStore?
    /// The last queued job: each new one waits for it, so passes and clears
    /// run strictly in the order they were asked for.
    private var tail: Task<Void, Never>?

    /// - Parameters:
    ///   - onGridLoadFailure: `assertionFailure` by default, so a broken
    ///     bundle stops a DEBUG run; Release carries on without blocks.
    init(
        container: ModelContainer,
        activityProvider: any MotionActivityProviding = CoreMotionActivityProvider(),
        loadGrid: @escaping @Sendable () throws -> StreetGrid = { try StreetGrid.loadBundled() },
        onGridLoadFailure: @escaping @Sendable (Error) -> Void = { error in
            assertionFailure("nyc-streets.bin did not load: \(error)")
        }
    ) {
        self.container = container
        self.activityProvider = activityProvider
        self.loadGrid = loadGrid
        self.onGridLoadFailure = onGridLoadFailure
    }

    nonisolated var generation: Int { generationLock.withLock { $0 } }

    /// Makes every pass in flight drop its work (Clear History).
    nonisolated func invalidate() {
        generationLock.withLock { $0 += 1 }
    }

    /// Full rebuilds saved so far (tests).
    var rebuildCount: Int { store?.rebuildCount ?? 0 }

    /// Matches whatever history is unmatched and returns the saved state.
    func catchUp() async -> Outcome {
        await enqueue { await $0.runPass() }
    }

    /// Deletes the masks and the stamp, after any pass already queued.
    func clearCache() async -> Outcome {
        await enqueue { await $0.runClear() }
    }

    private func enqueue(_ job: @escaping @Sendable (isolated BlockMatchingActor) async -> Outcome) async -> Outcome {
        let previous = tail
        let task = Task { () -> Outcome in
            await previous?.value
            return await job(self)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func runPass() async -> Outcome {
        let startGeneration = generation
        guard let store = prepareStore() else { return .unavailable }
        do {
            guard let plan = try store.plan() else {
                return .updated(try store.summary(), store.grid)
            }
            var activity = VehicleActivity.unavailable
            if let range = plan.range {
                activity = await activityProvider.vehicleActivity(from: range.start, to: range.end)
            }
            let saved = try store.apply(plan, activity: activity) { generation == startGeneration }
            return saved ? .updated(try store.summary(), store.grid) : .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func runClear() async -> Outcome {
        do {
            if let store {
                try store.clear()
                return .updated(try store.summary(), store.grid)
            }
            try WalkedBlockStore.clearCache(in: container)
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func prepareStore() -> WalkedBlockStore? {
        if let store { return store }
        if gridLoad == nil {
            gridLoad = Result { try loadGrid() }
            if case .failure(let error) = gridLoad { onGridLoadFailure(error) }
        }
        guard case .success(let grid) = gridLoad else { return nil }
        let store = WalkedBlockStore(container: container, grid: grid)
        self.store = store
        return store
    }
}
