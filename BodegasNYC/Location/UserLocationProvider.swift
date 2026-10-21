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
    /// Coarser fixes are kept but not published (eng D10): with Precise
    /// Location off the fix is kilometres wide, and a block count from it
    /// would be fiction.
    nonisolated static let maxAccuracyMeters: Double = 100
    /// A kept fix is dropped once it is older than this when a refresh fails
    /// to get a new one (eng D11).
    nonisolated static let maxFixAge: TimeInterval = 10 * 60

    /// The last fix received, published or not.
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

    /// Whether location is authorized right now. The rows and the header
    /// reserve the distance slot only then (design D2); otherwise they render
    /// exactly as before #68.
    var isAuthorized: Bool { checkAuthorized() }

    @ObservationIgnored private let checkAuthorized: @MainActor () -> Bool
    @ObservationIgnored private let requestFix: @MainActor () async -> CLLocation?
    @ObservationIgnored private let now: @MainActor () -> Date

    init(
        isAuthorized: @escaping @MainActor () -> Bool,
        requestFix: @escaping @MainActor () async -> CLLocation?,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        checkAuthorized = isAuthorized
        self.requestFix = requestFix
        self.now = now
    }

    /// Production wiring: authorization and the one-shot fix both come from
    /// the app's single `LocationPermissionClient`. Reading its observable
    /// `authorizationStatus` through `isAuthorized` keeps SwiftUI tracking it.
    convenience init(client: LocationPermissionClient) {
        self.init(
            isAuthorized: {
                LocationPermissionClient.canRequestCurrentLocation(authorizationStatus: client.authorizationStatus)
            },
            requestFix: { await client.requestCurrentFix() }
        )
    }

    /// Fetches one fix. Unauthorized before or after the await clears the fix
    /// and discards any result (a revocation must not be undone by a fix that
    /// was already in flight). A failed or timed-out fetch keeps the previous
    /// fix while it is at most `maxFixAge` old, so one slow fix does not blank
    /// every distance on screen. Overlapping refreshes are safe: each writes
    /// when it completes, and the last to complete wins.
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
        if let location {
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
