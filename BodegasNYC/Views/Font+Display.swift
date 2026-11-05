import SwiftUI

// `nonisolated`: a pure `Font` value, called from synchronous Swift Testing
// cases, which Xcode 27.2's compiler rejects under default main-actor isolation.
nonisolated extension Font {
    /// DESIGN.md D5 display register: SF Pro heavy, condensed width.
    /// Used on exactly three surfaces: onboarding page titles, the
    /// first-add card title, and the bodega name in the detail header.
    /// Nothing else changes width.
    static func display(_ style: Font.TextStyle) -> Font {
        .system(style, weight: .heavy).width(.condensed)
    }
}
