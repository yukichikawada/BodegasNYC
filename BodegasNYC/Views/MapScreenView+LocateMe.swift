import CoreLocation
import MapKit
import SwiftUI

/// One Locate Me tap (#84 eng R1). The fix can come back up to 10 s after
/// the tap (`LocationPermissionClient.requestCurrentFix`), by which time the
/// user may have panned, tapped again, chosen the List tab or entered or
/// left placement; the result must not take the camera back from them.
nonisolated struct LocateRequest: Equatable, Sendable {
    let id = UUID()
    /// `MapScreenView.settleCount` at the tap.
    let settleCount: Int
    /// Whether the tap came from the placement card's Near Me (design D7).
    let wasPlacing: Bool

    /// Whether this request's result (a fix, or nil) may still move the
    /// camera: it is the latest tap, the camera has not settled since the
    /// tap (a pan, a pinch or another camera move took over), the Map tab is
    /// showing, and placement is as it was at the tap (off for the toolbar
    /// button, on for Near Me). Otherwise the result is dropped: no camera
    /// move and no fallback.
    func shouldApply(current: LocateRequest?, settleCountNow: Int, showsToolbar: Bool, isPlacing: Bool) -> Bool {
        current == self && settleCountNow == settleCount && showsToolbar && isPlacing == wasPlacing
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

    /// The sole trigger for the core When-In-Use location prompt (PRD
    /// §4.2: requested on first map interaction, not at launch); never
    /// fired by incidental panning/zooming or at app launch.
    func locateMe() async {
        // The first add's choreography owns the camera (design D6).
        guard !Self.ignoresLocateMe(
            dropState: addCompletion?.dropState ?? .none,
            hasFirstAddCard: addCompletion?.firstAddCard != nil
        ) else { return }
        let request = LocateRequest(settleCount: settleCount, wasPlacing: isPlacingBodega)
        locateRequest = request
        let status = await locationPermissionClient.requestWhenInUseAuthorization()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        viewModel.browseModeDidChange(.nearby, currentRegion: nil)
        // The dot obstacle and the list's fix stay fresh on every tap.
        userLocation?.requestRefresh()
        if let kept = userLocation?.latestFix, Self.landsAtOnce(on: kept, now: Date()) {
            if isLocateRequestCurrent(request) { land(on: kept.coordinate) }
            return
        }
        isLocating = true
        let fix = await locationPermissionClient.requestCurrentFix()
        // A newer tap owns the pulse and the camera.
        guard locateRequest == request else { return }
        isLocating = false
        guard isLocateRequestCurrent(request) else { return }
        if let fix, Self.landsBlockZoom(accuracy: fix.horizontalAccuracy) {
            land(on: Coordinate(fix.coordinate))
        } else {
            cameraPosition = .userLocation(followsHeading: false, fallback: .region(Self.newYorkCityDefault))
        }
    }

    private func isLocateRequestCurrent(_ request: LocateRequest) -> Bool {
        request.shouldApply(
            current: locateRequest,
            settleCountNow: settleCount,
            showsToolbar: showsToolbar,
            isPlacing: isPlacingBodega
        )
    }

    /// Flies to block zoom over `coordinate`, keeping the heading and
    /// levelling the pitch (so the landing height is the calibrated one).
    private func land(on coordinate: Coordinate) {
        isLocating = false
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
