import CoreGraphics
import Foundation
import SwiftUI

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

// MARK: - Pin to detail (#23 T1)

extension BrowseMotion {
    /// Declared at top level and aliased here so its `Phase`/`Event`/`Effect`
    /// stay within SwiftLint's one level of nesting.
    typealias PinToDetail = PinToDetailMotion
}

/// `BrowseMotion.PinToDetail`. Pin → detail: the tapped pin takes its
/// selected look and holds, the detail zooms out of it, and after the pop
/// shrinks the detail back into it the pin relaxes. `MapScreenView` owns the
/// phase and the one timer; this type only decides what each event does.
nonisolated enum PinToDetailMotion {
    /// 0.15s `easeOut` into the selected look plus 0.10s at rest, so the pin
    /// and its label are seen still before the page grows (design review 4A).
    static let holdSeconds: TimeInterval = 0.25
    /// The measured back-button zoom pop on the branch simulator plus 0.1s,
    /// rounded to 0.05s (DESIGN.md Motion), so the pin relaxes just after
    /// the page has shrunk into it.
    static let releaseSeconds: TimeInterval = 0.4
    /// The R6 fallback switch: false ships the standard push with the same
    /// hold and release; the zoom code stays in place.
    static let zoomEnabled = true

    enum Phase: Equatable {
        case idle
        case holding(Bodega)
        case presented(Bodega)
        case releasing(Bodega)

        /// The held pin, in every phase but `idle`.
        var bodega: Bodega? {
            switch self {
            case .idle: nil
            case .holding(let bodega), .presented(let bodega), .releasing(let bodega): bodega
            }
        }
    }

    /// No `deselected` event: `MapScreenView` resets MapKit's selection to
    /// nil after every tap and ignores nil, so its own reset can never cancel
    /// the hold it just started.
    enum Event: Equatable {
        case pinTapped(Bodega)
        case clusterTapped
        case holdElapsed(Bodega.ID)
        /// `path` emptied: the back button or a completed swipe-back. A
        /// cancelled swipe never changes `path`, so never sends this.
        case detailDismissed
        case releaseElapsed(Bodega.ID)
        /// Placement mode entered or the List tab chosen.
        case interrupted
    }

    enum Effect: Equatable {
        case scheduleHold(Bodega.ID)
        case push(Bodega)
        case scheduleRelease(Bodega.ID)
        case cancelTimer
    }

    static func reduce(_ phase: Phase, _ event: Event) -> (Phase, [Effect]) {
        switch (phase, event) {
        case (.idle, .pinTapped(let bodega)):
            return (.holding(bodega), [.scheduleHold(bodega.id)])

        case (.holding(let held), .holdElapsed(let id)) where id == held.id:
            return (.presented(held), [.push(held)])
        case (.holding(let held), .pinTapped(let other)) where other.id != held.id:
            return (.holding(other), [.cancelTimer, .scheduleHold(other.id)])
        case (.holding, .clusterTapped), (.holding, .interrupted):
            return (.idle, [.cancelTimer])

        case (.presented(let held), .detailDismissed):
            return (.releasing(held), [.scheduleRelease(held.id)])
        case (.presented, .interrupted):
            return (.idle, [.cancelTimer])

        case (.releasing(let held), .releaseElapsed(let id)) where id == held.id:
            return (.idle, [])
        case (.releasing, .pinTapped(let bodega)):
            return (.holding(bodega), [.cancelTimer, .scheduleHold(bodega.id)])
        case (.releasing, .interrupted):
            return (.idle, [.cancelTimer])

        default:
            // Stale `*Elapsed` ids, a re-tap of the pin already being held,
            // and anything else a phase doesn't answer: unchanged.
            return (phase, [])
        }
    }
}

extension View {
    /// The pushed detail's transition: the zoom from the held pin's anchor
    /// (`MapScreenView`) for a push from the Map tab, the standard push for a
    /// list row. Not applied unconditionally (spec R5): on iOS 26 a zoom with
    /// no live source still zooms, out of the screen's centre, instead of
    /// falling back to the push. `fromMap` cannot change while a detail is up
    /// (the tab control is not on the detail), so the modifier is never
    /// swapped mid-push or mid-pop.
    @ViewBuilder
    func pinToDetailTransition(sourceID: Bodega.ID, in namespace: Namespace.ID, fromMap: Bool) -> some View {
        if BrowseMotion.PinToDetail.zoomEnabled, fromMap {
            navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }
}
