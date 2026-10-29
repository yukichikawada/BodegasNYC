import SwiftUI

/// The DD13 text card: symbol column, title and body, optional close, and
/// an optional action row. Empty states and recorder problems share it.
struct TextSlotCard<Symbol: View>: View {
    let title: String
    let message: String?
    let action: String?
    let isDismissible: Bool
    let onAction: () -> Void
    let onDismiss: () -> Void
    @ViewBuilder let symbol: Symbol

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 28pt at the default size, growing with the `.title2` symbol so the
    /// glyph never overflows its column at large sizes.
    @ScaledMetric(relativeTo: .title2) private var symbolColumnWidth: CGFloat = 28
    private let columnSpacing: CGFloat = 12

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
            HStack(alignment: .top, spacing: columnSpacing) {
                symbolView
                    .frame(width: symbolColumnWidth)
                textColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isDismissible {
                    CardCloseButton(action: onDismiss)
                        .accessibilitySortPriority(1)
                }
            }
            if let action {
                Button(action, action: onAction)
                    .buttonStyle(.bordered)
                    .padding(.leading, symbolColumnWidth + columnSpacing)
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
                if isDismissible {
                    CardCloseButton(action: onDismiss)
                        .accessibilitySortPriority(1)
                }
            }
            textColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action: onAction) {
                    // Wraps at the largest sizes rather than truncating
                    // ("Open Setti…", #123 QA).
                    Text(action)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
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
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilitySortPriority(4)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilitySortPriority(3)
            }
        }
    }
}

/// An empty state's symbol: the breathing cat for noBodegas, else a
/// `.secondary` SF Symbol.
struct EmptyStateSymbol: View {
    let state: MapBottomCard.EmptyState

    var body: some View {
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
