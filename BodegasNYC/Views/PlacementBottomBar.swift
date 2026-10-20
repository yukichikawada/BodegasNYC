import SwiftUI
import TipKit

/// The confirm/cancel bar shown while `isPlacingBodega` — pans underneath a
/// fixed center-screen pin (see `MapScreenView`'s `.overlay`); "Use This
/// Location" reads whatever coordinate is currently under that pin. It sits
/// in the map's bottom safe-area inset, so the pin is centred on the region
/// left visible above it.
///
/// "Near Me" (DD2) uses the toolbar's `locateMe()` path; always present.
/// From `.xLarge` up the bar wraps to two rows. The placement tip (#22) is a
/// popover on Use This Location (not a toolbar item, so R1 allows it).
struct PlacementBottomBar: View {
    let onUseThisLocation: () -> Void
    let onCancel: () -> Void
    let onNearMe: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPlacementTipPresented = true

    private var isStacked: Bool { dynamicTypeSize >= .xLarge }

    var body: some View {
        VStack(spacing: 12) {
            if isStacked {
                // One row only while neither label has to wrap (AX sizes).
                ViewThatFits(in: .horizontal) {
                    HStack { nearMeButton.fixedSize(); Spacer(); cancelButton.fixedSize() }
                    VStack(spacing: 12) { nearMeButton; cancelButton }
                }
                useThisLocationButton
            } else {
                HStack { nearMeButton; cancelButton; Spacer(); useThisLocationButton }
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    private var cancelButton: some View { Button("Cancel", action: onCancel) }

    private var nearMeButton: some View {
        Button(action: onNearMe) {
            Label(AppCopy.nearMeAction.copy.text, systemImage: "location.fill")
        }
        .buttonStyle(.bordered)
    }

    private var useThisLocationButton: some View {
        Button(action: onUseThisLocation) {
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
