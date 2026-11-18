import Foundation
import SwiftData

/// One block's tenths walked on one walk day (#170): a derived cache of
/// `WalkedPoint` history beside `WalkedBlock`'s totals, written by the same
/// match pass in the same `save()`. A block's total mask is the OR of its
/// day masks (eng E4, A2). `day` is a `WalkedDayKey` value.
@Model
final class WalkedDayBlock {
    #Unique<WalkedDayBlock>([\.day, \.storedPhysicalID])
    #Index<WalkedDayBlock>([\.day])

    var day: Int
    var storedPhysicalID: Int
    var storedMask: Int

    init(day: WalkedDayKey, physicalID: UInt32, mask: UInt16) {
        self.day = day.value
        storedPhysicalID = Int(physicalID)
        storedMask = Int(mask)
    }

    var dayKey: WalkedDayKey { WalkedDayKey(value: day) }

    var physicalID: UInt32 { UInt32(truncatingIfNeeded: storedPhysicalID) }

    var mask: UInt16 {
        get { UInt16(truncatingIfNeeded: storedMask) }
        set { storedMask = Int(newValue) }
    }
}

/// One walk day's distance (#170 spec rule 2): the summed length of that
/// day's creditable legs, whether or not they matched a block.
@Model
final class WalkedDay {
    #Unique<WalkedDay>([\.day])

    var day: Int
    var meters: Double

    init(day: WalkedDayKey, meters: Double) {
        self.day = day.value
        self.meters = meters
    }

    var dayKey: WalkedDayKey { WalkedDayKey(value: day) }
}
