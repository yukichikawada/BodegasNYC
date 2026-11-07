import MapKit
import SwiftUI

/// Show on Map (#150): the detail's way back to its bodega on the live map,
/// kept out of `BrowseView.swift` so that file stays within its length
/// budget. The map side is `PinToDetailMotion`'s `.spotlit` phase (eng R2).
extension BrowseView {
    /// From a list-opened detail (R5) the Map tab is chosen first, under the
    /// detail (the list page leaves unseen, the search field resigns and
    /// VoiceOver hears the screen change), then the standard pop reveals the
    /// map and the camera flies at once. From a pin-opened detail the zoom
    /// pop shrinks the page into the pin where it is, and the camera flies
    /// when the release has run (R3). `bodega` is the detail's post-edit value.
    ///
    /// From the List the pop waits one main-actor turn after the tab switch:
    /// popping in the same update left the list's bottom search field drawn
    /// over the map as a frozen glass capsule until the next push (iPhone SE
    /// simulator, iOS 26.5, either order and unanimated alike). One turn
    /// lets the hidden root drop the field before it is revealed.
    ///
    /// A second tap (the button or the preview) while the first is still
    /// under way is ignored: during the deferred pop `showOnMapPending` is
    /// set, and once the pop has begun `path` is empty. So the event,
    /// telemetry and flight run once per detail.
    func showOnMap(_ bodega: Bodega) {
        guard !showOnMapPending, !path.isEmpty else { return }
        telemetry.capture(.showOnMap(fromMap: zoomsFromPin(to: bodega)))
        guard activeTab != .map else {
            path.removeAll()
            pinMotion.send(.showOnMap(bodega))
            return
        }
        tabSelection.wrappedValue = .map
        showOnMapPending = true
        Task { @MainActor in
            showOnMapPending = false
            path.removeAll()
            pinMotion.send(.showOnMap(bodega))
        }
    }

    /// Whether a detail counts as opened from its map pin: opened on the Map
    /// tab, and not from the add flow's duplicate prompt (a standard push
    /// with no pin, #20). The zoom transition (`zoomsFromPin`) and Show on
    /// Map's `from_map` (#150 R4) both read it.
    static func opensFromPin(origin: Tab, addFlowBodegaID: Bodega.ID?, bodegaID: Bodega.ID) -> Bool {
        origin == .map && addFlowBodegaID != bodegaID
    }

    /// The pushed detail's entry origin (R5): captured on the render after
    /// the push and cleared when `path` empties. Until it is captured, the
    /// live tab is the origin, since nothing can change the tab between a
    /// push and that render.
    func zoomOrigin() -> Tab {
        detailOrigin ?? activeTab
    }

    /// Binds the spotlight's camera flight to the camera and mirrors the
    /// spotlit pin into the map view model's clustering exclusion (one
    /// writer: this modifier).
    var spotlightWiring: some ViewModifier {
        SpotlightWiring(pinMotion: pinMotion, mapViewModel: mapViewModel, camera: $cameraPosition)
    }
}

private struct SpotlightWiring: ViewModifier {
    let pinMotion: PinMotionState
    let mapViewModel: BodegaMapViewModel
    let camera: Binding<MapCameraPosition>

    func body(content: Content) -> some View {
        content
            .onAppear {
                let camera = camera
                // Locate Me's easing and camera (#156); the pan stays under
                // Reduce Motion, which lands level (DESIGN.md Motion).
                pinMotion.flyCamera = { target, seconds in
                    withAnimation(.easeInOut(duration: seconds)) {
                        camera.wrappedValue = .camera(target)
                    }
                }
            }
            .onChange(of: pinMotion.phase.spotlitBodega?.id) { _, id in
                mapViewModel.spotlitBodegaID = id
            }
    }
}
