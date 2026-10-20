import SwiftUI
import TipKit

/// The placement card shown while `isPlacingBodega` (#23 T3): the user pans
/// the map under a fixed crosshair (`MapScreenView`'s overlay), and "Use This
/// Location" reads whatever coordinate is under it. It is the bottom slot's
/// top-precedence occupant, floating over the map like `MapBottomCard`
/// rather than insetting it, so entering placement never moves a pin.
///
/// Visual contract (DESIGN.md Components, "Placement card"): the DD13 card
/// chrome (`MapBottomCardChrome`) plus the small card shadow, a `.headline`
/// title in voice, and an action row of Near Me and Cancel (`.bordered`) and
/// Use This Location (`.borderedProminent`). A task panel: the material
/// groups the task and its buttons keep native control styling, the one
/// material-under-controls exception. From `.xLarge` up the row stacks.
///
/// "Near Me" (DD2) uses the toolbar's `locateMe()` path; always present. The
/// placement tip (#22) is a popover on Use This Location, presented once the
/// card is at rest and dismissed before it leaves.
struct PlacementBottomBar: View {
    let onUseThisLocation: () -> Void
    let onCancel: () -> Void
    let onNearMe: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    /// False until the slot transition settles (`.task` below), so the
    /// popover anchors to a resting button; set false by `dismissTip()`
    /// before the card is removed.
    @State private var isPlacementTipPresented = false

    private var isStacked: Bool { dynamicTypeSize >= .xLarge }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppCopy.placementCardTitle.copy.text)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MapBottomCardChrome(isShadowed: true))
        .task {
            // Cancelled when the card leaves first: then the tip never shows.
            guard (try? await Task.sleep(for: .seconds(BrowseMotion.BottomSlot.placementTipDelaySeconds))) != nil
            else { return }
            isPlacementTipPresented = true
        }
    }

    @ViewBuilder
    private var actions: some View {
        if isStacked {
            VStack(spacing: 12) {
                // One row only while neither label has to wrap (AX sizes).
                ViewThatFits(in: .horizontal) {
                    HStack { nearMeButton.fixedSize(); Spacer(); cancelButton.fixedSize() }
                    VStack(spacing: 12) { nearMeButton; cancelButton }
                }
                useThisLocationButton
            }
        } else {
            HStack { nearMeButton; cancelButton; Spacer(); useThisLocationButton }
        }
    }

    /// Ends placement, dismissing the tip first so it never outlives the
    /// card it points at.
    private func endPlacement(_ action: () -> Void) {
        isPlacementTipPresented = false
        action()
    }

    private var cancelButton: some View {
        Button("Cancel") { endPlacement(onCancel) }
            .buttonStyle(.bordered)
    }

    private var nearMeButton: some View {
        Button(action: onNearMe) {
            Label(AppCopy.nearMeAction.copy.text, systemImage: "location.fill")
        }
        .buttonStyle(.bordered)
    }

    private var useThisLocationButton: some View {
        Button {
            endPlacement(onUseThisLocation)
        } label: {
            Text("Use This Location")
                .frame(maxWidth: isStacked ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .popoverTip(PlacementTip(), isPresented: $isPlacementTipPresented, arrowEdge: .bottom)
        // A popover tip keeps the appearance it was presented with; re-present
        // it after a light/dark switch.
        .onChange(of: colorScheme) {
            guard isPlacementTipPresented else { return }
            isPlacementTipPresented = false
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                isPlacementTipPresented = true
            }
        }
    }
}
