import Foundation

/// One user-facing string plus the kind of slot it fills. The kind decides
/// which voice rules apply to it (see `AppCopyVoiceTests`): titles and
/// bodies are sentences, labels are Title Case button text, values are short
/// data fragments.
nonisolated struct CopyString: Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case title
        case body
        case label
        /// A short data fragment in a data position: a row's trailing text, a
        /// column value ("2 blocks"). 1 to 4 words, no trailing period, not
        /// forced into Title Case, never starting lowercase (#68, spec D4).
        /// The five global voice rules still apply.
        case value
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
    case emptyNoneOnBlockTitle
    case emptyNoneOnBlockBody
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
    /// The short label for each data point (`BodegaFilter.Amenity.caption`),
    /// shared by onboarding page 2, the detail data points, the Add/Edit
    /// form and the Filters sheet; the prefix is historical.
    case onboardingCatLabel
    case onboardingHotFoodLabel
    case onboardingNicotineLabel
    case onboardingBeerLabel
    case onboardingLottoLabel
    case onboardingAtmLabel
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

    // MARK: Placement card (#23)

    /// The placement card's title: the instruction the crosshair stands for
    /// (the crosshair itself is hidden from VoiceOver).
    case placementCardTitle

    // MARK: Delight (#25)

    case delightFirstAddTitle
    case delightFirstAddBody
    case delightFirstAddBodyCat
    case delightDismiss
    /// A pin's VoiceOver value when the bodega has a cat (design DD15).
    case pinHasCatValue

    // MARK: Detail data points (#70)

    /// VoiceOver values for the detail screen's six data points, which
    /// otherwise show presence only by color and a struck-through caption.
    case dataPointPresentValue
    case dataPointAbsentValue

    // MARK: Duplicate check (#20)

    case duplicatePromptTitle
    case duplicatePromptBody
    /// Under the body, and every match row's VoiceOver hint (design DS3).
    case duplicatePromptFootnote
    case duplicateConfirmNewAction

    // MARK: Distances tip (#68, design D4)

    case distancesTipTitle
    case distancesTipBody
    /// The tip's one action: switches to the Map tab, where Locate Me is.
    case showMapAction

    // MARK: List order (#81)

    /// The Filters sheet section header; says where the order applies,
    /// since the sheet opens from the Map tab too.
    case listOrderSectionLabel
    case listOrderNearestLabel
    case listOrderNewestLabel
    /// Footer while the list is nearest-ordered (design D6).
    case listOrderActiveFootnote
    /// Footer while Nearest First is chosen, the list is not nearest-ordered
    /// and the map's Locate Me can still prompt (design D2).
    case listOrderNeedsLocationBody
    /// Footer while Nearest First is chosen and the list is not
    /// nearest-ordered for any other reason: denied, restricted, Precise
    /// Location off, a fix pending or expired (design D2). "Newest first" and
    /// "Nearest first" are in sentence case on purpose: the sentence names
    /// the orders, it does not quote the picker's Title Case labels.
    case listOrderFallbackBody
    /// VoiceOver, on an automatic re-sort to nearest while the list is in
    /// front (design D3, the DD15 precedent).
    case listOrderNearestAnnouncement

    // MARK: Photos (#107)

    /// The detail gallery's section header.
    case photosSectionLabel
    /// The gallery's picker button (up to 10 photos, #107 PR 2), and the
    /// upload sheet's title for more than one photo.
    case addPhotoAction
    /// The thumbnail context menu item and the viewer's menu item.
    case flagPhotoAction
    /// The viewer's `xmark` close button (VoiceOver label).
    case photoViewerCloseLabel
    /// The viewer's `ellipsis.circle` menu (VoiceOver label).
    case photoViewerMoreLabel
    /// VoiceOver named actions on a viewer page (design D19).
    case photoZoomInAction
    case photoResetZoomAction
    /// A gallery thumbnail's VoiceOver hint.
    case photoOpensFullScreenHint
    /// A viewer page whose image did not load (design D17); the button under
    /// it is `retryAction`.
    case photoLoadFailedBody
    /// The alert after a flag is submitted, on the detail screen and over
    /// the viewer (eng A2).
    case flagSubmittedTitle
    case flagSubmittedBody
    case okAction

    // MARK: Upload sheet and captions (#107 PR 2; design D2, D9-D15)

    /// The sheet's title with exactly one photo ("Add Photos" otherwise).
    case addOnePhotoTitle
    /// Toolbar: Upload; Stop while a pass runs; Done once one went up.
    case uploadAction, stopAction, doneAction, cancelAction
    /// The row's swipe and VoiceOver action; the discard dialog's button.
    case removeAction, discardAction
    /// The viewer's caption band button that expands it.
    case captionMoreAction
    /// The field's placeholder (never "optional") and the footer that is.
    case captionPlaceholder, captionsOptionalFooter
    /// A row's failure text and its uploaded checkmark's VoiceOver label.
    case photoUploadFailedValue, photoUploadedValue
    /// The single-photo preview's VoiceOver label; the no-loadable-picks body.
    case selectedPhotoLabel, photoUnreadableBody

    // MARK: Streets Walked (#108, design D3, D5, D11)

    case streetsWalkedMenuLabel
    case showOnMapToggle
    case startRecordingAction
    case stopRecordingAction
    /// The menu shows it with a trailing ellipsis (`menuItemWithEllipsis`):
    /// it opens a confirmation, the HIG's rule for "…".
    case clearHistoryMenuItem
    case clearHistoryConfirmTitle
    /// The cutoff is the confirm tap (design D5, eng R9).
    case clearHistoryConfirmBody
    case deleteHistoryAction
    /// The bottom card when more walked runs are in view than the map draws
    /// (design D3): the whole layer hides instead of drawing a subset.
    case zoomInForBlocksTitle
    /// VoiceOver, once Clear History is done (design D11).
    case historyClearedAnnouncement

    var copy: CopyString {
        switch self {
        case .emptyNoBodegasTitle: CopyString(kind: .title, text: "Nothing on the map yet.")
        case .emptyNoBodegasBody: CopyString(kind: .body, text: "You know a spot. Put it on.")
        case .emptyNoneNearbyTitle: CopyString(kind: .title, text: "Nothing near you yet.")
        case .emptyNoneNearbyBody: CopyString(kind: .body, text: "The one on your corner would be a start.")
        case .emptyNoneOnBlockTitle: CopyString(kind: .title, text: "Nothing on this block yet.")
        case .emptyNoneOnBlockBody:
            CopyString(kind: .body, text: "Pinch out and look around. Or add the one on your corner.")
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
                text: "Cat, hot food, nicotine, beer, lotto, ATM. Find the right one before the walk, not after."
            )
        case .onboardingCatLabel: CopyString(kind: .label, text: "Cat")
        case .onboardingHotFoodLabel: CopyString(kind: .label, text: "Hot Food")
        case .onboardingNicotineLabel: CopyString(kind: .label, text: "Nicotine")
        case .onboardingBeerLabel: CopyString(kind: .label, text: "Beer")
        case .onboardingLottoLabel: CopyString(kind: .label, text: "Lotto")
        case .onboardingAtmLabel: CopyString(kind: .label, text: "ATM")
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
        case .placementCardTitle: CopyString(kind: .title, text: "Line the marker up with the door.")
        case .delightFirstAddTitle: CopyString(kind: .title, text: "One down.")
        case .delightFirstAddBody: CopyString(kind: .body, text: "The map knows something it didn't a minute ago.")
        case .delightFirstAddBodyCat:
            CopyString(kind: .body, text: "The map knows something it didn't a minute ago. The cat, mostly.")
        case .delightDismiss: CopyString(kind: .label, text: "Done")
        // DD15 writes it "Has a cat"; as a label it takes Title Case. VoiceOver
        // reads both the same.
        case .pinHasCatValue: CopyString(kind: .label, text: "Has a Cat")
        case .dataPointPresentValue: CopyString(kind: .label, text: "Yes")
        case .dataPointAbsentValue: CopyString(kind: .label, text: "No")
        case .duplicatePromptTitle: CopyString(kind: .title, text: "Is this one of these?")
        case .duplicatePromptBody:
            CopyString(kind: .body, text: "The map already has something right there. If it's the same place, open it.")
        case .duplicatePromptFootnote: CopyString(kind: .body, text: "Opening one drops what you typed.")
        case .duplicateConfirmNewAction: CopyString(kind: .label, text: "No, It's New")
        case .distancesTipTitle: CopyString(kind: .title, text: "Distances come in blocks.")
        case .distancesTipBody:
            CopyString(kind: .body, text: "Tap Locate Me on the map and the list measures the way you do.")
        case .showMapAction: CopyString(kind: .label, text: "Show Map")
        case .listOrderSectionLabel: CopyString(kind: .label, text: "List Order")
        case .listOrderNearestLabel: CopyString(kind: .label, text: "Nearest First")
        case .listOrderNewestLabel: CopyString(kind: .label, text: "Newest First")
        case .listOrderActiveFootnote: CopyString(kind: .body, text: "Sorted from where you opened the list.")
        case .listOrderNeedsLocationBody:
            CopyString(kind: .body, text: "Nearest first needs your location. Tap Locate Me on the map.")
        case .listOrderFallbackBody:
            CopyString(kind: .body, text: "Newest first for now. Nearest first needs to know where you are.")
        case .listOrderNearestAnnouncement: CopyString(kind: .body, text: "Nearest first now.")
        case .photosSectionLabel: CopyString(kind: .label, text: "Photos")
        case .addPhotoAction: CopyString(kind: .label, text: "Add Photos")
        case .flagPhotoAction: CopyString(kind: .label, text: "Flag Photo")
        case .photoViewerCloseLabel: CopyString(kind: .label, text: "Close")
        case .photoViewerMoreLabel: CopyString(kind: .label, text: "More")
        case .photoZoomInAction: CopyString(kind: .label, text: "Zoom In")
        case .photoResetZoomAction: CopyString(kind: .label, text: "Reset Zoom")
        case .photoOpensFullScreenHint: CopyString(kind: .body, text: "Opens full screen.")
        case .photoLoadFailedBody: CopyString(kind: .body, text: "That one didn't load.")
        case .flagSubmittedTitle: CopyString(kind: .title, text: "Thanks for the heads-up.")
        case .flagSubmittedBody: CopyString(kind: .body, text: "Your flag was submitted.")
        case .okAction: CopyString(kind: .label, text: "OK")
        case .addOnePhotoTitle: CopyString(kind: .label, text: "Add a Photo")
        case .uploadAction: CopyString(kind: .label, text: "Upload")
        case .stopAction: CopyString(kind: .label, text: "Stop")
        case .doneAction: CopyString(kind: .label, text: "Done")
        case .cancelAction: CopyString(kind: .label, text: "Cancel")
        case .removeAction: CopyString(kind: .label, text: "Remove")
        case .discardAction: CopyString(kind: .label, text: "Discard")
        case .captionMoreAction: CopyString(kind: .label, text: "More")
        case .captionPlaceholder: CopyString(kind: .body, text: "What's in the shot?")
        case .captionsOptionalFooter: CopyString(kind: .body, text: "Captions are optional. 140 characters, tops.")
        case .photoUploadFailedValue: CopyString(kind: .value, text: "Didn't go through")
        case .photoUploadedValue: CopyString(kind: .value, text: "Went up")
        case .selectedPhotoLabel: CopyString(kind: .value, text: "Selected photo")
        case .photoUnreadableBody: CopyString(kind: .body, text: "Try a different photo.")
        case .streetsWalkedMenuLabel: CopyString(kind: .label, text: "Streets Walked")
        case .showOnMapToggle: CopyString(kind: .label, text: "Show on Map")
        case .startRecordingAction: CopyString(kind: .label, text: "Start Recording")
        case .stopRecordingAction: CopyString(kind: .label, text: "Stop Recording")
        case .clearHistoryMenuItem: CopyString(kind: .label, text: "Clear History")
        case .clearHistoryConfirmTitle: CopyString(kind: .title, text: "Delete your walked history?")
        case .clearHistoryConfirmBody:
            CopyString(kind: .body, text: "Your saved walks and block counts go. This can't be undone.")
        case .deleteHistoryAction: CopyString(kind: .label, text: "Delete History")
        case .zoomInForBlocksTitle: CopyString(kind: .title, text: "Zoom in to see your blocks.")
        case .historyClearedAnnouncement: CopyString(kind: .body, text: "History cleared.")
        }
    }

    /// A menu item that opens a confirmation, with the HIG's trailing "…".
    /// The voice rules check the label without it.
    var menuItemWithEllipsis: String {
        copy.text + "\u{2026}"
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
}

// Outside the enum body, which sits at SwiftLint's type_body_length limit.
nonisolated extension AppCopy {
    /// The detail reviews section's empty state: the cat line only when the
    /// bodega has a cat (spec D2, cat use 2 of 2).
    static func noReviews(hasCat: Bool) -> (title: AppCopy, body: AppCopy) {
        hasCat
            ? (.emptyNoReviewsCatTitle, .emptyNoReviewsCatBody)
            : (.emptyNoReviewsTitle, .emptyNoReviewsBody)
    }
}

// MARK: - Distance (#68)

/// The number is data, so these are templates rather than cases; the voice
/// test runs them over a fixture set covering every branch.
nonisolated extension AppCopy {
    /// A list row's trailing value (design D5/D7): "Around the corner",
    /// "1 block", "2 blocks", "0.6 miles", "1 mile", "2,450 miles".
    static func distanceValue(_ distance: BlockDistance) -> CopyString {
        let text = switch distance {
        case .aroundTheCorner: "Around the corner"
        case .blocks(1): "1 block"
        case .blocks(let count): "\(count) blocks"
        case .miles(let miles): milesPhrase(miles)
        }
        return CopyString(kind: .value, text: text)
    }

    /// The detail header's line and a row's VoiceOver ending: "Around the
    /// corner.", "1 block from you.", "0.6 miles from you.".
    static func distanceFromYou(_ distance: BlockDistance) -> CopyString {
        let text = switch distance {
        case .aroundTheCorner: "Around the corner."
        case .blocks(1): "1 block from you."
        case .blocks(let count): "\(count) blocks from you."
        case .miles(let miles): "\(milesPhrase(miles)) from you."
        }
        return CopyString(kind: .body, text: text)
    }

    /// "1 mile" when the number reads as exactly one, else "<n> miles".
    private static func milesPhrase(_ miles: Double) -> String {
        let number = milesText(miles)
        return number == "1" ? "1 mile" : "\(number) miles"
    }

    /// At most one decimal, none when it would be ".0", schoolbook rounding
    /// (as for blocks), grouping on, in a fixed `en_US` locale (the app is
    /// English-only): 0.55 → "0.6", 1.0 → "1", 1.25 → "1.3", 2450 → "2,450".
    private static func milesText(_ miles: Double) -> String {
        miles.formatted(
            .number
                .precision(.fractionLength(0...1))
                .rounded(rule: .toNearestOrAwayFromZero)
                .grouping(.automatic)
                .locale(Locale(identifier: "en_US"))
        )
    }
}
