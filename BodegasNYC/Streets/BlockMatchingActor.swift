import Foundation
import os
import SwiftData
import Synchronization

/// Runs every Streets Walked match pass and cache clear, one at a time
/// (#108 spec Implementation 4). Owns the `StreetGrid` (loaded once, off the
/// main actor, on the first pass) and a `WalkedBlockStore` on its own
/// contexts.
///
/// Clear History deletes raw history and bumps `generation` from the main
/// actor at once (eng R9), then queues `clearCache()`. A pass checks the
/// generation after staging its writes, right before its single `save()`,
/// and drops its work if it changed. The check is an optimization, not the
/// guarantee: nothing here ever makes the main actor wait on a pass's save,
/// so a Clear can still land between the check and the save. That pass's
/// save then only touches state the Clear's queued `clearCache()` replaces
/// (masks and stamp), plus `isMatched` on fixes the Clear deleted, and the
/// cache clear runs after it, here, in order (#113 item 2).
actor BlockMatchingActor {
    /// Where a test seam runs inside a pass or a cache clear.
    nonisolated enum CommitPoint: Sendable {
        /// A pass has staged its writes; its generation check comes next.
        case beforeCheck
        /// A pass passed its check; its `save()` comes next.
        case beforeSave
        /// A cache clear is about to delete masks and the stamp.
        case clear
    }

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
    private let willCommit: @Sendable (CommitPoint) throws -> Void
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
        },
        willCommit: @escaping @Sendable (CommitPoint) throws -> Void = { _ in }
    ) {
        self.willCommit = willCommit
        self.container = container
        self.activityProvider = activityProvider
        self.loadGrid = loadGrid
        self.onGridLoadFailure = onGridLoadFailure
    }

    nonisolated var generation: Int { generationLock.withLock { $0 } }

    /// Makes every pass in flight drop its work (Clear History). Never waits
    /// on a pass: the lock only guards the integer.
    nonisolated func invalidate() {
        generationLock.withLock { $0 += 1 }
    }

    /// Your Walks' history (#170), read after every queued pass.
    nonisolated enum HistoryOutcome: Sendable {
        case ready(WalkedHistory)
        /// The street data did not load (eng R5).
        case unavailable
        /// The day rows could not be read, or their backfill has not
        /// succeeded yet (eng A6); the next pass retries.
        case failed
    }

    /// Full rebuilds saved so far (tests).
    var rebuildCount: Int { store?.rebuildCount ?? 0 }
    /// Day-row backfills saved so far (tests).
    var backfillCount: Int { store?.backfillCount ?? 0 }

    /// Matches whatever history is unmatched and returns the saved state.
    func catchUp() async -> Outcome {
        await enqueue { await $0.runPass() }
    }

    /// Deletes the masks and the stamp, after any pass already queued.
    func clearCache() async -> Outcome {
        await enqueue { await $0.runClear() }
    }

    /// The walk days, after any pass already queued (#170 spec rule 6). The
    /// first read loads every day row; later reads are in memory.
    func history() async -> HistoryOutcome {
        await enqueue { actor in
            guard let store = actor.prepareStore() else { return .unavailable }
            guard let history = try? store.history() else { return .failed }
            return .ready(history)
        }
    }

    /// One day's walked runs for its map, built here, off the main actor
    /// (eng A5). Empty when the day has none or the history is unavailable.
    func dayRuns(_ day: WalkedDayKey) async -> [WalkedRun] {
        await enqueue { actor in
            (try? actor.prepareStore()?.dayRuns(day)) ?? []
        }
    }

    private func enqueue<T: Sendable>(_ job: @escaping @Sendable (isolated BlockMatchingActor) async -> T) async -> T {
        let previous = tail
        let task = Task { () -> T in
            await previous?.value
            return await job(self)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// A backfill (#170 eng A1) runs first when the day rows are behind,
    /// then the unmatched fixes take an incremental pass in the same job. A
    /// backfill that throws does not block the summary (A6): the pass goes
    /// on without it, history reports `.failed`, and the next pass retries.
    private func runPass() async -> Outcome {
        let startGeneration = generation
        guard let store = prepareStore() else { return .unavailable }
        do {
            var plan = try store.plan()
            if let backfill = plan, backfill.kind == .backfill {
                do {
                    guard try await run(backfill, on: store, generation: startGeneration) else { return .cancelled }
                } catch {
                    WalkRecorder.logger.error("backfill: \(error.localizedDescription, privacy: .public)")
                }
                plan = try store.plan(allowsBackfill: false)
            }
            guard let plan else {
                return .updated(try store.summary(), store.grid)
            }
            let saved = try await run(plan, on: store, generation: startGeneration)
            return saved ? .updated(try store.summary(), store.grid) : .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Queries the activity for `plan` (none for a backfill, which judges
    /// legs by saved evidence and speed alone, eng A1) and applies it.
    private func run(
        _ plan: WalkedBlockStore.Plan,
        on store: WalkedBlockStore,
        generation startGeneration: Int
    ) async throws -> Bool {
        var activity = VehicleActivity.unavailable
        if plan.kind != .backfill, let range = plan.range {
            activity = await activityProvider.vehicleActivity(from: range.start, to: range.end)
        }
        return try store.apply(
            plan,
            activity: activity,
            seam: willCommit,
            shouldCommit: { generation == startGeneration }
        )
    }

    private func runClear() async -> Outcome {
        do {
            try willCommit(.clear)
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
