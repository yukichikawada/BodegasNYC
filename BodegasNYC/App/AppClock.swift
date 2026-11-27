import Foundation

/// "Now" for walk days: which day is today in Your Walks, the Progress
/// ranges, Share a Walk's last day, and the matching store's ride-evidence
/// window. In Release it is the system clock and nothing else.
///
/// In a DEBUG build launched with `-UITestFixtures -UITestNow <ISO 8601>`
/// it is that instant, frozen (#201), so a UI test can pin the hour and
/// date the walk day turns on (before 4 am, the first of a month) instead
/// of depending on when it happens to run. The simulator's own clock, and
/// so the date picker's idea of today, still follows the host.
nonisolated enum AppClock {
    static func now() -> Date {
        #if DEBUG
        if let pinned = UITestFixtures.pinnedNow { return pinned }
        #endif
        return Date()
    }
}
