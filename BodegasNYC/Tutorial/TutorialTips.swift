import SwiftUI
import TipKit

/// The first-run tutorial (#22): three TipKit coachmarks over the real UI
/// (spec D6/D9), never a scripted walkthrough.
///
/// - `AddBodegaTip`: inline in the map's bottom card slot
///   (`MapBottomCard.Content.addTip`), never a popover on a toolbar item
///   (eng review R1: popover tips don't render on iOS 26 toolbar menus).
/// - `PlacementTip`: popover on "Use This Location" in placement mode.
/// - `FormTip`: inline at the top of the Add a Bodega form (never Edit).
/// - `DistancesTip` (#68, design D4): inline at the top of the loaded list
///   while location is not authorized. Not part of the add tutorial: the
///   first add does not invalidate it; the first published fix does.
///
/// The parameters below are mirrored from `BrowseView` state (on appear and
/// on change). Closing a tip only closes that tip; the first successful add
/// invalidates all three (`invalidateAll`). Nothing else dismisses one.
nonisolated enum TutorialTips {
    /// Mirrors `FirstRunState.hasAddedFirstBodega`. Persisted by TipKit, but
    /// re-mirrored on every appear, so `FirstRunState` stays the truth.
    @Parameter static var hasAddedFirstBodega: Bool = false

    /// Mirrors `RootView`'s onboarding overlay. Transient: reset every
    /// launch, since the overlay is decided fresh each launch.
    @Parameter(.transient) static var isOnboardingVisible: Bool = false

    /// Mirrors `BrowseView.isPlacingBodega`. Transient for the same reason.
    @Parameter(.transient) static var isPlacingBodega: Bool = false

    /// Mirrors `UserLocationProvider.isAuthorized` (#68). Transient: the
    /// system decides authorization, and it is re-mirrored on every appear.
    @Parameter(.transient) static var isLocationAuthorized: Bool = false

    /// Donated each time a bodega detail screen opens, from any path (map
    /// pin or list row; both go through `BrowseView`'s
    /// `navigationDestination`). The Add tip waits for one (design DD4): ask
    /// for a contribution only after the user has looked at one.
    static let didOpenBodegaDetail = Tips.Event(id: "didOpenBodegaDetail")

    /// The Add tip's gating, as a pure function so the truth table is unit
    /// tested without TipKit (`TutorialTipsTests`). `AddBodegaTip.rules`
    /// encode the same four inputs.
    static func shouldOfferAddTip(
        hasAddedFirstBodega: Bool,
        isOnboardingVisible: Bool,
        isPlacingBodega: Bool,
        hasOpenedDetail: Bool
    ) -> Bool {
        !hasAddedFirstBodega && !isOnboardingVisible && !isPlacingBodega && hasOpenedDetail
    }

    /// The Distances tip's gating (#68, design D4), the pure form of
    /// `DistancesTip.rules`: offered only while location is not authorized.
    /// Where it renders (the loaded list with rows) is `BodegaListView`'s.
    static func shouldOfferDistancesTip(isLocationAuthorized: Bool) -> Bool {
        !isLocationAuthorized
    }

    /// The first successful add ends the tutorial: none of the three tips
    /// shows again, including after relaunch.
    static func invalidateAll() {
        AddBodegaTip().invalidate(reason: .actionPerformed)
        PlacementTip().invalidate(reason: .actionPerformed)
        FormTip().invalidate(reason: .actionPerformed)
    }
}

/// What `BrowseView` needs to know about the Add tip beyond its own state.
/// The bottom card shows the tip only when `shouldOfferAddTip` and
/// `isDisplayable` agree, so it never draws an empty card around a tip
/// TipKit won't render.
@Observable
final class AddTipState {
    /// TipKit's own verdict (rules, close, invalidation), followed from
    /// `shouldDisplayUpdates`: a close (`.tipClosed`), the first add
    /// (`.actionPerformed`) or a parameter change all collapse the card.
    private(set) var isDisplayable = false
    /// Whether `didOpenBodegaDetail` has any donation. Read from TipKit when
    /// observation starts, set on each donation.
    private(set) var hasOpenedDetail = false

    /// Runs for the lifetime of the calling view's `.task`.
    func observe() async {
        hasOpenedDetail = !TutorialTips.didOpenBodegaDetail.donations.isEmpty
        for await isDisplayable in AddBodegaTip().shouldDisplayUpdates {
            self.isDisplayable = isDisplayable
        }
    }

    /// Every path into detail (map pin, list row) lands in `BrowseView`'s
    /// `navigationDestination`, so donating there covers them all (DD4).
    func donateDidOpenBodegaDetail() async {
        await TutorialTips.didOpenBodegaDetail.donate()
        hasOpenedDetail = true
    }
}

/// "Know one that's not here?" Inline in the map's bottom card. Its one
/// action, "Add a Bodega", enters placement mode on the Map tab (DD4).
nonisolated struct AddBodegaTip: Tip {
    static let addActionID = "addBodega"

    var title: Text { Text(AppCopy.tutorialAddTipTitle.copy.text) }
    var message: Text? { Text(AppCopy.tutorialAddTipBody.copy.text) }

    var actions: [Action] {
        Action(id: Self.addActionID, title: AppCopy.addBodegaAction.copy.text)
    }

    var rules: [Rule] {
        #Rule(TutorialTips.$hasAddedFirstBodega) { $0 == false }
        #Rule(TutorialTips.$isOnboardingVisible) { $0 == false }
        #Rule(TutorialTips.$isPlacingBodega) { $0 == false }
        #Rule(TutorialTips.didOpenBodegaDetail) { $0.donations.count >= 1 }
    }
}

/// "Put the marker on the door." Popover on "Use This Location". A popover
/// floats above the whole window, onboarding overlay included, so it also
/// waits for onboarding to be gone (Show Intro Again while placing, or the
/// overlay still animating out on the first-run add path).
nonisolated struct PlacementTip: Tip {
    var title: Text { Text(AppCopy.tutorialPlacementTipTitle.copy.text) }
    var message: Text? { Text(AppCopy.tutorialPlacementTipBody.copy.text) }

    var rules: [Rule] {
        #Rule(TutorialTips.$hasAddedFirstBodega) { $0 == false }
        #Rule(TutorialTips.$isOnboardingVisible) { $0 == false }
    }
}

/// "Only the name is required." Inline above Basics in the add form.
nonisolated struct FormTip: Tip {
    var title: Text { Text(AppCopy.tutorialFormTipTitle.copy.text) }
    var message: Text? { Text(AppCopy.tutorialFormTipBody.copy.text) }

    var rules: [Rule] {
        #Rule(TutorialTips.$hasAddedFirstBodega) { $0 == false }
    }
}

/// "Distances come in blocks." Inline as the first element of the loaded
/// list while location is not authorized (#68, design D4). Its one action,
/// "Show Map", switches to the Map tab, where Locate Me is; it never asks for
/// permission itself. Close hides it for good; `BrowseView` invalidates it
/// (`.actionPerformed`) the first time the user's fix is published.
nonisolated struct DistancesTip: Tip {
    static let showMapActionID = "showMap"

    var title: Text { Text(AppCopy.distancesTipTitle.copy.text) }
    var message: Text? { Text(AppCopy.distancesTipBody.copy.text) }

    var actions: [Action] {
        Action(id: Self.showMapActionID, title: AppCopy.showMapAction.copy.text)
    }

    var rules: [Rule] {
        #Rule(TutorialTips.$isLocationAuthorized) { $0 == false }
    }
}

/// The tips' one look (spec D9, design DD13): headline title, secondary
/// subheadline message, no image, a close button, actions as `.bordered`
/// buttons. A popover gets a `.regularMaterial` background; inline (the
/// map card, the form row) gets none, because the container already
/// supplies it.
struct BodegaTipStyle: TipViewStyle {
    var inline: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let content = VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let title = configuration.title {
                        title
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let message = configuration.message {
                        message
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CardCloseButton {
                    configuration.tip.invalidate(reason: .tipClosed)
                }
            }
            ForEach(configuration.actions) { action in
                Button(action: action.handler) {
                    action.label()
                }
                .buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .contain)

        if inline {
            content
        } else {
            // Capped (as DD16 caps the pin label) so the placement popover
            // always fits above Use This Location at accessibility sizes.
            content
                .padding(16)
                .background(.regularMaterial)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }
}

extension View {
    /// An inline `TipView` in `BodegaTipStyle`. TipKit still draws its own
    /// rounded background behind a custom style (and clips the text to its
    /// corners), so inline tips clear it: the container (the map card's
    /// material, the form row) is the only background (DD13).
    func inlineBodegaTipStyle() -> some View {
        tipViewStyle(BodegaTipStyle(inline: true))
            .tipBackground(Color.clear)
            .tipCornerRadius(0)
    }
}
