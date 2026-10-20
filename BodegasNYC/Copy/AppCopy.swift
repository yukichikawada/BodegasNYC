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
        }
    }

    /// The list's search-only no-matches title. `query` is user-typed and
    /// exempt from the voice rules; the voice test checks the template with
    /// the fixture "Deli". The period sits inside the closing curly quote.
    static func noSearchMatchesTitle(_ query: String) -> CopyString {
        CopyString(kind: .title, text: "Nothing called \u{201C}\(query).\u{201D}")
    }

    /// The detail reviews section's empty state: the cat line only when the
    /// bodega has a cat (spec D2, cat use 2 of 2).
    static func noReviews(hasCat: Bool) -> (title: AppCopy, body: AppCopy) {
        hasCat
            ? (.emptyNoReviewsCatTitle, .emptyNoReviewsCatBody)
            : (.emptyNoReviewsTitle, .emptyNoReviewsBody)
    }
}
