import CoreGraphics
import Foundation

/// Every browse-session motion constant and pure motion decision (#23), in
/// one place so the timings DESIGN.md's Motion section records have one
/// source and are unit-tested (`BrowseMotionTests`). `AnyTransition` and
/// `Animation` are not inspectable, so each decision is a small value type
/// the views map to SwiftUI transitions.
///
/// PR 1 ("map stays put") adds `ListTransition`, `BottomSlot` and
/// `crosshairY`; PR 2 ("zoom from the pin") adds `PinToDetail` here.
nonisolated enum BrowseMotion {
    // Styles sit at this level, not inside their decision, to stay within
    // SwiftLint's one level of type nesting.

    // MARK: List over the live map (#23 T2)

    enum ListStyle: Equatable, Sendable {
        case slide
        case fade
    }

    /// How the List tab's page enters and leaves over the always-mounted
    /// map: a slide from the bottom edge with no opacity (the page is opaque,
    /// so the map never ghosts through it), or a plain fade when the user has
    /// Reduce Motion or Prefer Cross-Fade Transitions on.
    enum ListTransition {
        static let slideSeconds: TimeInterval = 0.3
        static let fadeSeconds: TimeInterval = 0.25

        static func style(reduceMotion: Bool, crossFade: Bool) -> ListStyle {
            reduceMotion || crossFade ? .fade : .slide
        }

        /// Also how long placement waits after leaving the List tab, so the
        /// list is gone before the crosshair lands (design review 3A).
        static func duration(reduceMotion: Bool, crossFade: Bool) -> TimeInterval {
            switch style(reduceMotion: reduceMotion, crossFade: crossFade) {
            case .slide: slideSeconds
            case .fade: fadeSeconds
            }
        }
    }

    // MARK: The map's bottom slot (#23 T3)

    enum SlotStyle: Equatable, Sendable {
        /// From the bottom edge with opacity.
        case moveAndFade
        /// Opacity only, in place (Reduce Motion).
        case fade
    }

    /// The one floating object in the map's bottom slot. The placement card
    /// outranks every `MapBottomCard` content (DESIGN.md Layout: Density);
    /// the value is the slot's `.animation` key, so any change of occupant
    /// runs the slot transition.
    enum BottomSlot: Hashable, Sendable {
        case placing
        case card(MapBottomCard.Content)
        case empty

        /// The DD13 slot transition, 0.25s ease-in-out in both styles.
        static let transitionSeconds: TimeInterval = 0.25
        /// The placement tip waits for the card to be at rest, so the
        /// popover anchors to a button that has stopped moving.
        static let placementTipDelaySeconds: TimeInterval = 0.3

        static func select(isPlacing: Bool, card: MapBottomCard.Content?) -> BottomSlot {
            if isPlacing { return .placing }
            if let card { return .card(card) }
            return .empty
        }

        static func style(reduceMotion: Bool) -> SlotStyle {
            reduceMotion ? .fade : .moveAndFade
        }
    }

    // MARK: Placement crosshair (#23 T3)

    /// The crosshair lands like a dropped pin (DESIGN.md Pin: spring 0.5s,
    /// bounce 0.35, from 0.6 scale); under Reduce Motion it fades in over
    /// 0.2s, the pin-drop rule. It always fades out over 0.15s.
    enum Crosshair {
        static let entranceScale: CGFloat = 0.6
        static let springSeconds: TimeInterval = 0.5
        static let springBounce: Double = 0.35
        static let fadeInSeconds: TimeInterval = 0.2
        static let fadeOutSeconds: TimeInterval = 0.15
    }

    /// The crosshair's vertical centre, in the map's local coordinates: the
    /// middle of the band the placement card leaves uncovered, i.e. between
    /// the map's top edge and the card's top edge (`mapHeight - cardHeight -
    /// clearance`). Clamped at 0 so a card taller than the map (landscape at
    /// accessibility sizes) never pushes it off the top.
    static func crosshairY(mapHeight: CGFloat, cardHeight: CGFloat, clearance: CGFloat) -> CGFloat {
        max(0, (mapHeight - cardHeight - clearance) / 2)
    }
}
