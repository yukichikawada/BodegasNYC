import Foundation

/// One walk day (#170 eng A7): a New York date stored as a `yyyymmdd` Int.
/// A day starts at 4:00 am New York wall-clock time, so a 10 pm to 2 am
/// night out is one day. The zone is fixed whatever the device's (the grid
/// is New York only, and a fixed zone keeps stored days stable), and the
/// day comes from calendar components, never from subtracting four hours,
/// so daylight-saving changes do not move the boundary.
nonisolated struct WalkedDayKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// `yyyymmdd`, e.g. 20261103.
    let value: Int

    static let startHour = 4
    static let timeZone = TimeZone(identifier: "America/New_York")!

    /// Gregorian in New York: the only calendar day keys are computed in.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    init(value: Int) {
        self.value = value
    }

    init(year: Int, month: Int, day: Int) {
        value = year * 10_000 + month * 100 + day
    }

    /// The walk day `date` falls in: its New York date, or the date before
    /// when its New York hour is under `startHour`.
    init(date: Date) {
        let calendar = Self.calendar
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let key = WalkedDayKey(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
        self = (parts.hour ?? 0) < Self.startHour ? key.advanced(by: -1) : key
    }

    var year: Int { value / 10_000 }
    var month: Int { value / 100 % 100 }
    var day: Int { value % 100 }

    /// Noon New York time on this date: an instant safely inside the day for
    /// formatting and day arithmetic.
    var noon: Date { wallClock(hour: 12) }

    /// From 4:00 am on this date to 4:00 am on the next, New York time.
    var interval: DateInterval {
        DateInterval(start: wallClock(hour: Self.startHour), end: advanced(by: 1).wallClock(hour: Self.startHour))
    }

    /// The key `days` calendar days later (earlier when negative).
    func advanced(by days: Int) -> WalkedDayKey {
        guard days != 0, let moved = Self.calendar.date(byAdding: .day, value: days, to: noon) else { return self }
        let parts = Self.calendar.dateComponents([.year, .month, .day], from: moved)
        return WalkedDayKey(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    static func < (lhs: WalkedDayKey, rhs: WalkedDayKey) -> Bool { lhs.value < rhs.value }

    var description: String { String(value) }

    private func wallClock(hour: Int) -> Date {
        let parts = DateComponents(year: year, month: month, day: day, hour: hour)
        return Self.calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }
}

/// Which days were rebuilt without saved ride evidence (#170 eng E2): kept
/// apart in one small function because a pending device check may change
/// the rule (very recent legs left unknown and settled on a later pass).
nonisolated enum WalkedEstimate {
    /// CoreMotion's window: an unknown leg older than this can no longer be
    /// asked about, so its day is an estimate.
    static let window = CoreMotionActivityProvider.historyWindow

    /// How far back a pass of `kind` could ask CoreMotion: a backfill never
    /// asks (eng A1), so every unknown leg it matched is an estimate, of any
    /// age; a rebuild or incremental pass asks for the last `window`.
    static func askableWindow(for kind: WalkedPassKind) -> TimeInterval {
        kind == .backfill ? 0 : window
    }

    /// The day of the newest fix whose leg has no ride evidence (saved, or
    /// found by this pass in `found`) and which is older than `window` at
    /// `now` (any fix before `now` when `window` is 0), or of the newest
    /// `.imported` fix at any age (#180 eng E2: this phone could never ask
    /// about it); `nil` when there is none. `points` is in history order
    /// and its first fix ends no leg, so it is skipped.
    static func throughDay(
        _ points: [WalkedPointSnapshot],
        found: [UUID: RideEvidence],
        now: Date,
        window: TimeInterval = window
    ) -> WalkedDayKey? {
        let cutoff = now.addingTimeInterval(-window)
        for point in points.dropFirst().reversed() {
            switch point.ride {
            case .imported:
                return WalkedDayKey(date: point.recordedAt)
            case .unknown where point.recordedAt < cutoff && found[point.id] == nil:
                return WalkedDayKey(date: point.recordedAt)
            default:
                continue
            }
        }
        return nil
    }
}
