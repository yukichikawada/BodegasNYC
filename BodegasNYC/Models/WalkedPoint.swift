import Foundation
import SwiftData

/// A single raw GPS fix recorded while streets-walked tracking is enabled
/// (`docs/PRD.md` §5). Deliberately just a point: raw history is kept
/// forever (until Clear History) and map-matched into `WalkedBlock` masks
/// by `BlockMatchingActor` (#108), so a matcher or data change can always
/// rebuild from it.
@Model
final class WalkedPoint {
    #Index<WalkedPoint>([\.isMatched], [\.recordedAt])

    var id: UUID
    var latitude: Double
    var longitude: Double
    var recordedAt: Date
    /// Whether a saved match pass has folded this fix into the masks (#108
    /// eng R8). Flipped in the same `save()` as the mask writes, so a crash
    /// never leaves the two out of step. History from before #108 migrates
    /// as `false` and is backfilled.
    var isMatched: Bool = false
    /// What Motion & Fitness said about the leg that ends at this fix, as a
    /// `RideEvidence` raw value, saved when a pass first can answer (#170).
    /// CoreMotion forgets after 7 days, so a later rebuild reads this
    /// instead. The default lets 1.0.0 stores migrate lightweight as unknown.
    var storedRide: Int = 0
    /// The import that added this fix (#180 eng E3): one new UUID per
    /// commit, `nil` on every fix this phone recorded. Not shown, not
    /// exported; kept so a mistaken import can be undone later (`TODOS.md`).
    /// Optional with a nil default, so older stores migrate lightweight.
    var importBatch: UUID?

    init(id: UUID = UUID(), latitude: Double, longitude: Double, recordedAt: Date) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.recordedAt = recordedAt
    }

    var ride: RideEvidence {
        get { RideEvidence(rawValue: storedRide) ?? .unknown }
        set { storedRide = newValue.rawValue }
    }
}

/// Whether the leg ending at a fix was a ride, as CoreMotion answered while
/// it still could (#170). `.unknown` falls back to the activity of the pass.
nonisolated enum RideEvidence: Int, Sendable {
    case unknown = 0
    case walking = 1
    case ride = 2
    /// Imported from a file with no evidence (#180 eng E2): another phone
    /// recorded it, so this phone's CoreMotion is never asked about its leg
    /// (the speed rule alone judges it), no pass overwrites it, and its day
    /// is an estimate at any age.
    case imported = 3
}
