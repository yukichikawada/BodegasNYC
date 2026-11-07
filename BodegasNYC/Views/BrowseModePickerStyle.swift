import CoreGraphics
import SwiftUI

/// Which form the toolbar's Map/List switch takes, and where (#44, #143, #160).
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
///
/// On wide layouts (landscape phones, the iPhone Duo's unfolded panel) the
/// trailing group has room for one more glass button, so the switch leaves
/// the centre and becomes a one-tap destination toggle there, between
/// Streets Walked and Account (#160 DS1, DS2).
///
/// `width` is `BrowseView`'s measured browse width: the `NavigationStack`
/// content width inside the safe areas, not the window's (the folded Duo
/// measures about 402 in a 466 pt window; a landscape iPhone 17 Pro is
/// narrower than its 874 pt screen by its side insets).
nonisolated enum BrowseModePickerStyle: Equatable {
    /// Principal slot, text segments.
    case segmented
    /// Principal slot, one 44 pt button wrapping the picker.
    case menu
    /// Trailing group, a one-tap glass button naming the other tab (#160).
    case trailingToggle

    /// Narrowest browse width, in points, that still fits the segmented
    /// control beside the full map toolbar at default text size.
    static let minimumSegmentedWidth: CGFloat = 400

    /// Narrowest browse width at which the switch joins the trailing group
    /// (#160 eng D1): 100 pt above the widest portrait phone (440) and below
    /// the narrowest wide target. Checked before the Dynamic Type gate, so
    /// large text on a wide window still gets the trailing toggle.
    static let minimumTrailingWidth: CGFloat = 540

    /// 0 (not yet measured) keeps the segmented control, so wide phones
    /// never flash the menu on launch (a landscape cold start shows the
    /// centre form for one frame, accepted in #160 DS3).
    static func resolve(dynamicTypeSize: DynamicTypeSize, width: CGFloat) -> Self {
        if width >= minimumTrailingWidth { return .trailingToggle }
        if dynamicTypeSize >= .xLarge { return .menu }
        if width > 0, width < minimumSegmentedWidth { return .menu }
        return .segmented
    }

    var isInTrailingGroup: Bool { self == .trailingToggle }
}
