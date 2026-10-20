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

extension BrowseView {
    /// Opens a duplicate-prompt match (#20) once the add sheet has closed.
    /// The match goes into both view models first (an idempotent upsert),
    /// so a bodega added since launch is on the map and list after Back and
    /// an Edit from its detail lands somewhere (eng R6). No coordinator,
    /// highlight, camera move or first-add: nothing was added. The push is
    /// standard, not the pin zoom (`detailOpenedFromAddFlow`).
    func openExisting(_ bodega: Bodega) {
        mapViewModel.bodegaWasAdded(bodega)
        listViewModel.bodegaWasAdded(bodega)
        detailOpenedFromAddFlow = bodega.id
        path.append(bodega)
    }

    /// The detail destination's zoom gate: from the pin on the Map tab,
    /// except for a detail opened from the duplicate prompt, which gets a
    /// standard push since its pin may be clustered, off screen or not yet
    /// loaded and iOS 26 would zoom from the screen centre (#20). Cleared
    /// when the path empties.
    func zoomsFromPin(to bodega: Bodega) -> Bool {
        activeTab == .map && detailOpenedFromAddFlow != bodega.id
    }
}

extension View {
    // Six parameters is the #20 eng review's D2 shape: the parked match stays
    // `BrowseView` state, passed in, rather than a modifier of its own.
    // swiftlint:disable function_parameter_count

    /// Presents the Add a Bodega sheet for `viewModel`. On a successful
    /// submit: the sheet closes, `onLanding` puts the user on the map, and
    /// `completion` takes over (insert, camera, drop, haptic, first-add
    /// card). The new pin is never left selected, since selecting a pin
    /// navigates (DD11).
    ///
    /// When the duplicate prompt's match is tapped (#20), the sheet closes
    /// with the draft, the match is parked in `existingToOpen`, and
    /// `openExisting` runs from `onDismiss`, so the push starts only after
    /// the sheet has finished going away.
    func addBodegaFlow(
        _ viewModel: Binding<AddBodegaViewModel?>,
        sessionStore: SessionStore,
        completion: AddCompletionCoordinator,
        existingToOpen: Binding<Bodega?>,
        openExisting: @escaping (Bodega) -> Void,
        onLanding: @escaping () -> Void
    ) -> some View {
        sheet(item: viewModel, onDismiss: {
            guard let bodega = existingToOpen.wrappedValue else { return }
            existingToOpen.wrappedValue = nil
            openExisting(bodega)
        }, content: { addViewModel in
            AddBodegaView(viewModel: addViewModel, sessionStore: sessionStore) { bodega in
                viewModel.wrappedValue = nil
                onLanding()
                completion.bodegaWasSubmitted(bodega)
            } onOpenExisting: { bodega in
                existingToOpen.wrappedValue = bodega
                viewModel.wrappedValue = nil
            }
        })
    }
    // swiftlint:enable function_parameter_count

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
