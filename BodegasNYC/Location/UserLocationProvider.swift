import CoreLocation
import Foundation
import Observation

/// One location fix as the distance code needs it (#68, eng D10): where,
/// how sure, and when.
nonisolated struct UserFix: Equatable, Sendable {
    var coordinate: Coordinate
    /// Metres, as `CLLocation.horizontalAccuracy` reports it; negative means
    /// the fix is invalid.
    var horizontalAccuracy: Double
    var timestamp: Date
}

/// The user's position for the List tab's and the detail header's distances
/// (#68, eng D6). Reads a fix only when location is already authorized and
/// never prompts: the map's Locate Me stays the one way in (PRD §4.2).
///
/// `BrowseView` owns it and calls `refresh()` whenever the List tab is
/// shown, the navigation path changes, authorization changes, or the app
/// returns to the foreground with the list or a detail on screen. A fresh fix
/// on those events is the contract, not continuous tracking, and expiry is
/// evaluated only inside `refresh()`, never by a timer (a list that blanks
/// mid-read is worse; design review mechanics).
///
/// No permission, a coarse fix, an expired fix and Precise Location off are
/// all silent: `usableFix` is `nil` and the views show no distance, no error.
@MainActor
@Observable
final class UserLocationProvider {
    /// Coarser fixes are never stored or published (eng D10): with Precise
    /// Location off the fix is kilometres wide, and a block count from it
    /// would be fiction.
    nonisolated static let maxAccuracyMeters: Double = 100
    /// A kept fix is dropped once it is older than this when a refresh fails
    /// to get a new one (eng D11).
    nonisolated static let maxFixAge: TimeInterval = 10 * 60

    /// The last fresh, precise fix received.
    private(set) var latestFix: UserFix?

    /// `latestFix` when its accuracy is good enough to measure blocks from
    /// (`0 <= horizontalAccuracy <= maxAccuracyMeters`), else `nil`. What the
    /// views read: its accuracy also gates "Around the corner" (design D3).
    var usableFix: UserFix? {
        guard let latestFix, Self.isPrecise(latestFix.horizontalAccuracy) else { return nil }
        return latestFix
    }

    /// The published coordinate (eng D6): `usableFix`'s, or `nil`.
    var coordinate: Coordinate? { usableFix?.coordinate }

    /// Whether location is authorized right now.
    var isAuthorized: Bool { checkAuthorized() }

    /// Whether a usable fix is plausible: authorized with full accuracy. The
    /// rows and the header reserve the distance slot only then (design D2, as
    /// refined in review): with Precise Location off every fix is coarse, so
    /// they render exactly as unauthorized instead of keeping a blank line.
    var reservesDistanceSlot: Bool { checkAuthorized() && checkFullAccuracy() }

    @ObservationIgnored private let checkAuthorized: @MainActor () -> Bool
    @ObservationIgnored private let checkFullAccuracy: @MainActor () -> Bool
    @ObservationIgnored private let requestFix: @MainActor () async -> CLLocation?
    @ObservationIgnored private let now: @MainActor () -> Date
    /// The refresh started by `requestRefresh()`, while it runs.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        isAuthorized: @escaping @MainActor () -> Bool,
        isFullAccuracy: @escaping @MainActor () -> Bool = { true },
        requestFix: @escaping @MainActor () async -> CLLocation?,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        checkAuthorized = isAuthorized
        checkFullAccuracy = isFullAccuracy
        self.requestFix = requestFix
        self.now = now
    }

    /// Production wiring: authorization, accuracy and the one-shot fix all
    /// come from the app's single `LocationPermissionClient`. Reading its
    /// observable properties through these closures keeps SwiftUI tracking them.
    convenience init(client: LocationPermissionClient) {
        self.init(
            isAuthorized: {
                LocationPermissionClient.canRequestCurrentLocation(authorizationStatus: client.authorizationStatus)
            },
            isFullAccuracy: { client.accuracyAuthorization == .fullAccuracy },
            requestFix: { await client.requestCurrentFix() }
        )
    }

    /// What the view triggers call: starts `refresh()` unless one is already
    /// in flight, in which case it does nothing (the running one is at most
    /// the fix timeout old and would return the same fix).
    func requestRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            await refresh()
            refreshTask = nil
        }
    }

    /// Fetches one fix. Unauthorized before or after the await clears the fix
    /// and discards any result (a revocation must not be undone by a fix that
    /// was already in flight). Only a fresh (at most `maxFixAge` old) and
    /// precise fix is stored: a failed or timed-out fetch, CoreLocation's
    /// stale cached fix, or a coarse fix all keep the previous fix while it is
    /// at most `maxFixAge` old, so one bad fix does not blank or degrade every
    /// distance on screen. Overlapping direct calls are safe: each writes when
    /// it completes, and the last to complete wins.
    func refresh() async {
        guard checkAuthorized() else {
            latestFix = nil
            return
        }
        let location = await requestFix()
        guard checkAuthorized() else {
            latestFix = nil
            return
        }
        if let location,
           now().timeIntervalSince(location.timestamp) <= Self.maxFixAge,
           Self.isPrecise(location.horizontalAccuracy) {
            latestFix = UserFix(
                coordinate: Coordinate(location.coordinate),
                horizontalAccuracy: location.horizontalAccuracy,
                timestamp: location.timestamp
            )
        } else if let kept = latestFix, now().timeIntervalSince(kept.timestamp) > Self.maxFixAge {
            latestFix = nil
        }
    }

    nonisolated static func isPrecise(_ horizontalAccuracy: Double) -> Bool {
        horizontalAccuracy >= 0 && horizontalAccuracy <= maxAccuracyMeters
    }
}
