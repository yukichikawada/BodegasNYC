import Foundation

/// Periods CoreMotion classed as a ride (#108 eng R6): automotive or cycling
/// at medium confidence or better. `coverage` is the span CoreMotion could
/// answer for (its 7-day window); a leg outside it, or no coverage at all
/// (denied, unavailable), falls back to the speed rule alone.
nonisolated struct VehicleActivity: Sendable, Equatable {
    var intervals: [DateInterval]
    var coverage: DateInterval?

    static let unavailable = VehicleActivity(intervals: [], coverage: nil)

    /// Whether the leg `start...end` overlaps a ride. Only legs that start
    /// inside the coverage are judged; the rest are the speed rule's.
    func isRide(from start: Date, to end: Date) -> Bool {
        guard let coverage, coverage.contains(start) else { return false }
        return intervals.contains { interval in
            start == end
                ? interval.start <= start && start <= interval.end
                : interval.start < end && start < interval.end
        }
    }
}

/// Map-matching for Streets Walked (#108, spec Implementation 3): turns raw
/// fixes into per-block bin masks. Pure and synchronous; the same history in
/// any batching gives the same masks, because a fix credits nothing on its
/// own, only legs do, and the last matched fix closes the next batch's first
/// leg.
nonisolated enum BlockMatcher {
    /// A leg is sampled at both ends and at most this far apart between.
    static let sampleSpacingMeters = 2.0
    /// Half the 60 m minimum Manhattan street spacing.
    static let matchRadiusMeters = 30.0
    /// 14.4 km/h: running counts, driving and most cycling do not.
    static let maxWalkingSpeedMetersPerSecond = 4.0
    /// Longer legs credit nothing: pauses, subway gaps, GPS dropouts (eng R7).
    static let maxLegMeters = 60.0
    /// A zero-duration leg counts only under this length.
    static let zeroDurationMaxMeters = 5.0
    static let binCount = 10
    /// Walked = at least 6 of the block's 10 tenths touched.
    static let walkedBinThreshold = 6

    /// Bin masks for `points`, which must be in history order
    /// (`WalkedPointSnapshot.sortsBefore`). Keys are `physicalid`s.
    static func match(
        _ points: [WalkedPointSnapshot],
        grid: StreetGrid,
        activity: VehicleActivity = .unavailable
    ) -> [UInt32: UInt16] {
        var masks: [UInt32: UInt16] = [:]
        guard points.count >= 2 else { return masks }
        for index in 1 ..< points.count {
            let start = points[index - 1]
            let end = points[index]
            guard isCreditableLeg(from: start, to: end, activity: activity) else { continue }
            creditLeg(from: start.coordinate, to: end.coordinate, grid: grid, into: &masks)
        }
        return masks
    }

    /// Whether a leg can earn bins: same walk (20 min, 250 m), at most 60 m,
    /// walking speed (a zero-duration leg only under 5 m), and not during a
    /// ride CoreMotion saw.
    static func isCreditableLeg(
        from start: WalkedPointSnapshot,
        to end: WalkedPointSnapshot,
        activity: VehicleActivity
    ) -> Bool {
        let seconds = end.recordedAt.timeIntervalSince(start.recordedAt)
        let meters = distance(start.coordinate, end.coordinate)
        guard seconds >= 0,
              seconds <= StreetsWalkedViewModel.walkGapSeconds,
              meters <= StreetsWalkedViewModel.walkGapMeters,
              meters <= maxLegMeters
        else { return false }
        if seconds == 0 {
            guard meters < zeroDurationMaxMeters else { return false }
        } else if meters / seconds > maxWalkingSpeedMetersPerSecond {
            return false
        }
        return !activity.isRide(from: start.recordedAt, to: end.recordedAt)
    }

    /// Samples the leg and ORs each sample's bin into its nearest block.
    /// Consecutive samples on the same block also fill every tenth between
    /// them (eng R10), so a short block walked end to end is walked.
    static func creditLeg(
        from start: Coordinate,
        to end: Coordinate,
        grid: StreetGrid,
        into masks: inout [UInt32: UInt16]
    ) {
        let meters = distance(start, end)
        let steps = max(1, Int((meters / sampleSpacingMeters).rounded(.up)))
        var previous: (segment: Int, bin: Int)?
        for step in 0 ... steps {
            let progress = Double(step) / Double(steps)
            let sample = Coordinate(
                latitude: start.latitude + (end.latitude - start.latitude) * progress,
                longitude: start.longitude + (end.longitude - start.longitude) * progress
            )
            guard let match = grid.nearestSegment(to: sample, within: matchRadiusMeters) else {
                previous = nil
                continue
            }
            let bin = self.bin(for: match.fraction)
            var bits = UInt16(1) << UInt16(bin)
            if let previous, previous.segment == match.segment {
                for filled in min(previous.bin, bin) ... max(previous.bin, bin) {
                    bits |= UInt16(1) << UInt16(filled)
                }
            }
            masks[grid.physicalIDs[match.segment], default: 0] |= bits
            previous = (match.segment, bin)
        }
    }

    /// The tenth of the block a projection lands in: `min(9, floor(f * 10))`.
    /// A position within `binSnap` of a tenth's boundary (a few micrometres
    /// on a city block) counts as on it, so the same boundary never lands in
    /// the lower tenth at one end of a walk and the upper at the other
    /// because of floating-point noise in the projection.
    static func bin(for fraction: Double) -> Int {
        min(binCount - 1, max(0, Int((fraction * Double(binCount) + binSnap).rounded(.down))))
    }

    static let binSnap = 1e-6

    static func isWalked(mask: UInt16) -> Bool {
        (mask & 0x3FF).nonzeroBitCount >= walkedBinThreshold
    }

    /// Local equirectangular distance in metres.
    static func distance(_ lhs: Coordinate, _ rhs: Coordinate) -> Double {
        let meanLatitude = (lhs.latitude + rhs.latitude) / 2 * .pi / 180
        let deltaX = (rhs.longitude - lhs.longitude) * cos(meanLatitude) * StreetGrid.metersPerDegreeLongitudeAtEquator
        let deltaY = (rhs.latitude - lhs.latitude) * StreetGrid.metersPerDegreeLatitude
        return (deltaX * deltaX + deltaY * deltaY).squareRoot()
    }
}
