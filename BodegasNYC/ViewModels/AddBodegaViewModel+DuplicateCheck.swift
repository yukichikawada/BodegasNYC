import Foundation

/// The duplicate check's query (#20), kept out of `AddBodegaViewModel.swift`
/// so that file stays within its length budget. The prompt's state and
/// actions (`confirmNew()`, `dismissDuplicatePrompt()`, `cancelSubmit()`)
/// stay there, next to the private state they touch.
extension AddBodegaViewModel {
    /// Visible bodegas within `duplicateRadiusMeters` of `coordinate`,
    /// nearest first, as the `nearby_bodegas` RPC returns them. The RPC is
    /// raced against `duplicateCheckTimeout` on `clock` (eng R2); an error
    /// or the timeout counts as no matches, since the check is advisory.
    /// RLS shows a creator their own hidden rows, so those are dropped here
    /// rather than offered as duplicates (eng R5).
    nonisolated static func visibleNearbyMatches(
        at coordinate: Coordinate,
        bodegaService: BodegaService,
        clock: any Clock<Duration>
    ) async -> [Bodega] {
        let matches = await firstFinished(within: duplicateCheckTimeout, on: clock) {
            try await bodegaService.fetchNearby(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radiusMeters: duplicateRadiusMeters
            )
        }
        return (matches ?? []).filter { !$0.isHidden }
    }

    /// `operation`'s value, or nil if it throws, if `clock` reaches
    /// `timeout` first, or if the calling task is cancelled. Whichever
    /// finishes first wins; the other is cancelled and never awaited, so a
    /// request that ignores cancellation can't hold up the caller.
    nonisolated static func firstFinished<Value: Sendable>(
        within timeout: Duration,
        on clock: any Clock<Duration>,
        operation: @escaping @Sendable () async throws -> Value
    ) async -> Value? {
        let race = FirstFinish<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let work = Task {
                    race.finish(with: try? await operation())
                }
                let timer = Task {
                    try? await clock.sleep(for: timeout)
                    race.finish(with: nil)
                }
                race.start(continuation) {
                    work.cancel()
                    timer.cancel()
                }
            }
        } onCancel: {
            race.finish(with: nil)
        }
    }
}

/// The single resumption point for `AddBodegaViewModel.firstFinished`: the
/// first `finish(with:)` wins and later ones are ignored. Either call may
/// come first (a cancellation can beat `start`), so an early result is held
/// until the continuation exists.
nonisolated private final class FirstFinish<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var cancelLosers: (@Sendable () -> Void)?
    private var early: Value??
    private var isDone = false

    func start(_ continuation: CheckedContinuation<Value?, Never>, cancelLosers: @escaping @Sendable () -> Void) {
        let early: Value?? = lock.withLock {
            if let early = self.early {
                isDone = true
                return early
            }
            self.continuation = continuation
            self.cancelLosers = cancelLosers
            return nil
        }
        guard let early else { return }
        cancelLosers()
        continuation.resume(returning: early)
    }

    func finish(with value: Value?) {
        let winner: (CheckedContinuation<Value?, Never>, (@Sendable () -> Void)?)? = lock.withLock {
            guard !isDone, early == nil else { return nil }
            guard let continuation else {
                early = .some(value)
                return nil
            }
            isDone = true
            self.continuation = nil
            return (continuation, cancelLosers)
        }
        guard let (continuation, cancelLosers) = winner else { return }
        cancelLosers?()
        continuation.resume(returning: value)
    }
}
