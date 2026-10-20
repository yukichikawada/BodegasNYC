import MapKit
import SwiftUI

/// `BrowseView`'s wiring for `AddCompletionCoordinator` (#25), kept out of
/// `BrowseView.swift` so that file stays within its length budget.
extension AddCompletionCoordinator {
    /// The coordinator `BrowseView` owns, holding the same view models the
    /// view keeps: inserts go to both (R6), the highlight to the map's (R7),
    /// and the first add ends the tutorial (#22). The camera move is bound
    /// later with `cameraMove`, once the view's camera state exists. The new
    /// pin is never selected after an add, since selecting navigates (DD11).
    static func forBrowsing(
        _ firstRunState: FirstRunState,
        _ mapViewModel: BodegaMapViewModel,
        _ listViewModel: BodegaListViewModel
    ) -> AddCompletionCoordinator {
        AddCompletionCoordinator(
            firstRunState: firstRunState,
            insert: { bodega in
                mapViewModel.bodegaWasAdded(bodega)
                listViewModel.bodegaWasAdded(bodega)
            },
            moveCamera: { _ in },
            setHighlighted: { mapViewModel.highlightedBodegaID = $0 },
            onFirstAdd: { TutorialTips.invalidateAll() }
        )
    }

    /// Centers the map on the given point (the coordinator passes the pin's
    /// `cameraCenter(for:)`) at street zoom (span 0.004), animated
    /// over 0.6 s; the drop waits for it to settle.
    static func cameraMove(_ cameraPosition: Binding<MapCameraPosition>) -> (Coordinate) -> Void {
        { coordinate in
            withAnimation(.easeInOut(duration: 0.6)) {
                cameraPosition.wrappedValue = .region(
                    MKCoordinateRegion(
                        center: coordinate.clLocationCoordinate,
                        span: MKCoordinateSpan(latitudeDelta: cameraSpan, longitudeDelta: cameraSpan)
                    )
                )
            }
        }
    }
}

extension View {
    /// Presents the Add a Bodega sheet for `viewModel`. On a successful
    /// submit: the sheet closes, `onLanding` puts the user on the map, and
    /// `completion` takes over (insert, camera, drop, haptic, first-add
    /// card). The new pin is never left selected, since selecting a pin
    /// navigates (DD11).
    func addBodegaFlow(
        _ viewModel: Binding<AddBodegaViewModel?>,
        sessionStore: SessionStore,
        completion: AddCompletionCoordinator,
        onLanding: @escaping () -> Void
    ) -> some View {
        sheet(item: viewModel) { addViewModel in
            AddBodegaView(viewModel: addViewModel, sessionStore: sessionStore) { bodega in
                viewModel.wrappedValue = nil
                onLanding()
                completion.bodegaWasSubmitted(bodega)
            }
        }
    }

    /// Hooks `coordinator` up to the browse screen: binds its camera move
    /// to `camera` on appear, plays the success haptic when the pin drops
    /// (D8), and cancels what's left of an add (no card, no late haptic)
    /// when the user leaves the map: a detail push or the List tab.
    func addCompletion(
        _ coordinator: AddCompletionCoordinator,
        camera: Binding<MapCameraPosition>,
        hasLeftMap: Bool
    ) -> some View {
        sensoryFeedback(.success, trigger: coordinator.hapticTrigger)
            .onAppear { coordinator.moveCamera = AddCompletionCoordinator.cameraMove(camera) }
            .onChange(of: hasLeftMap) { _, hasLeft in
                if hasLeft { coordinator.cancel() }
            }
    }
}
