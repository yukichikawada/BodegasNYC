import CoreGraphics
import SwiftUI

/// Which form the toolbar's Map/List switch takes (#44, #143).
///
/// The segmented control needs the room left between the leading filter
/// button and the trailing group (Locate Me, Streets Walked, Account, Add).
/// On iOS 26 that room shrinks two ways:
/// - Dynamic Type: the trailing buttons grow, so at `.xLarge` the segmented
///   control truncates and from `.xxLarge` up the toolbar drops it (#44).
/// - Width: at default text size a 390 pt iPhone (16e, 17e) truncates "Map"
///   to "M…" and a 375 pt one (SE 3rd generation, 13 mini) drops the
///   control, leaving no way to reach the List tab (#143). 402 pt (iPhone 17
///   Pro) and wider show it in full.
///
/// Either way the switch becomes the compact single-button `Menu`, which
/// fits in one 44 pt toolbar slot.
nonisolated enum BrowseModePickerStyle: Equatable {
    case segmented
    case menu

    /// Narrowest browse width, in points, that still fits the segmented
    /// control beside the full map toolbar at default text size.
    static let minimumSegmentedWidth: CGFloat = 400

    /// `width` is the browse screen's width; 0 (not yet measured) keeps the
    /// segmented control, so wide phones never flash the menu on launch.
    static func resolve(dynamicTypeSize: DynamicTypeSize, width: CGFloat) -> Self {
        if dynamicTypeSize >= .xLarge { return .menu }
        if width > 0, width < minimumSegmentedWidth { return .menu }
        return .segmented
    }
}
