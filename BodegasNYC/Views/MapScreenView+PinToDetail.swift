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
    /// Show on Map's camera flight (#150 R2, DS7; #156): the block-zoom
    /// camera over `AddCompletionCoordinator.cameraCenter(for:heading:)` and
    /// the flight's seconds. Bound by `BrowseView`, which owns the camera
    /// position.
    @ObservationIgnored var flyCamera: (MapCamera, TimeInterval) -> Void = { _, _ in }
    /// Show on Map's VoiceOver landing (DS9).
    @ObservationIgnored var announce: (String) -> Void = { AddCompletionCoordinator.postHighPriorityAnnouncement($0) }
    /// The map's last settled camera (`cameraDidSettle`): the flight's
    /// duration, its heading and DS7's no-op are measured from it.
    @ObservationIgnored private(set) var settledCamera: MapCamera?
    /// Design DS6: the user levelled a pitched map by hand (the pitch toggle
    /// or two fingers), so both landings stay level until a settle arrives
    /// pitched again. Session state: it lives as long as the browse screen.
    @ObservationIgnored private(set) var userLevelled = false
    /// An app camera write that levels a pitched map is in flight (the add
    /// flow, Locate Me's coarse-fix fallback or a level landing): its settle
    /// is not the user's level.
    @ObservationIgnored private var appLevelWriteInFlight = false
    /// The landing pitch's other inputs (design DS5, DS8), kept current by
    /// `MapScreenView`, which reads the environment.
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored var isCompactHeight = false
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
        let heading = settledCamera?.heading ?? 0
        let target = BodegaMapViewModel.blockZoomCamera(
            center: AddCompletionCoordinator.cameraCenter(for: bodega.coordinate, heading: heading),
            heading: heading,
            pitch: landingPitch
        )
        dropPendingAnnouncement()
        guard let seconds = Self.spotlightFlightSeconds(from: settledCamera, to: target) else {
            announce(AppCopy.showOnMapAnnouncement(name: bodega.name).text)
            return
        }
        pendingAnnouncement = bodega
        if target.pitch < BodegaMapViewModel.levelPitchMaximum { noteAppLevelWrite() }
        flyCamera(target, seconds)
        announcementFallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds + Self.announcementGraceSeconds))
            guard !Task.isCancelled else { return }
            self?.announcePending()
        }
    }

    /// The map settled (`MapScreenView.cameraDidSettle`, on both tabs): the
    /// next flight measures from here, the user's level is judged (DS6), and
    /// a pending landing is announced.
    func cameraDidSettle(camera: MapCamera) {
        userLevelled = BodegaMapViewModel.userLevelled(
            was: userLevelled,
            previousPitch: settledCamera?.pitch,
            settledPitch: camera.pitch,
            appLevelWriteInFlight: appLevelWriteInFlight
        )
        appLevelWriteInFlight = false
        settledCamera = camera
        announcePending()
    }

    /// The pitch both landings fly to now (design DS5, DS6, DS8).
    var landingPitch: Double {
        BodegaMapViewModel.landingPitch(
            reduceMotion: reduceMotion, compact: isCompactHeight, userLevelled: userLevelled
        )
    }

    /// An app camera write is about to level the map: when the settled
    /// camera is pitched, its settle must not count as the user's level
    /// (DS6). A level map needs no flag (no settle could set it), so a write
    /// that never settles cannot leave one behind.
    func noteAppLevelWrite() {
        guard let pitch = settledCamera?.pitch, pitch > BodegaMapViewModel.pitchedPitchMinimum else { return }
        appLevelWriteInFlight = true
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

    /// How close the settled centre must be to the target for Show on Map to
    /// count as already there (#156 eng D6): about a sixth of the landing's
    /// 173 m level-equivalent height, and still over MapKit's settle rounding.
    nonisolated static let spotlightCentreToleranceMeters: Double = 30
    /// The no-op's distance (relative) and pitch tolerances: MapKit may
    /// settle a pitched camera a little off the requested values.
    nonisolated static let spotlightDistanceTolerance: Double = 0.10
    nonisolated static let spotlightPitchToleranceDegrees: Double = 5

    /// DS7 on cameras (#156): `nil` (no flight) when `settled` is already on
    /// `target`: centre within 30 m, distance within 10% and pitch within
    /// 5°. Else Locate Me's rule: 0.9 s when it zooms in more than three
    /// levels or moves more than 2 km, 0.6 s otherwise. With no settle yet,
    /// the long flight.
    nonisolated static func spotlightFlightSeconds(from settled: MapCamera?, to target: MapCamera) -> TimeInterval? {
        guard let settled else { return MapScreenView.locateMeLongFlightSeconds }
        let move = Coordinate(settled.centerCoordinate).distance(to: Coordinate(target.centerCoordinate))
        if move <= spotlightCentreToleranceMeters,
           abs(settled.distance - target.distance) <= target.distance * spotlightDistanceTolerance,
           abs(settled.pitch - target.pitch) <= spotlightPitchToleranceDegrees {
            return nil
        }
        return MapScreenView.locateMeFlightSeconds(ratio: settled.distance / target.distance, centreMoveMeters: move)
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
