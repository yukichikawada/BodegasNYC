import SwiftUI

/// The placement crosshair (#23 T3), drawn over the map while placing:
/// `figure.wave`, centred horizontally and vertically in the band the
/// placement card leaves uncovered (`BrowseMotion.crosshairY`), so it stays
/// fully visible at every Dynamic Type size and orientation. It lands like a
/// dropped pin and, under Reduce Motion, fades in. Silent to VoiceOver: the
/// placement card's title is the instruction.
///
/// Reports its centre in global coordinates through `point`; `MapScreenView`
/// converts that point with `MapProxy`, so "Use This Location" submits the
/// coordinate drawn under the figure.
struct PlacementCrosshair: View {
    let isPlacing: Bool
    /// The placement card's height, its slot chrome included.
    let cardHeight: CGFloat
    /// The slot's lift above the attribution row.
    let clearance: CGFloat
    @Binding var point: CGPoint?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Waits for the card's first measurement, so the very first placement
    /// lands the figure where it stays instead of jumping up a frame later.
    private var isShown: Bool { isPlacing && cardHeight > 0 }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isShown {
                    // `figure.wave` has no directional "point" the way
                    // `mappin` does, so its centre is the submitted point.
                    Image(systemName: "figure.wave")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                        .onGeometryChange(for: CGPoint.self) { proxy in
                            let frame = proxy.frame(in: .global)
                            return CGPoint(x: frame.midX, y: frame.midY)
                        } action: { point = $0 }
                        .position(
                            x: geometry.size.width / 2,
                            y: BrowseMotion.crosshairY(
                                mapHeight: geometry.size.height,
                                cardHeight: cardHeight,
                                clearance: clearance
                            )
                        )
                        .transition(BrowseMotion.Crosshair.transition(reduceMotion: reduceMotion))
                }
            }
            .animation(
                BrowseMotion.Crosshair.animation(isPlacing: isShown, reduceMotion: reduceMotion),
                value: isShown
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
