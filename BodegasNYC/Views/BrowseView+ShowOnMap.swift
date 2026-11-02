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
    func showOnMap(_ bodega: Bodega) {
        telemetry.capture(.showOnMap(fromMap: zoomOrigin() == .map))
        guard activeTab != .map else {
            path.removeAll()
            pinMotion.send(.showOnMap(bodega))
            return
        }
        tabSelection.wrappedValue = .map
        Task { @MainActor in
            path.removeAll()
            pinMotion.send(.showOnMap(bodega))
        }
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
                // Locate Me's easing; the pan stays under Reduce Motion
                // (DESIGN.md Motion), like the add flow's.
                pinMotion.flyCamera = { center, seconds in
                    withAnimation(.easeInOut(duration: seconds)) {
                        camera.wrappedValue = .region(
                            MKCoordinateRegion(
                                center: center.clLocationCoordinate,
                                span: MKCoordinateSpan(
                                    latitudeDelta: AddCompletionCoordinator.cameraSpan,
                                    longitudeDelta: AddCompletionCoordinator.cameraSpan
                                )
                            )
                        )
                    }
                }
            }
            .onChange(of: pinMotion.phase.spotlitBodega?.id) { _, id in
                mapViewModel.spotlitBodegaID = id
            }
    }
}
