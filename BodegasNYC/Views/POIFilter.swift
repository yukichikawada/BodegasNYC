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

    /// The map style both maps draw (#154 D2, AC 1): muted, following the
    /// system appearance. No view forces a colour scheme on a `Map`: the
    /// muted map at night is the night look. The browse map passes
    /// `BodegaMapViewModel.browseMapElevation` (3D buildings when pitched,
    /// #156), the detail preview `.flat`.
    func mapStyle(elevation: MapStyle.Elevation) -> MapStyle {
        .standard(elevation: elevation, emphasis: .muted, pointsOfInterest: categories)
    }
}

extension View {
    /// The browse map's look: its style (`browseMapElevation`, the POI
    /// filter for the zoom) and MapKit's controls (#156 design DS7): the
    /// compass on MapKit's own rule, and the pitch toggle, the way back from
    /// the tilt, only where `showsPitchToggle` says.
    func browseMapLook(isBlockZoom: Bool, showsPitchToggle: Bool) -> some View {
        mapStyle(
            BodegaMapViewModel.poiFilter(isBlockZoom: isBlockZoom)
                .mapStyle(elevation: BodegaMapViewModel.browseMapElevation)
        )
        .mapControls {
            MapCompass()
            MapPitchToggle()
                .mapControlVisibility(showsPitchToggle ? .visible : .hidden)
        }
    }
}
