import CoreLocation
import Foundation

/// A plain, framework-free snapshot of a `WalkedPoint` — lets
/// `StreetsWalkedViewModel.segments(from:)` stay pure and directly testable
/// without any `SwiftData`/`@Model` dependency (`@Model` classes carry
/// reference-identity semantics that have no place in pure value logic).
nonisolated struct WalkedPointSnapshot: Sendable, Equatable {
    var coordinate: Coordinate
    var recordedAt: Date
    /// The `WalkedPoint`'s id: the tie-break when two fixes share a
    /// timestamp, so every pass orders history the same way (#108).
    var id = UUID()

    /// History order (#108): `recordedAt`, then `id`.
    static func sortsBefore(_ lhs: WalkedPointSnapshot, _ rhs: WalkedPointSnapshot) -> Bool {
        lhs.recordedAt != rhs.recordedAt ? lhs.recordedAt < rhs.recordedAt : lhs.id < rhs.id
    }
}

extension StreetsWalkedViewModel {
    /// The walk-gap rule: consecutive fixes further apart than this in time
    /// or distance belong to different walks. `BlockMatcher` breaks legs on
    /// the same thresholds (#108).
    nonisolated static let walkGapSeconds: TimeInterval = 20 * 60
    nonisolated static let walkGapMeters: Double = 250

    /// Splits `points` (must already be sorted chronologically) into
    /// separate polylines wherever the gap to the next point exceeds
    /// `maxGapSeconds` or `maxGapMeters` — otherwise a single flat polyline
    /// across all-time history would draw a bogus straight line connecting
    /// unrelated walks (e.g. Monday near home, Wednesday across town).
    ///
    /// Pure and synchronous: no `CLLocationManager`/SwiftData dependency,
    /// so it's directly unit-testable (see `WalkedPathSegmentingTests`).
    /// Drops any resulting segment with fewer than 2 points — a single
    /// point isn't a renderable `MapPolyline`.
    nonisolated static func segments(
        from points: [WalkedPointSnapshot],
        maxGapSeconds: TimeInterval = walkGapSeconds,
        maxGapMeters: Double = walkGapMeters
    ) -> [[Coordinate]] {
        guard let first = points.first else { return [] }

        var result: [[Coordinate]] = []
        var current: [Coordinate] = [first.coordinate]

        for (previous, next) in zip(points, points.dropFirst()) {
            let gapSeconds = next.recordedAt.timeIntervalSince(previous.recordedAt)
            let gapMeters = CLLocation(latitude: previous.coordinate.latitude, longitude: previous.coordinate.longitude)
                .distance(from: CLLocation(latitude: next.coordinate.latitude, longitude: next.coordinate.longitude))

            if gapSeconds > maxGapSeconds || gapMeters > maxGapMeters {
                if current.count > 1 {
                    result.append(current)
                }
                current = [next.coordinate]
            } else {
                current.append(next.coordinate)
            }
        }

        if current.count > 1 {
            result.append(current)
        }

        return result
    }
}
