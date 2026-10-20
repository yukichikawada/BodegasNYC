import MapKit
import SwiftUI

/// The pin → detail motion (#23 T1): the held pin's phase, its one pending
/// hold or release, and the zoom's source point. `BrowseView` owns it and
/// hands it to `MapScreenView` through the environment; it is observable so
/// `HeldPinView` and `PinTransitionAnchor` can read it in their own bodies.
@MainActor
@Observable
final class PinMotionState {
    private(set) var phase: BrowseMotion.PinToDetail.Phase = .idle
    /// The held pin's point in the map's coordinate space, for the anchor.
    private(set) var anchorPoint: CGPoint?
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// The map's proxy from the last placement, so later events can re-place.
    @ObservationIgnored private var proxy: MapProxy?
    @ObservationIgnored private var onPush: (Bodega) -> Void = { _ in }

    /// Runs `BrowseMotion.PinToDetail.reduce` and performs its effects.
    /// `onPush` opens the detail; it is kept for the timer's later events.
    func send(_ event: BrowseMotion.PinToDetail.Event, onPush: ((Bodega) -> Void)? = nil) {
        if let onPush { self.onPush = onPush }
        let (next, effects) = BrowseMotion.PinToDetail.reduce(phase, event)
        phase = next
        for effect in effects {
            switch effect {
            case .scheduleHold(let id):
                startTimer(BrowseMotion.PinToDetail.holdSeconds, then: .holdElapsed(id))
            case .scheduleRelease(let id):
                // Re-placed for the pop: the camera may have moved while the
                // detail was up (Locate Me follows the user).
                placeAnchor()
                startTimer(BrowseMotion.PinToDetail.releaseSeconds, then: .releaseElapsed(id))
            case .push(let bodega):
                // Re-placed here: a cluster zoom or pan inertia may have moved
                // the pin since the tap, and the camera may not have settled.
                placeAnchor()
                self.onPush(bodega)
            case .cancelTimer:
                timer?.cancel()
                timer = nil
            }
        }
    }

    /// A tap MapKit reported (its selection tag): feeds `pinTapped` or
    /// `clusterTapped` and returns the cluster, which the map zooms into.
    /// The stand-in annotation's tag resolves to the held pin.
    func tapped(
        _ id: MapDisplayItem.ID,
        among items: [MapDisplayItem],
        onPush: @escaping (Bodega) -> Void
    ) -> MapDisplayItem.Cluster? {
        let held = standIn(among: items).map(MapDisplayItem.pin)
        switch items.first(where: { $0.id == id }) ?? held.flatMap({ $0.id == id ? $0 : nil }) {
        case .pin(let bodega):
            send(.pinTapped(bodega), onPush: onPush)
            return nil
        case .cluster(let cluster):
            send(.clusterTapped)
            return cluster
        case nil:
            return nil
        }
    }

    /// Converts the held pin's coordinate to the anchor's point: when the
    /// held pin changes, before the push and at the pop. Never from `body`:
    /// calling `MapProxy.convert` while rendering made every `Map` update
    /// invalidate the view again, and the app hung at 100% CPU (simulator, a
    /// pin tapped during a release).
    func placeAnchor(using proxy: MapProxy? = nil) {
        if let proxy { self.proxy = proxy }
        let point = phase.bodega.flatMap { self.proxy?.convert($0.coordinate.clLocationCoordinate, to: .local) }
        if anchorPoint != point { anchorPoint = point }
    }

    /// The held pin when `items` no longer carries it as a pin (a recluster,
    /// the add highlight cleared, an edit outside the filter), so the pop
    /// still shrinks into a visible pin (design review 11A).
    func standIn(among items: [MapDisplayItem]) -> Bodega? {
        guard let held = phase.bodega else { return nil }
        let isShown = items.contains { item in
            if case .pin(let bodega) = item { return bodega.id == held.id }
            return false
        }
        return isShown ? nil : held
    }

    /// The stand-in's annotation, declared after every pin so it is drawn
    /// last, tagged like any pin so tapping it holds it again.
    @MapContentBuilder
    func standInAnnotation(among items: [MapDisplayItem]) -> some MapContent {
        if let bodega = standIn(among: items) {
            Annotation(bodega.name, coordinate: bodega.coordinate.clLocationCoordinate, anchor: .center) {
                BodegaPinView(bodega: bodega, isSelected: true, phase: .atRest)
            }
            .tag(MapDisplayItem.pin(bodega).id)
            .annotationTitles(.hidden)
        }
    }

    private func startTimer(_ seconds: TimeInterval, then event: BrowseMotion.PinToDetail.Event) {
        timer?.cancel()
        timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            send(event)
        }
    }
}

extension EnvironmentValues {
    /// `BrowseView`'s namespace for the detail's zoom transition.
    @Entry var pinZoomNamespace: Namespace.ID?
}

extension View {
    /// Feeds the held pin the events that come from outside the map: the pop
    /// (`path` emptied by the back button or a completed swipe), entering
    /// placement, and choosing the List tab.
    func pinMotionEvents(
        _ motion: PinMotionState,
        presentedBodegaID: Bodega.ID?,
        isPlacing: Bool,
        showsMap: Bool
    ) -> some View {
        onChange(of: presentedBodegaID) { oldValue, newValue in
            if oldValue != nil, newValue == nil { motion.send(.detailDismissed) }
        }
        .onChange(of: isPlacing) { _, isPlacing in
            if isPlacing { motion.send(.interrupted) }
        }
        .onChange(of: showsMap) { _, showsMap in
            if !showsMap { motion.send(.interrupted) }
        }
    }
}

/// An invisible 28pt square at the held pin's screen point: the zoom's
/// source, in SwiftUI's hierarchy rather than MapKit's annotation hosting.
/// Off screen (`convert` gave nil) there is no anchor and the push is the
/// default. Placed in the map's overlay chain, where `proxy` is in scope.
struct PinTransitionAnchor: View {
    let proxy: MapProxy
    @Environment(PinMotionState.self) private var motion
    @Environment(\.pinZoomNamespace) private var namespace

    var body: some View {
        ZStack {
            if BrowseMotion.PinToDetail.zoomEnabled, let namespace,
               let bodega = motion.phase.bodega, let point = motion.anchorPoint {
                Color.clear
                    .frame(width: BodegaPinView.diameter, height: BodegaPinView.diameter)
                    .matchedTransitionSource(id: bodega.id, in: namespace)
                    .position(point)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: motion.phase.bodega?.id) { motion.placeAnchor(using: proxy) }
    }
}

/// A map pin whose selected look follows the held pin. `Map` does not
/// re-render an `Annotation`'s content when only state the closure captured
/// changes (verified on the simulator: a pin passed `isSelected` from the
/// phase never showed the held look), so the pin reads the observable phase
/// itself, inside the view MapKit hosts.
struct HeldPinView: View {
    let bodega: Bodega
    let motion: PinMotionState
    let phase: AddCompletionCoordinator.PinPhase

    var body: some View {
        BodegaPinView(bodega: bodega, isSelected: motion.phase.bodega?.id == bodega.id, phase: phase)
    }
}
