import MapKit
import SwiftUI

/// Which of Apple's points of interest a map draws (#154 eng D2, design
/// DS8). An enum, not the SDK value, because `PointOfInterestCategories` is
/// not `Equatable` in the iOS 26.5 SDK, so the choice is what the unit test
/// can see.
enum POIFilter: Equatable {
    /// Apple's commercial categories hidden, wayfinding and unclassified
    /// businesses shown: the main map above block zoom (#67 design D1).
    case commercialHidden
    /// Wayfinding only (`BodegaMapViewModel.wayfindingPOICategories`): the
    /// main map at block zoom and the detail preview.
    case wayfindingOnly

    var categories: PointOfInterestCategories {
        switch self {
        case .commercialHidden: .excluding(BodegaMapViewModel.excludedPOICategories)
        case .wayfindingOnly: .including(BodegaMapViewModel.wayfindingPOICategories)
        }
    }

    /// The map style both maps draw (#154 D2, AC 1): flat, muted, following
    /// the system appearance. No view forces a colour scheme on a `Map`: the
    /// muted map at night is the night look.
    var mapStyle: MapStyle {
        .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: categories)
    }
}
