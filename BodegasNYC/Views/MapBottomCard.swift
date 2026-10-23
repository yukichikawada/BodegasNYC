import SwiftUI
import TipKit

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
    /// banners; `noStreets` and `zoomInForBlocks` are Streets Walked's,
    /// lowest in precedence.
    nonisolated enum EmptyState: Hashable, Sendable {
        case noneNearby
        /// `noneNearby` at block zoom (#84 design D3): the 200 m radius is
        /// the block, so the copy names it and points at the pinch.
        case noneOnBlock
        case noBodegas
        case noFilterMatches
        case noStreets
        /// More walked runs are in view than the map draws, so the layer is
        /// hidden (#108 design D3). Title only, not dismissible: zooming in
        /// clears it.
        case zoomInForBlocks
    }

    /// The first-add card (#25): shown once per device, after the first
    /// bodega lands. `hasCat` picks the body line and whether the cat walks
    /// into the symbol column.
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
    /// banner > zoom in for blocks (#108 design D3, lowest).
    ///
    /// - Parameters:
    ///   - emptyState: the bodega banner that applies, if any (see
    ///     `bodegaEmptyState`).
    ///   - streets: whether the "No streets yet." banner applies (see
    ///     `showsStreetsBanner`).
    ///   - zoomInForBlocks: whether the walked layer is hidden over its cap
    ///     (only while Show on Map is on and history exists).
    nonisolated static func select(
        isPlacing: Bool,
        firstAdd: FirstAdd?,
        emptyState: EmptyState?,
        addTip: Bool,
        streets: Bool,
        zoomInForBlocks: Bool = false
    ) -> Content? {
        if isPlacing { return nil }
        if let firstAdd { return .firstAdd(firstAdd) }
        if let emptyState { return .emptyState(emptyState) }
        if addTip { return .addTip }
        if streets { return .emptyState(.noStreets) }
        if zoomInForBlocks { return .emptyState(.zoomInForBlocks) }
        return nil
    }

    /// Which bodega banner the map's data calls for. Nearby and all-mode
    /// banners need a load that came back with zero rows; the filter
    /// banner needs rows that the filter hides entirely. An empty nearby
    /// load at block zoom is `noneOnBlock`.
    nonisolated static func bodegaEmptyState(
        browseMode: BrowseMode,
        isLoadedEmpty: Bool,
        isFilteredEmpty: Bool,
        isBlockZoom: Bool
    ) -> EmptyState? {
        if isLoadedEmpty {
            guard browseMode == .nearby else { return .noBodegas }
            return isBlockZoom ? .noneOnBlock : .noneNearby
        }
        if isFilteredEmpty { return .noFilterMatches }
        return nil
    }

    /// The streets banner shows while tracking is on, a count has finished
    /// with zero walked blocks (it keys on blocks, not raw fixes, #108), and
    /// the user hasn't closed it this launch. Never while the first count
    /// runs (design D8) and never when the street data did not load: "No
    /// streets yet." would be wrong in both.
    nonisolated static func showsStreetsBanner(
        isTrackingEnabled: Bool,
        hasCounted: Bool,
        hasWalkedBlocks: Bool,
        isDismissed: Bool
    ) -> Bool {
        isTrackingEnabled && hasCounted && !hasWalkedBlocks && !isDismissed
    }

    /// From `.accessibility1` up the card stacks vertically (symbol above
    /// the text) instead of using the side-by-side grid, which can't fit
    /// accessibility-size text in one column (DD16).
    nonisolated static func usesStackedLayout(for dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize >= .accessibility1
    }

    let content: Content
    /// The card's action: the empty state's Add a Bodega or Clear Filters,
    /// the add tip's Add a Bodega, or the first-add card's Done.
    let onAction: () -> Void
    /// The close button, shown only for dismissible content (`noStreets`).
    let onDismiss: () -> Void

    var body: some View {
        switch content {
        case .emptyState(let state):
            EmptyStateCard(state: state, onAction: onAction, onDismiss: onDismiss)
        case .firstAdd(let firstAdd):
            FirstAddCard(hasCat: firstAdd.hasCat, onDone: onAction)
        case .addTip:
            // The tutorial's Add tip (#22), inline rather than a toolbar
            // popover (eng review R1). The card supplies the material, so
            // the tip style draws no background (DD13).
            TipView(AddBodegaTip()) { action in
                if action.id == AddBodegaTip.addActionID { onAction() }
            }
            .inlineBodegaTipStyle()
            .modifier(MapBottomCardChrome())
        }
    }
}

private extension MapBottomCard.EmptyState {
    var title: AppCopy {
        switch self {
        case .noneNearby: .emptyNoneNearbyTitle
        case .noneOnBlock: .emptyNoneOnBlockTitle
        case .noBodegas: .emptyNoBodegasTitle
        case .noFilterMatches: .emptyNoFilterMatchesTitle
        case .noStreets: .emptyNoStreetsTitle
        case .zoomInForBlocks: .zoomInForBlocksTitle
        }
    }

    var body: AppCopy? {
        switch self {
        case .noneNearby: .emptyNoneNearbyBody
        case .noneOnBlock: .emptyNoneOnBlockBody
        case .noBodegas: .emptyNoBodegasBody
        case .noFilterMatches: .emptyNoFilterMatchesBody
        case .noStreets: .emptyNoStreetsBody
        case .zoomInForBlocks: nil
        }
    }

    var action: AppCopy? {
        switch self {
        case .noneNearby, .noneOnBlock, .noBodegas: .addBodegaAction
        case .noFilterMatches: .clearFiltersAction
        case .noStreets, .zoomInForBlocks: nil
        }
    }

    /// Only the streets banner can be closed; the bodega banners have an
    /// action instead and go away when the data changes.
    var isDismissible: Bool { self == .noStreets }
}

/// The DD13 card chrome every slot content shares: 16pt padding, material
/// rounded rectangle, 480pt max width centered, 16pt side inset, 8pt above
/// the bottom safe area.
struct MapBottomCardChrome: ViewModifier {
    /// Clips the content to the card's shape, so something entering from
    /// outside (the first-add cat) is cut at the card's edge (DD11).
    var clips = false

    func body(content: Content) -> some View {
        clipped(content.padding(16))
            // The material and the small card shadow (DESIGN.md Elevation,
            // radius 2 y 1) sit behind the content, so the text casts none
            // and a clipped card still keeps its shadow.
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            .accessibilityElement(children: .contain)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func clipped(_ card: some View) -> some View {
        if clips {
            card.clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            card
        }
    }
}

private struct EmptyStateCard: View {
    let state: MapBottomCard.EmptyState
    let onAction: () -> Void
    let onDismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 28pt at the default size, growing with the `.title2` symbol so the
    /// glyph never overflows its column at large sizes.
    @ScaledMetric(relativeTo: .title2) private var symbolColumnWidth: CGFloat = 28
    private static let columnSpacing: CGFloat = 12

    var body: some View {
        Group {
            if MapBottomCard.usesStackedLayout(for: dynamicTypeSize) {
                stackedLayout
            } else {
                gridLayout
            }
        }
        .modifier(MapBottomCardChrome())
    }

    /// The DD13 grid: symbol column, text column, trailing close, action
    /// row under the text.
    private var gridLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                symbolView
                    .frame(width: symbolColumnWidth)
                textColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                if state.isDismissible {
                    CardCloseButton(action: onDismiss)
                        .accessibilitySortPriority(1)
                }
            }
            if let action = state.action {
                Button(action.copy.text, action: onAction)
                    .buttonStyle(.bordered)
                    .padding(.leading, symbolColumnWidth + Self.columnSpacing)
                    .accessibilitySortPriority(2)
            }
        }
    }

    /// Accessibility sizes (DD16, same treatment as the first-add card):
    /// symbol above the text with the close top-trailing, then a
    /// full-width action, so nothing truncates or overflows the card.
    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                symbolView
                Spacer(minLength: 0)
                if state.isDismissible {
                    CardCloseButton(action: onDismiss)
                        .accessibilitySortPriority(1)
                }
            }
            textColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = state.action {
                Button(action: onAction) {
                    Text(action.copy.text)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilitySortPriority(2)
            }
        }
    }

    private var symbolView: some View {
        symbol
            .font(.title2)
            .accessibilityHidden(true)
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.title.copy.text)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilitySortPriority(4)
            if let body = state.body {
                Text(body.copy.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilitySortPriority(3)
            }
        }
    }

    @ViewBuilder
    private var symbol: some View {
        switch state {
        case .noBodegas:
            EmptyStateCatSymbol()
        case .noneNearby, .noneOnBlock:
            Image(systemName: "mappin.slash").foregroundStyle(.secondary)
        case .noFilterMatches:
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
        case .noStreets:
            Image(systemName: "figure.walk").foregroundStyle(.secondary)
        case .zoomInForBlocks:
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
    }
}

/// The one close button for map bottom cards and tutorial tips: an
/// `xmark.circle.fill` in `.secondary` with at least a 44pt target.
///
/// Below accessibility sizes the target is pulled 12pt back into the card's
/// 16pt padding so the glyph lines up with the first line of text. From
/// `.accessibility1` up the glyph outgrows the 44pt frame, so the pull would
/// push it past the card edge (and TipView clips there); it sits in place.
struct CardCloseButton: View {
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var inset: CGFloat {
        MapBottomCard.usesStackedLayout(for: dynamicTypeSize) ? 0 : -12
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, inset)
        .padding(.trailing, inset)
        .accessibilityLabel(AppCopy.dismissAction.copy.text)
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
