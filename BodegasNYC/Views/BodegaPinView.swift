import SwiftUI

/// The one pin view for every bodega on the map (spec D10, design DD3), so
/// the pin that drops in after an add (#25) never looks different from its
/// neighbours, and #23 has one view to hang matched geometry on. The cat is
/// the `cat` symbol (D11), swappable for an illustration here later.
///
/// Rendered inside `Annotation(_, coordinate:, anchor: .center)`: the name
/// label is an overlay above the circle, outside its layout, so showing it
/// never moves the pin off its coordinate.
///
/// Why above (#59): each `Annotation` is its own MapKit annotation view, and
/// MapKit stacks those by screen position (lower on screen draws in front),
/// not by `ForEach` order, and SwiftUI's `Map` exposes no z-priority. So a
/// neighbour just south of a dropping or selected pin is drawn over it, and
/// a label hung below the circle sat under that neighbour's circle. Above
/// the circle, any annotation drawn in front of this one has its centre at
/// or below this pin's, so its circle can't reach the label.
struct BodegaPinView: View {
    static let diameter: CGFloat = 28
    nonisolated static let maxLabelCharacters = 18

    let bodega: Bodega
    let isSelected: Bool
    /// From `AddCompletionCoordinator.pinPhase(for:)`. `.pending` renders
    /// invisible (the camera is still on its way), `.dropping` plays the
    /// drop on appear or on change, `.atRest` is every other pin. An edit
    /// never sets a phase, so edited pins never drop.
    let phase: AddCompletionCoordinator.PinPhase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether this pin's drop has played; only read while `phase` isn't
    /// `.atRest`.
    @State private var hasLanded = false

    /// The name, cut to `maxLabelCharacters` with a trailing ellipsis.
    nonisolated static func labelText(for name: String) -> String {
        guard name.count > maxLabelCharacters else { return name }
        return String(name.prefix(maxLabelCharacters - 1)) + "\u{2026}"
    }

    private var isAtRest: Bool {
        switch phase {
        case .atRest: true
        case .pending: false
        case .dropping: hasLanded
        }
    }

    private var showsLabel: Bool { isSelected || phase != .atRest }

    /// Reduce Motion (DD14): the pin fades in where it lands, no fall and
    /// no squash.
    private var dropOffset: CGFloat { isAtRest || reduceMotion ? 0 : -48 }
    private var dropScale: CGFloat { isAtRest || reduceMotion ? 1 : 0.6 }

    var body: some View {
        circle
            .scaleEffect(isSelected ? 1.15 : 1)
            .overlay(alignment: .bottom) {
                if showsLabel {
                    nameLabel
                        .fixedSize()
                        // Sit the label above the circle (clear of the
                        // selected 1.15 scale; see the type comment for why
                        // not below); an alignment guide here is not honored
                        // inside the annotation.
                        .offset(y: -(Self.diameter + 4))
                }
            }
            .offset(y: dropOffset)
            .scaleEffect(dropScale)
            .opacity(isAtRest ? 1 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: isSelected)
            .onAppear(perform: dropIfNeeded)
            .onChange(of: phase) { dropIfNeeded() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bodega.name)
            .accessibilityValue(bodega.hasCat ? AppCopy.pinHasCatValue.copy.text : "")
            .accessibilityAddTraits(.isButton)
    }

    private var circle: some View {
        Image(systemName: bodega.hasCat ? "cat" : "figure.wave")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Self.diameter, height: Self.diameter)
            .background(bodega.hasCat ? Color.catPin : Color.pin, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: isSelected ? 3 : 2))
            .shadow(color: .black.opacity(0.3), radius: isSelected ? 4 : 2, y: isSelected ? 2 : 1)
    }

    private var nameLabel: some View {
        Text(Self.labelText(for: bodega.name))
            .font(.caption2)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
    }

    private func dropIfNeeded() {
        switch phase {
        case .atRest, .pending:
            hasLanded = false
        case .dropping:
            guard !hasLanded else { return }
            let animation: Animation = reduceMotion
                ? .easeOut(duration: 0.2)
                : .spring(duration: 0.5, bounce: 0.35)
            withAnimation(animation) { hasLanded = true }
        }
    }
}

/// A cluster of nearby bodegas, in the pin family (DD3): at least the pin's
/// 28pt, neutral fill, white count, same stroke and shadow. Tapping zooms
/// (`MapScreenView`).
struct ClusterBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(6)
            .frame(minWidth: BodegaPinView.diameter, minHeight: BodegaPinView.diameter)
            // Opaque, so the white count keeps its contrast over light tiles.
            .background(Color(.systemGray), in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            // Same 44pt target as a pin, so a neighbouring pin can't steal
            // the tap.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}
