import SwiftUI

/// The first-add card (#25, design DD11/DD13/DD14/DD16): "One down." and
/// the body line (the cat version when the bodega has one), with Done as a
/// trailing `.bordered` button. The symbol column holds the cat, which walks
/// in from the trailing side 0.3 s after the card appears and bounces once,
/// or the pin symbol when there's no cat. Under Reduce Motion the cat is
/// simply there. Shown once per device; `AddCompletionCoordinator` decides
/// when.
struct FirstAddCard: View {
    let hasCat: Bool
    let onDone: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var symbolColumnWidth: CGFloat = 36
    @State private var catHasEntered = false
    @State private var catBounces = 0
    private static let columnSpacing: CGFloat = 12

    private var bodyCopy: AppCopy { hasCat ? .delightFirstAddBodyCat : .delightFirstAddBody }

    var body: some View {
        Group {
            if MapBottomCard.usesStackedLayout(for: dynamicTypeSize) {
                VStack(alignment: .leading, spacing: 12) {
                    symbol
                    textColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                    doneButton(fullWidth: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: Self.columnSpacing) {
                        symbol
                            .frame(width: symbolColumnWidth)
                        textColumn
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        doneButton(fullWidth: false)
                    }
                }
            }
        }
        .modifier(MapBottomCardChrome(clips: true))
        .task { await enterCat() }
    }

    /// Reading order (DD15): title, body, Done.
    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppCopy.delightFirstAddTitle.copy.text)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilitySortPriority(3)
            Text(bodyCopy.copy.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilitySortPriority(2)
        }
    }

    private func doneButton(fullWidth: Bool) -> some View {
        Button(action: onDone) {
            Text(AppCopy.delightDismiss.copy.text)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .accessibilitySortPriority(1)
    }

    @ViewBuilder
    private var symbol: some View {
        if hasCat {
            Image(systemName: "cat")
                .font(.system(size: 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.catPin)
                .symbolEffect(.bounce, value: catBounces)
                .offset(x: catHasEntered ? 0 : 24)
                .opacity(catHasEntered ? 1 : 0)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "mappin.and.ellipse")
                .font(.title2)
                .foregroundStyle(Color.pin)
                .accessibilityHidden(true)
        }
    }

    /// 0.3 s after the card appears the cat springs in from the trailing
    /// side, then bounces once (DD11). Reduce Motion: in place, no bounce
    /// (DD14).
    private func enterCat() async {
        guard hasCat, !catHasEntered else { return }
        guard !reduceMotion else {
            catHasEntered = true
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.3)) {
            catHasEntered = true
        } completion: {
            catBounces += 1
        }
    }
}
