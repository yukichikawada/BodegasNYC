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
    /// Show on Map's camera flight (#150 R2, DS7): the camera centre
    /// (`AddCompletionCoordinator.cameraCenter(for:)`) and the flight's
    /// seconds. Bound by `BrowseView`, which owns the camera position.
    @ObservationIgnored var flyCamera: (Coordinate, TimeInterval) -> Void = { _, _ in }
    /// Show on Map's VoiceOver landing (DS9).
    @ObservationIgnored var announce: (String) -> Void = { AddCompletionCoordinator.postHighPriorityAnnouncement($0) }
    /// The map's last settled region (`cameraDidSettle`): the flight's
    /// duration and DS7's no-op are measured from it.
    @ObservationIgnored private(set) var settledRegion: MKCoordinateRegion?
    /// The spotlit bodega whose announcement waits for the flight's settle.
    @ObservationIgnored private var pendingAnnouncement: Bodega?
    @ObservationIgnored private var announcementFallback: Task<Void, Never>?

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
                // Re-placed for the pop: the camera may have moved after the
                // anchor was placed (pan inertia that had not settled at the
                // push); a late Locate Me result is dropped under a detail.
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
            case .moveCamera(let bodega):
                moveCamera(to: bodega)
            }
        }
        if phase.spotlitBodega == nil { dropPendingAnnouncement() }
    }

    // MARK: Show on Map (#150)

    /// The `.moveCamera` effect: flies to the spotlit pin on Locate Me's
    /// duration rule (DS7), or, when the camera is already there, flies
    /// nowhere and announces at once. Otherwise the announcement waits for
    /// the flight's settle (a fallback covers a settle that never comes).
    private func moveCamera(to bodega: Bodega) {
        let center = AddCompletionCoordinator.cameraCenter(for: bodega.coordinate)
        dropPendingAnnouncement()
        guard let seconds = Self.spotlightFlightSeconds(from: settledRegion, to: center) else {
            announce(AppCopy.showOnMapAnnouncement(name: bodega.name).text)
            return
        }
        pendingAnnouncement = bodega
        flyCamera(center, seconds)
        announcementFallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds + Self.announcementGraceSeconds))
            guard !Task.isCancelled else { return }
            self?.announcePending()
        }
    }

    /// The map settled (`MapScreenView.cameraDidSettle`, on both tabs): the
    /// next flight measures from here, and a pending landing is announced.
    func cameraDidSettle(region: MKCoordinateRegion) {
        settledRegion = region
        announcePending()
    }

    private func announcePending() {
        guard let bodega = pendingAnnouncement else { return }
        dropPendingAnnouncement()
        guard phase.spotlitBodega?.id == bodega.id else { return }
        announce(AppCopy.showOnMapAnnouncement(name: bodega.name).text)
    }

    private func dropPendingAnnouncement() {
        pendingAnnouncement = nil
        announcementFallback?.cancel()
        announcementFallback = nil
    }

    /// How long past the flight a missing settle is waited for.
    nonisolated static let announcementGraceSeconds: TimeInterval = 0.5

    /// DS7: `nil` (no flight) when `settled` is already centred within
    /// `settleTolerance` of `center` at the street span, else Locate Me's
    /// rule: 0.9 s when it zooms in more than three levels or moves more
    /// than 2 km, 0.6 s otherwise. The span compared is the smaller of the
    /// two, the one MapKit fits the requested square span to. With no settle
    /// yet, the long flight.
    static func spotlightFlightSeconds(
        from settled: MKCoordinateRegion?,
        to center: Coordinate
    ) -> TimeInterval? {
        guard let settled else { return MapScreenView.locateMeLongFlightSeconds }
        let target = AddCompletionCoordinator.cameraSpan
        let tolerance = AddCompletionCoordinator.settleTolerance
        let span = min(settled.span.latitudeDelta, settled.span.longitudeDelta)
        if abs(settled.center.latitude - center.latitude) <= tolerance,
           abs(settled.center.longitude - center.longitude) <= tolerance,
           abs(span - target) <= tolerance {
            return nil
        }
        return MapScreenView.locateMeFlightSeconds(
            ratio: span / target,
            centreMoveMeters: Coordinate(settled.center).distance(to: center)
        )
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
    /// placement, and choosing the List tab. Show on Map's `.showOnMap` is
    /// sent by `BrowseView.showOnMap`, before the pop's `.detailDismissed`,
    /// which the spotlight then ignores.
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
///
/// The block-zoom label (#67) follows the same rule: the pin reads the
/// observable `PinLabelState` here, not a captured flag.
struct HeldPinView: View {
    let bodega: Bodega
    let motion: PinMotionState
    let labels: PinLabelState
    let phase: AddCompletionCoordinator.PinPhase

    var body: some View {
        BodegaPinView(
            bodega: bodega,
            isSelected: motion.phase.bodega?.id == bodega.id,
            phase: phase,
            showsBlockLabel: labels.ids.contains(bodega.id)
        )
    }
}
