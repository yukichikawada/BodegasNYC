import CoreLocation
import MapKit
import SwiftUI

/// One Locate Me tap (#84 eng R1). The fix can come back up to 10 s after
/// the tap, by which time the user may have panned, tapped again, chosen the
/// List tab, opened a detail or entered or left placement; the result must
/// not take the camera back from them. A newer tap replaces the request; the
/// List tab, a pushed detail and any placement change cancel it from live
/// state (`MapScreenView.locateMeEvents`); a camera move is checked here.
nonisolated struct LocateRequest: Equatable, Sendable {
    let id = UUID()
    /// `MapScreenView.cameraTakeoverCount` at the tap.
    let takeoverCount: Int

    /// Whether this request's result may still move the camera: it is still
    /// the current request (not replaced or cancelled) and no settle has
    /// moved the camera's centre since the tap (a pan or another camera move
    /// took over). Otherwise the result is dropped: no camera move and no
    /// fallback.
    func shouldApply(current: LocateRequest?, takeoverCountNow: Int) -> Bool {
        current == self && takeoverCountNow == takeoverCount
    }
}

/// Locate Me lands at block zoom (#84 item 1). A precise fix flies the camera
/// to `BodegaMapViewModel.locateMeCameraDistance` over it, once: the camera
/// does not follow the user afterwards, and a later tap re-centres. Without a
/// precise fix the camera goes where MapKit puts it (`.userLocation`, its
/// zoom, the accuracy halo).
///
/// One-shot, not a handover to following (probe P1, 2026-10-21, iPhone 17
/// Pro simulator): setting `.userLocation(followsHeading: false, fallback:
/// .camera(landed))` at the landing's settle made MapKit re-zoom to its own
/// follow distance (5,885 m, 2,425 m of visible height); `MapCameraPosition`
/// has no follow-at-a-distance. So there is no follow state, no follow glyph
/// and no landing check.
extension MapScreenView {
    /// A kept fix at most this old lands at once (design D1).
    nonisolated static let locateMeKeptFixMaxAge: TimeInterval = 60
    /// Flights over three zoom levels (a ratio of 8) or 2 km take 0.9 s,
    /// the rest 0.6 s, the add flow's pan (design D8).
    nonisolated static let locateMeLongFlightRatio: Double = 8
    nonisolated static let locateMeLongFlightMeters: Double = 2000
    nonisolated static let locateMeLongFlightSeconds: TimeInterval = 0.9
    nonisolated static let locateMeFlightSeconds: TimeInterval = 0.6

    /// A settle whose centre moved more than this from the previous
    /// settle is a takeover that drops a pending Locate Me result (#84
    /// review); a heading change keeps the centre.
    nonisolated static let locateTakeoverMeters: Double = 20
    /// Settles this soon after the map's size changed are layout, not the
    /// user: on device rotation MapKit settles two or three times and moved
    /// the centre 2.4 km (simulator, portrait to landscape, 2026-10-21).
    nonisolated static let locateResizeGraceSeconds: TimeInterval = 1

    /// The sole trigger for the core When-In-Use location prompt (PRD
    /// §4.2: requested on first map interaction, not at launch); never
    /// fired by incidental panning/zooming or at app launch.
    ///
    /// Whoever replaces or cancels the request clears the pulse at that
    /// moment, and every return here leaves it false.
    func locateMe() async {
        // The first add's choreography owns the camera (design D6).
        guard !Self.ignoresLocateMe(
            dropState: addCompletion?.dropState ?? .none,
            hasFirstAddCard: addCompletion?.firstAddCard != nil
        ) else { return }
        let request = LocateRequest(takeoverCount: cameraTakeoverCount)
        isLocating = false
        locateRequest = request
        let status = await locationPermissionClient.requestWhenInUseAuthorization()
        guard locateRequest == request else { return }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            locateRequest = nil
            return
        }
        if let kept = userLocation?.latestFix, Self.landsAtOnce(on: kept, now: Date()) {
            locateRequest = nil
            // The dot obstacle and the list's fix stay fresh on every tap.
            userLocation?.requestRefresh()
            land(on: kept.coordinate)
            return
        }
        isLocating = true
        let fix = await preciseFreshFix()
        // Replaced or cancelled: whoever did it cleared the pulse.
        guard locateRequest == request else { return }
        isLocating = false
        locateRequest = nil
        guard request.shouldApply(current: request, takeoverCountNow: cameraTakeoverCount) else { return }
        if let fix {
            land(on: fix)
        } else {
            viewModel.browseModeDidChange(.nearby, currentRegion: nil)
            cameraPosition = .userLocation(followsHeading: false, fallback: .region(Self.newYorkCityDefault))
        }
    }

    /// One location round trip per tap (#84 review): the provider's refresh,
    /// which keeps only a precise fix at most `UserLocationProvider.maxFixAge`
    /// old (eng R3; never CoreLocation's hours-old cache). Without a
    /// provider (previews), the one-shot fix under the same two rules.
    private func preciseFreshFix() async -> Coordinate? {
        if let userLocation {
            await userLocation.refresh()
            return userLocation.usableFix?.coordinate
        }
        guard let fix = await locationPermissionClient.requestCurrentFix(),
              Self.landsOnFreshFix(accuracy: fix.horizontalAccuracy, timestamp: fix.timestamp, now: Date())
        else { return nil }
        return Coordinate(fix.coordinate)
    }

    /// Drops the pending request and its pulse: the List tab, a pushed
    /// detail or a placement change since the tap.
    func cancelLocateRequest() {
        locateRequest = nil
        isLocating = false
    }

    /// The live-state cancels, read where they change rather than captured
    /// at the tap. Near Me taken while placing still lands: placement does
    /// not change during its wait.
    func locateMeEvents(_ content: some View) -> some View {
        content
            .onChange(of: hasLeftMap) { _, hasLeft in
                if hasLeft { cancelLocateRequest() }
            }
            .onChange(of: isPlacingBodega) { cancelLocateRequest() }
    }

    /// Called at every settle, before `lastSettledCamera` moves on.
    func countLocateTakeover(settledAt camera: MapCamera) {
        guard let previous = lastSettledCamera,
              Self.isCameraTakeover(
                from: Coordinate(previous.centerCoordinate),
                to: Coordinate(camera.centerCoordinate),
                secondsSinceResize: mapResizedAt.map { Date().timeIntervalSince($0) }
              )
        else { return }
        cameraTakeoverCount += 1
    }

    /// Flies to block zoom over `coordinate`, keeping the heading and
    /// levelling the pitch (so the landing height is the calibrated one).
    private func land(on coordinate: Coordinate) {
        let distance = BodegaMapViewModel.locateMeCameraDistance
        let heading = lastSettledCamera?.heading ?? 0
        let move = lastSettledCamera.map { Coordinate($0.centerCoordinate).distance(to: coordinate) }
        let seconds = Self.locateMeFlightSeconds(
            ratio: lastSettledCamera.map { $0.distance / distance } ?? .infinity,
            centreMoveMeters: move ?? .infinity
        )
        let camera = MapCamera(
            centerCoordinate: coordinate.clLocationCoordinate, distance: distance, heading: heading, pitch: 0
        )
        // The nearby fetch waits for the landing's settle rather than
        // fetching around the old centre first (#84 review: one card swap).
        // A landing on the settled camera itself has no settle to wait for.
        let isSettledCamera = (move ?? .infinity) < 1
            && abs((lastSettledCamera?.distance ?? 0) - distance) < 1
        if isSettledCamera {
            viewModel.browseModeDidChange(.nearby, currentRegion: lastVisibleRegion)
        } else {
            viewModel.enterNearbyAtNextSettle()
        }
        withAnimation(.easeInOut(duration: seconds)) { cameraPosition = .camera(camera) }
    }

    /// The toolbar glyph, pulsing while a fix is awaited (design D1).
    var locateMeLabel: some View {
        Label {
            Text("Locate Me")
        } icon: {
            Image(systemName: "location")
                .symbolEffect(.pulse, isActive: isLocating)
        }
    }

    // MARK: Pure decisions (unit-tested)

    /// Design D6: Locate Me is ignored while a new pin is pending or
    /// dropping or the first-add card is up.
    static func ignoresLocateMe(dropState: AddCompletionCoordinator.DropState, hasFirstAddCard: Bool) -> Bool {
        dropState != .none || hasFirstAddCard
    }

    /// Eng R3 for the one-shot fix: precise and at most
    /// `UserLocationProvider.maxFixAge` old.
    nonisolated static func landsOnFreshFix(accuracy: Double, timestamp: Date, now: Date) -> Bool {
        landsBlockZoom(accuracy: accuracy) && now.timeIntervalSince(timestamp) <= UserLocationProvider.maxFixAge
    }

    /// Whether a settle moved the camera's centre enough to count as the
    /// user (or another move) taking over from a pending Locate Me, outside
    /// the layout grace after a map resize.
    static func isCameraTakeover(
        from previous: Coordinate,
        to settled: Coordinate,
        secondsSinceResize: TimeInterval?
    ) -> Bool {
        if let secondsSinceResize, secondsSinceResize < locateResizeGraceSeconds { return false }
        return previous.distance(to: settled) > locateTakeoverMeters
    }

    /// Design D1: a kept fix lands at once when it is precise and at most
    /// `locateMeKeptFixMaxAge` old; otherwise Locate Me waits for a new one.
    nonisolated static func landsAtOnce(on fix: UserFix, now: Date) -> Bool {
        landsBlockZoom(accuracy: fix.horizontalAccuracy)
            && now.timeIntervalSince(fix.timestamp) <= locateMeKeptFixMaxAge
    }

    /// Eng R3: only a precise fix (`UserLocationProvider.isPrecise`, 0 to
    /// 100 m) lands at block zoom; a coarse or invalid one would name the
    /// wrong block.
    nonisolated static func landsBlockZoom(accuracy: Double) -> Bool {
        UserLocationProvider.isPrecise(accuracy)
    }

    /// Design D8: 0.9 s when the flight zooms in more than three levels
    /// (`ratio`, the settled distance over the landing distance, above 8)
    /// or moves the centre more than 2 km; else 0.6 s.
    nonisolated static func locateMeFlightSeconds(ratio: Double, centreMoveMeters: Double) -> TimeInterval {
        ratio > locateMeLongFlightRatio || centreMoveMeters > locateMeLongFlightMeters
            ? locateMeLongFlightSeconds
            : locateMeFlightSeconds
    }
}
