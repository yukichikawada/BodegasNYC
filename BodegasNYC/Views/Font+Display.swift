import SwiftUI

extension Font {
    /// DESIGN.md D5 display register: SF Pro heavy, condensed width.
    /// Used on exactly three surfaces: onboarding page titles, the
    /// first-add card title, and the bodega name in the detail header.
    /// Nothing else changes width.
    static func display(_ style: Font.TextStyle) -> Font {
        .system(style, weight: .heavy).width(.condensed)
    }
}
