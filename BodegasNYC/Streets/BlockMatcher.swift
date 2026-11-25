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
        matchByDay(points, grid: grid, activity: activity).masks
    }

    /// One walk day's share of a match (#170 spec rule 2).
    struct DayDelta: Equatable, Sendable {
        var masks: [UInt32: UInt16] = [:]
        /// The day's street meters (#192 eng E1, E2): each creditable leg
        /// adds the shorter of its straight length and the distance between
        /// its two ends' snapped positions, nothing when either end is more
        /// than 30 m from every block, and nothing when its end fix is
        /// standing still (`isDwelling`). Repeats count.
        var meters: Double = 0
    }

    /// A match split by walk day: each leg belongs to the day of its end fix
    /// (`WalkedDayKey`), and `masks` is the OR of the day masks, so it equals
    /// what `match` always returned.
    struct MatchResult: Equatable, Sendable {
        var masks: [UInt32: UInt16] = [:]
        var days: [WalkedDayKey: DayDelta] = [:]
    }

    /// `match`, keeping each leg's day and street meters. The current day's
    /// interval is kept and recomputed only when a leg's end fix falls
    /// outside it, so a long history costs about one calendar call per day
    /// (eng A7). Legs are formed only for end indexes from `firstLegEnd`;
    /// the fixes before it are context an incremental pass loaded for the
    /// standing-still look-back (#192 eng E3), so the same history gives
    /// the same meters in any batching. Each fix is snapped once.
    static func matchByDay(
        _ points: [WalkedPointSnapshot],
        grid: StreetGrid,
        activity: VehicleActivity = .unavailable,
        firstLegEnd: Int = 1
    ) -> MatchResult {
        var result = MatchResult()
        let firstEnd = max(1, firstLegEnd)
        guard points.count > firstEnd else { return result }
        var current: (key: WalkedDayKey, interval: DateInterval)?
        var delta = DayDelta()
        func flush() {
            guard let key = current?.key else { return }
            result.days[key, default: DayDelta()].meters += delta.meters
            result.days[key, default: DayDelta()].masks.merge(delta.masks) { $0 | $1 }
            delta = DayDelta()
        }
        var startSnapped = snappedPosition(of: points[firstEnd - 1].coordinate, grid: grid)
        for index in firstEnd ..< points.count {
            let start = points[index - 1]
            let end = points[index]
            let endSnapped = snappedPosition(of: end.coordinate, grid: grid)
            defer { startSnapped = endSnapped }
            guard isCreditableLeg(from: start, to: end, activity: activity) else { continue }
            let time = end.recordedAt
            if let interval = current?.interval, interval.start <= time, time < interval.end {
                // Same day: keep accumulating.
            } else {
                flush()
                let key = WalkedDayKey(date: time)
                current = (key, key.interval)
            }
            delta.meters += streetMeters(points, endingAt: index, from: startSnapped, to: endSnapped)
            creditLeg(from: start.coordinate, to: end.coordinate, grid: grid, into: &delta.masks)
        }
        flush()
        for day in result.days.values {
            result.masks.merge(day.masks) { $0 | $1 }
        }
        return result
    }

    // MARK: Street meters (#192)

    /// The look-back window for standing still (#192 spec rule 2).
    static let dwellWindowSeconds: TimeInterval = 300
    /// Every fix in the window within this of the end fix means standing still.
    static let dwellRadiusMeters = 50.0
    /// The fixes read must reach back at least this far.
    static let dwellMinimumSpanSeconds: TimeInterval = 240
    /// At most this many fixes before the end fix are read (#192 eng E3), so
    /// a dense imported file costs at most this many distances a leg.
    static let dwellMaxFixes = 64

    /// A fix's snapped position (#192 eng E1): the point on its nearest
    /// block within 30 m (`StreetGrid.nearestSegment`, same tie rule), or
    /// `nil` when it is unmatched.
    static func snappedPosition(of coordinate: Coordinate, grid: StreetGrid) -> Coordinate? {
        grid.nearestSegment(to: coordinate, within: matchRadiusMeters)?.coordinate
    }

    /// The street meters of the creditable leg ending at `index` (#192 eng
    /// E1, E2): `min(straight, snapped distance)`, or 0 when either end is
    /// unmatched or the end fix is dwelling. A leg that cuts a corner
    /// measures the diagonal between its snapped ends (accepted, E1).
    static func streetMeters(
        _ points: [WalkedPointSnapshot],
        endingAt index: Int,
        from startSnapped: Coordinate?,
        to endSnapped: Coordinate?
    ) -> Double {
        guard let startSnapped, let endSnapped else { return 0 }
        let straight = distance(points[index - 1].coordinate, points[index].coordinate)
        let meters = min(straight, distance(startSnapped, endSnapped))
        guard meters > 0, !isDwelling(points, at: index) else { return 0 }
        return meters
    }

    /// Whether the fix at `index` is standing still (#192 spec rule 2, eng
    /// E3): of the at most `dwellMaxFixes` fixes before it in history order,
    /// those recorded within `dwellWindowSeconds` before it reach back at
    /// least `dwellMinimumSpanSeconds` and all lie within
    /// `dwellRadiusMeters` of it. Looks back only, so batching cannot
    /// change the answer; fixes that end no creditable leg still count.
    static func isDwelling(_ points: [WalkedPointSnapshot], at index: Int) -> Bool {
        let end = points[index]
        let windowStart = end.recordedAt.addingTimeInterval(-dwellWindowSeconds)
        let lowest = max(0, index - dwellMaxFixes)
        var earliest: Date?
        var lookBack = index - 1
        while lookBack >= lowest, points[lookBack].recordedAt >= windowStart {
            guard distance(points[lookBack].coordinate, end.coordinate) <= dwellRadiusMeters else { return false }
            earliest = points[lookBack].recordedAt
            lookBack -= 1
        }
        guard let earliest else { return false }
        return end.recordedAt.timeIntervalSince(earliest) >= dwellMinimumSpanSeconds
    }

    /// Whether a leg can earn bins: same walk (20 min, 250 m), at most 60 m,
    /// walking speed (a zero-duration leg only under 5 m), and not during a
    /// ride CoreMotion saw. Evidence saved on the end fix wins over
    /// `activity`, so a rebuild after CoreMotion's window repeats the
    /// original decision (#170).
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
        switch end.ride {
        case .ride: return false
        // Imported with no evidence (#180 eng E2): the speed rule above
        // alone, never this phone's CoreMotion.
        case .walking, .imported: return true
        case .unknown: return !activity.isRide(from: start.recordedAt, to: end.recordedAt)
        }
    }

    /// The ride evidence to save, keyed by each leg's end fix (#170): legs
    /// whose end is still unknown and whose start `activity` covers. The
    /// rest are left out and stay unknown, so no coverage saves nothing. An
    /// `.imported` end is never unknown, so it is never overwritten (#180
    /// eng E2).
    static func evidence(_ points: [WalkedPointSnapshot], activity: VehicleActivity) -> [UUID: RideEvidence] {
        guard let coverage = activity.coverage, points.count >= 2 else { return [:] }
        var result: [UUID: RideEvidence] = [:]
        for index in 1 ..< points.count {
            let start = points[index - 1]
            let end = points[index]
            guard end.ride == .unknown, coverage.contains(start.recordedAt) else { continue }
            result[end.id] = activity.isRide(from: start.recordedAt, to: end.recordedAt) ? .ride : .walking
        }
        return result
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
