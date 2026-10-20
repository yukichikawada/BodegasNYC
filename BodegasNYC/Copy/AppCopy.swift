import Foundation

/// One user-facing string plus the kind of slot it fills. The kind decides
/// which voice rules apply to it (see `AppCopyVoiceTests`): titles and
/// bodies are sentences, labels are Title Case button text.
nonisolated struct CopyString: Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case title
        case body
        case label
    }

    let kind: Kind
    let text: String
}

/// Every string the app speaks in its own voice. One case per string, so
/// `allCases` is the complete list the voice test runs over, and the
/// exhaustive `switch` in `copy` means a new case cannot ship without text.
/// Views read `.copy.text`.
///
/// Voice (spec D1-D4): dry New Yorker, short declaratives, second person,
/// no puns, no emoji, no exclamation points, never "we", never the app's
/// name. Plain `String`, no string catalog: localization is out of scope.
nonisolated enum AppCopy: CaseIterable, Hashable, Sendable {
    // MARK: Empty states (#24)

    case emptyNoBodegasTitle
    case emptyNoBodegasBody
    case emptyNoneNearbyTitle
    case emptyNoneNearbyBody
    case emptyNoReviewsCatTitle
    case emptyNoReviewsCatBody
    case emptyNoReviewsTitle
    case emptyNoReviewsBody
    case emptyNoPhotosTitle
    case emptyNoPhotosBody
    case emptyNoStreetsTitle
    case emptyNoStreetsBody
    case emptyNoFilterMatchesTitle
    case emptyNoFilterMatchesBody
    case emptyNoSearchMatchesBody
    case emptyLoadFailedTitle
    case emptyLoadFailedBody

    // MARK: Empty-state actions (#24)

    case addBodegaAction
    case clearFiltersAction
    case retryAction
    case dismissAction

    // MARK: Onboarding (#21)

    case onboardingPage1Title
    case onboardingPage1Body
    case onboardingPage2Title
    case onboardingPage2Body
    case onboardingCatLabel
    case onboardingHotFoodLabel
    case onboardingCigarettesLabel
    case onboardingBeerLabel
    case onboardingLottoLabel
    case onboardingPage3Title
    case onboardingPage3Body
    case onboardingAddAction
    case onboardingBrowseAction
    case onboardingNext
    case onboardingSkip
    case onboardingReplayMenuItem

    // MARK: Root loading (#21, design DD8)

    case rootLoading
    case rootLoadFailed

    // MARK: Tutorial tips and sign-in (#22)

    case tutorialAddTipTitle
    case tutorialAddTipBody
    case tutorialPlacementTipTitle
    case tutorialPlacementTipBody
    case tutorialFormTipTitle
    case tutorialFormTipBody
    case signInTitle
    case signInBody
    case nearMeAction

    // MARK: Delight (#25)

    case delightFirstAddTitle
    case delightFirstAddBody
    case delightFirstAddBodyCat
    case delightDismiss
    /// A pin's VoiceOver value when the bodega has a cat (design DD15).
    case pinHasCatValue

    var copy: CopyString {
        switch self {
        case .emptyNoBodegasTitle: CopyString(kind: .title, text: "Nothing on the map yet.")
        case .emptyNoBodegasBody: CopyString(kind: .body, text: "You know a spot. Put it on.")
        case .emptyNoneNearbyTitle: CopyString(kind: .title, text: "Nothing near you yet.")
        case .emptyNoneNearbyBody: CopyString(kind: .body, text: "The one on your corner would be a start.")
        case .emptyNoReviewsCatTitle: CopyString(kind: .title, text: "No reviews yet.")
        case .emptyNoReviewsCatBody: CopyString(kind: .body, text: "The cat isn't talking. You go first.")
        case .emptyNoReviewsTitle: CopyString(kind: .title, text: "No reviews yet.")
        case .emptyNoReviewsBody: CopyString(kind: .body, text: "Been here? Say so.")
        case .emptyNoPhotosTitle: CopyString(kind: .title, text: "No photos yet.")
        case .emptyNoPhotosBody: CopyString(kind: .body, text: "Start with the awning.")
        case .emptyNoStreetsTitle: CopyString(kind: .title, text: "No streets yet.")
        case .emptyNoStreetsBody: CopyString(kind: .body, text: "Walk somewhere. This fills in on its own.")
        case .emptyNoFilterMatchesTitle: CopyString(kind: .title, text: "Nothing with all of that.")
        case .emptyNoFilterMatchesBody: CopyString(kind: .body, text: "Drop a filter.")
        case .emptyNoSearchMatchesBody: CopyString(kind: .body, text: "Try the cross street.")
        case .emptyLoadFailedTitle: CopyString(kind: .title, text: "Couldn't reach the map.")
        case .emptyLoadFailedBody: CopyString(kind: .body, text: "Try again in a second.")
        case .addBodegaAction: CopyString(kind: .label, text: "Add a Bodega")
        case .clearFiltersAction: CopyString(kind: .label, text: "Clear Filters")
        case .retryAction: CopyString(kind: .label, text: "Retry")
        case .dismissAction: CopyString(kind: .label, text: "Dismiss")
        case .onboardingPage1Title: CopyString(kind: .title, text: "Every bodega has something.")
        case .onboardingPage1Body:
            CopyString(
                kind: .body,
                text: "A cat. Hot food. Lotto. Cold beer at 3 a.m. The big maps don't know any of that. "
                    + "This map only knows what people put in it."
            )
        case .onboardingPage2Title: CopyString(kind: .title, text: "Filter by what you need.")
        case .onboardingPage2Body:
            CopyString(
                kind: .body,
                text: "Cat, hot food, cigarettes, beer, lotto. Find the right one before the walk, not after."
            )
        case .onboardingCatLabel: CopyString(kind: .label, text: "Cat")
        case .onboardingHotFoodLabel: CopyString(kind: .label, text: "Hot Food")
        case .onboardingCigarettesLabel: CopyString(kind: .label, text: "Cigarettes")
        case .onboardingBeerLabel: CopyString(kind: .label, text: "Beer")
        case .onboardingLottoLabel: CopyString(kind: .label, text: "Lotto")
        case .onboardingPage3Title: CopyString(kind: .title, text: "You know a spot.")
        case .onboardingPage3Body:
            CopyString(kind: .body, text: "Put the one on your corner on the map. A minute, maybe two.")
        case .onboardingAddAction: CopyString(kind: .label, text: "Add a Bodega You Know")
        case .onboardingBrowseAction: CopyString(kind: .label, text: "Just Look Around")
        case .onboardingNext: CopyString(kind: .label, text: "Next")
        case .onboardingSkip: CopyString(kind: .label, text: "Skip")
        case .onboardingReplayMenuItem: CopyString(kind: .label, text: "Show Intro Again")
        case .rootLoading: CopyString(kind: .body, text: "Getting the map.")
        case .rootLoadFailed: CopyString(kind: .title, text: "Couldn't reach the map.")
        case .tutorialAddTipTitle: CopyString(kind: .title, text: "Know one that's not here?")
        case .tutorialAddTipBody: CopyString(kind: .body, text: "Add it. Takes a minute.")
        case .tutorialPlacementTipTitle: CopyString(kind: .title, text: "Put the marker on the door.")
        case .tutorialPlacementTipBody:
            CopyString(
                kind: .body,
                text: "Zoom in to your block. Drag the map, not the marker. Then tap Use This Location."
            )
        case .tutorialFormTipTitle: CopyString(kind: .title, text: "Only the name is required.")
        case .tutorialFormTipBody: CopyString(kind: .body, text: "The rest is what people filter by.")
        case .signInTitle: CopyString(kind: .title, text: "Sign in to put it on the map.")
        case .signInBody:
            CopyString(kind: .body, text: "Looking never needs an account. Adding, reviewing, and photos do.")
        case .nearMeAction: CopyString(kind: .label, text: "Near Me")
        case .delightFirstAddTitle: CopyString(kind: .title, text: "One down.")
        case .delightFirstAddBody: CopyString(kind: .body, text: "The map knows something it didn't a minute ago.")
        case .delightFirstAddBodyCat:
            CopyString(kind: .body, text: "The map knows something it didn't a minute ago. The cat, mostly.")
        case .delightDismiss: CopyString(kind: .label, text: "Done")
        // DD15 writes it "Has a cat"; as a label it takes Title Case. VoiceOver
        // reads both the same.
        case .pinHasCatValue: CopyString(kind: .label, text: "Has a Cat")
        }
    }

    /// The list's search-only no-matches title. `query` is user-typed and
    /// exempt from the voice rules; the voice test checks the template with
    /// the fixture "Deli". The period sits inside the closing curly quote.
    static func noSearchMatchesTitle(_ query: String) -> CopyString {
        CopyString(kind: .title, text: "Nothing called \u{201C}\(query).\u{201D}")
    }

    /// The VoiceOver announcement posted on every successful add (design
    /// DD15), independent of the first-add card. `name` is user-typed and
    /// exempt from the voice rules; the voice test checks the template with
    /// the fixture "Deli".
    static func addedAnnouncement(name: String) -> CopyString {
        CopyString(kind: .body, text: "\(name) is on the map.")
    }

    /// The detail reviews section's empty state: the cat line only when the
    /// bodega has a cat (spec D2, cat use 2 of 2).
    static func noReviews(hasCat: Bool) -> (title: AppCopy, body: AppCopy) {
        hasCat
            ? (.emptyNoReviewsCatTitle, .emptyNoReviewsCatBody)
            : (.emptyNoReviewsTitle, .emptyNoReviewsBody)
    }
}
