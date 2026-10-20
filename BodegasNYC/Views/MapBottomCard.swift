import SwiftUI

/// The one card that sits in the map's bottom slot (eng review R5): empty
/// states now (#24), the first-add card (#25) and the inline add tip (#22)
/// later. `select` owns the precedence so at most one card is ever up, and
/// it's a pure function so the whole table is unit-tested
/// (`MapBottomCardTests`). The placement bar outranks everything and isn't a
/// card; `select` returns nil while placing so `MapScreenView` shows the bar.
///
/// Visual contract (design DD13): 16pt inset, `.regularMaterial` rounded
/// rectangle, 16pt padding, 28pt symbol column, title/body text column,
/// optional trailing close, optional action row under the text, max 480pt
/// wide.
struct MapBottomCard: View {
    /// The empty states the map can show. The first three are bodega
    /// banners; `noStreets` is the streets-walked banner, lowest in
    /// precedence.
    nonisolated enum EmptyState: Hashable, Sendable {
        case noneNearby
        case noBodegas
        case noFilterMatches
        case noStreets
    }

    /// Placeholder payload for #25's first-add card, defined now so the
    /// precedence table is real. #25 fills in what it carries.
    nonisolated struct FirstAdd: Hashable, Sendable {
        let hasCat: Bool
    }

    nonisolated enum Content: Hashable, Sendable {
        case emptyState(EmptyState)
        case firstAdd(FirstAdd)
        case addTip
    }

    /// Precedence: placement bar (nil) > first-add card > bodega empty
    /// state (noneNearby, noBodegas, noFilterMatches) > add tip > streets
    /// banner.
    ///
    /// - Parameters:
    ///   - emptyState: the bodega banner that applies, if any (see
    ///     `bodegaEmptyState`).
    ///   - streets: whether the "No streets yet." banner applies (see
    ///     `showsStreetsBanner`).
    nonisolated static func select(
        isPlacing: Bool,
        firstAdd: FirstAdd?,
        emptyState: EmptyState?,
        addTip: Bool,
        streets: Bool
    ) -> Content? {
        if isPlacing { return nil }
        if let firstAdd { return .firstAdd(firstAdd) }
        if let emptyState { return .emptyState(emptyState) }
        if addTip { return .addTip }
        if streets { return .emptyState(.noStreets) }
        return nil
    }

    /// Which bodega banner the map's data calls for. Nearby and all-mode
    /// banners need a load that came back with zero rows; the filter
    /// banner needs rows that the filter hides entirely.
    nonisolated static func bodegaEmptyState(
        browseMode: BrowseMode,
        isLoadedEmpty: Bool,
        isFilteredEmpty: Bool
    ) -> EmptyState? {
        if isLoadedEmpty {
            return browseMode == .nearby ? .noneNearby : .noBodegas
        }
        if isFilteredEmpty { return .noFilterMatches }
        return nil
    }

    /// The streets banner shows while tracking is on, nothing has been
    /// drawn yet, and the user hasn't closed it this launch.
    nonisolated static func showsStreetsBanner(isTrackingEnabled: Bool, hasPolylines: Bool, isDismissed: Bool) -> Bool {
        isTrackingEnabled && !hasPolylines && !isDismissed
    }

    let content: Content
    /// The empty state's action: Add a Bodega or Clear Filters.
    let onAction: () -> Void
    /// The close button, shown only for dismissible content (`noStreets`).
    let onDismiss: () -> Void

    var body: some View {
        switch content {
        case .emptyState(let state):
            EmptyStateCard(state: state, onAction: onAction, onDismiss: onDismiss)
        case .firstAdd:
            // Rendered by #25 (delight: first-add card).
            EmptyView()
        case .addTip:
            // Rendered by #22 (tutorial: inline AddBodegaTip).
            EmptyView()
        }
    }
}

private extension MapBottomCard.EmptyState {
    var title: AppCopy {
        switch self {
        case .noneNearby: .emptyNoneNearbyTitle
        case .noBodegas: .emptyNoBodegasTitle
        case .noFilterMatches: .emptyNoFilterMatchesTitle
        case .noStreets: .emptyNoStreetsTitle
        }
    }

    var body: AppCopy {
        switch self {
        case .noneNearby: .emptyNoneNearbyBody
        case .noBodegas: .emptyNoBodegasBody
        case .noFilterMatches: .emptyNoFilterMatchesBody
        case .noStreets: .emptyNoStreetsBody
        }
    }

    var action: AppCopy? {
        switch self {
        case .noneNearby, .noBodegas: .addBodegaAction
        case .noFilterMatches: .clearFiltersAction
        case .noStreets: nil
        }
    }

    /// Only the streets banner can be closed; the bodega banners have an
    /// action instead and go away when the data changes.
    var isDismissible: Bool { self == .noStreets }
}

private struct EmptyStateCard: View {
    let state: MapBottomCard.EmptyState
    let onAction: () -> Void
    let onDismiss: () -> Void

    private static let symbolColumnWidth: CGFloat = 28
    private static let columnSpacing: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                symbol
                    .font(.title2)
                    .frame(width: Self.symbolColumnWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title.copy.text)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilitySortPriority(4)
                    Text(state.body.copy.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .minimumScaleFactor(0.85)
                        .accessibilitySortPriority(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if state.isDismissible {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Pull the 44pt target back into the card's padding so
                    // the glyph lines up with the title, not 12pt lower.
                    .padding(.top, -12)
                    .padding(.trailing, -12)
                    .accessibilityLabel(AppCopy.dismissAction.copy.text)
                    .accessibilitySortPriority(1)
                }
            }
            if let action = state.action {
                Button(action.copy.text, action: onAction)
                    .buttonStyle(.bordered)
                    .padding(.leading, Self.symbolColumnWidth + Self.columnSpacing)
                    .accessibilitySortPriority(2)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var symbol: some View {
        switch state {
        case .noBodegas:
            EmptyStateCatSymbol()
        case .noneNearby:
            Image(systemName: "mappin.slash").foregroundStyle(.secondary)
        case .noFilterMatches:
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
        case .noStreets:
            Image(systemName: "figure.walk").foregroundStyle(.secondary)
        }
    }
}

/// The empty-state cat (spec D2/D11, cat use 1 of 2): the `cat` symbol in
/// `.catPin`, breathing three times (design DD14, bounded) and not at all
/// under Reduce Motion. Shared by the list's and the map's noBodegas state.
struct EmptyStateCatSymbol: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "cat")
            .foregroundStyle(Color.catPin)
            .symbolEffect(.breathe, options: .repeat(3), isActive: !reduceMotion)
    }
}
