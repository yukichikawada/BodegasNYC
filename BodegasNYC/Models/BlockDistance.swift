import Foundation

/// How far a bodega is from the user, the way a New Yorker says it (#68):
/// "Around the corner", "2 blocks", or miles once it is past twenty blocks.
/// Pure value; the words live in `AppCopy.distanceValue(_:)` and
/// `AppCopy.distanceFromYou(_:)` so the voice test sees them.
///
/// A block is a Manhattan street block at the "20 blocks to a mile" rule
/// (80.4672 m). Avenue blocks are two to three times longer and are not
/// modelled: the count is direction-blind.
///
/// The distance is straight-line, from the location fix to the pin (eng
/// D12): a folk estimate like every map app's list distance, not blocks
/// walked.
nonisolated enum BlockDistance: Equatable, Sendable {
    case aroundTheCorner
    case blocks(Int)
    case miles(Double)

    static let metersPerMile: Double = 1609.344
    static let metersPerBlock: Double = metersPerMile / 20
    /// The last whole block count that still reads as blocks (design D6):
    /// up to 20.49 blocks (1648.8 m); from 20.5 blocks it is miles.
    static let maxBlocks = 20
    /// "Around the corner" is a claim about a fix good enough to make it
    /// (design D3): a count that rounds to zero needs the fix's horizontal
    /// accuracy at or under this; otherwise it reads "1 block".
    static let maxCornerAccuracyMeters: Double = 50

    /// `nil` for a negative, NaN or infinite distance. `horizontalAccuracy`
    /// is the fix's own (`CLLocation.horizontalAccuracy`, metres); `nil` or a
    /// negative value (invalid) means unknown, which never earns "Around the
    /// corner".
    ///
    /// Schoolbook rounding (`.toNearestOrAwayFromZero`) on a `Double`, and
    /// every branch is decided before any `Int` conversion, so a huge
    /// distance cannot overflow.
    init?(meters: Double, horizontalAccuracy: Double?) {
        guard meters.isFinite, meters >= 0 else { return nil }
        let rounded = (meters / Self.metersPerBlock).rounded(.toNearestOrAwayFromZero)
        if rounded > Double(Self.maxBlocks) {
            self = .miles(meters / Self.metersPerMile)
        } else if rounded == 0 {
            if let horizontalAccuracy, horizontalAccuracy >= 0, horizontalAccuracy <= Self.maxCornerAccuracyMeters {
                self = .aroundTheCorner
            } else {
                self = .blocks(1)
            }
        } else {
            self = .blocks(Int(rounded))
        }
    }
}
