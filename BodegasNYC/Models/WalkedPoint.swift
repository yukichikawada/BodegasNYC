import Foundation
import SwiftData

/// A single raw GPS fix recorded while streets-walked tracking is enabled
/// (`docs/PRD.md` §5). Deliberately just a point, not pre-computed street
/// geometry — no road-snapping/map-matching. Points are grouped into
/// renderable polylines by `StreetsWalkedViewModel.segments(from:)`, not at
/// storage time.
@Model
final class WalkedPoint {
    var id: UUID
    var latitude: Double
    var longitude: Double
    var recordedAt: Date

    init(id: UUID = UUID(), latitude: Double, longitude: Double, recordedAt: Date) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.recordedAt = recordedAt
    }
}
