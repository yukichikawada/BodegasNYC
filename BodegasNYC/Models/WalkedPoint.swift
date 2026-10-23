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

    init(id: UUID = UUID(), latitude: Double, longitude: Double, recordedAt: Date) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.recordedAt = recordedAt
    }
}
