import Foundation
import SwiftData

/// One street block's walked tenths (#108): a derived cache of `WalkedPoint`
/// history, keyed by the CSCL `physicalid`. Bit `n` of `mask` is the block's
/// `n`th tenth from its start; the block is walked once 6 of the 10 are set
/// (`BlockMatcher.isWalked`). Stored as `Int` columns, read through the
/// typed accessors.
@Model
final class WalkedBlock {
    #Unique<WalkedBlock>([\.storedPhysicalID])

    var storedPhysicalID: Int
    var storedMask: Int

    init(physicalID: UInt32, mask: UInt16) {
        storedPhysicalID = Int(physicalID)
        storedMask = Int(mask)
    }

    var physicalID: UInt32 { UInt32(truncatingIfNeeded: storedPhysicalID) }

    var mask: UInt16 {
        get { UInt16(truncatingIfNeeded: storedMask) }
        set { storedMask = Int(newValue) }
    }
}

/// The singleton record of which bundled street data the `WalkedBlock`
/// masks were matched against (#108 eng R8). Absent, or a stamp that differs
/// from the bundle's, means the cache is rebuilt from all history.
@Model
final class WalkedMatchState {
    var datasetStamp: Int

    init(datasetStamp: UInt32) {
        self.datasetStamp = Int(datasetStamp)
    }
}

/// Every model in the Streets Walked store, in one place for the
/// containers that hold them.
nonisolated enum StreetsWalkedSchema {
    static let models: [any PersistentModel.Type] = [WalkedPoint.self, WalkedBlock.self, WalkedMatchState.self]
}
