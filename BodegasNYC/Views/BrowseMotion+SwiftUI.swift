import SwiftUI

// The SwiftUI side of `BrowseMotion`'s pure decisions (#23): each style maps
// to its transition here, so the views never restate a duration or curve.

extension BrowseMotion.ListStyle {
    /// Move only, no opacity: the list page is opaque, so the map never
    /// ghosts through it mid-slide.
    var transition: AnyTransition {
        switch self {
        case .slide: .move(edge: .bottom)
        case .fade: .opacity
        }
    }
}

extension BrowseMotion.SlotStyle {
    var transition: AnyTransition {
        switch self {
        case .moveAndFade: .move(edge: .bottom).combined(with: .opacity)
        case .fade: .opacity
        }
    }
}

extension BrowseMotion.Crosshair {
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .scale(scale: entranceScale).combined(with: .opacity),
                removal: .opacity
            )
    }

    /// Keyed on the new value of `isPlacing`, so landing and leaving each get
    /// their own curve: the pin's spring (a 0.2s fade under Reduce Motion) in,
    /// a 0.15s fade out.
    static func animation(isPlacing: Bool, reduceMotion: Bool) -> Animation {
        guard isPlacing else { return .easeOut(duration: fadeOutSeconds) }
        return reduceMotion
            ? .easeInOut(duration: fadeInSeconds)
            : .spring(duration: springSeconds, bounce: springBounce)
    }
}
