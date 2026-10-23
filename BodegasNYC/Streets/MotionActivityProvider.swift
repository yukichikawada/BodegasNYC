import CoreMotion
import Foundation

/// Motion & Fitness, behind a seam so the matcher's ride filter is testable
/// without CoreMotion (#108 eng R6).
nonisolated protocol MotionActivityProviding: Sendable {
    var authorization: MotionAuthorization { get }
    /// Shows the system Motion & Fitness prompt if it has never been
    /// answered (design D6: only right after Start Recording succeeds).
    func requestAuthorization() async
    /// Rides between `start` and `end`, or `.unavailable` when Motion &
    /// Fitness is denied, not determined or unsupported. Never prompts.
    func vehicleActivity(from start: Date, to end: Date) async -> VehicleActivity
}

nonisolated enum MotionAuthorization: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case unavailable
}

/// The live provider: `CMMotionActivityManager`, queried per pass. CoreMotion
/// keeps 7 days of activity, so a leg older than that is the speed rule's.
nonisolated struct CoreMotionActivityProvider: MotionActivityProviding {
    static let historyWindow: TimeInterval = 7 * 24 * 60 * 60

    var authorization: MotionAuthorization {
        guard CMMotionActivityManager.isActivityAvailable() else { return .unavailable }
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async {
        guard authorization == .notDetermined else { return }
        // CoreMotion has no request call: the first query shows the prompt,
        // and its handler runs once the person answers.
        let now = Date()
        _ = await query(from: now.addingTimeInterval(-60), to: now)
    }

    func vehicleActivity(from start: Date, to end: Date) async -> VehicleActivity {
        guard authorization == .authorized else { return .unavailable }
        let windowStart = max(start, Date().addingTimeInterval(-Self.historyWindow))
        guard windowStart < end, let samples = await query(from: windowStart, to: end) else {
            return .unavailable
        }
        return VehicleActivity(
            intervals: Self.rideIntervals(samples, until: end),
            coverage: DateInterval(start: windowStart, end: end)
        )
    }

    /// One CoreMotion activity entry, copied out of the non-Sendable class.
    struct Sample: Sendable, Equatable {
        var startDate: Date
        var isRide: Bool
    }

    /// Each entry lasts until the next one starts; rides are automotive or
    /// cycling at medium confidence or better.
    static func rideIntervals(_ samples: [Sample], until end: Date) -> [DateInterval] {
        var intervals: [DateInterval] = []
        for (index, sample) in samples.enumerated() where sample.isRide {
            let stop = index + 1 < samples.count ? samples[index + 1].startDate : end
            if stop >= sample.startDate {
                intervals.append(DateInterval(start: sample.startDate, end: stop))
            }
        }
        return intervals
    }

    private func query(from start: Date, to end: Date) async -> [Sample]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Sample]?, Never>) in
            let manager = CMMotionActivityManager()
            manager.queryActivityStarting(from: start, to: end, to: OperationQueue()) { activities, error in
                // Keeps the manager alive until its handler runs.
                withExtendedLifetime(manager) {}
                guard error == nil, let activities else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: activities.map {
                    Sample(
                        startDate: $0.startDate,
                        isRide: ($0.automotive || $0.cycling) && $0.confidence != .low
                    )
                })
            }
        }
    }
}
