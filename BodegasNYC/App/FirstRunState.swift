import Foundation
import Observation

/// First-run flags for onboarding (#21) and the first-add moment (#25).
///
/// Per-device by design: stored in `UserDefaults`, never synced and never
/// derived from the server, so a signed-in user on a second device sees
/// onboarding (and, later, the first-add card) once more there.
///
/// Owned by `RootView` as `@State` created in its `init`, not built in
/// `RootView.load()` like the rest of `AppEnvironment`: `load()` re-runs on
/// Retry, which would replace this object and drop `pendingTutorialAdd`, and
/// onboarding has to render in the first frame, before the environment
/// exists (eng review R2/R4).
@Observable
@MainActor
final class FirstRunState {
    /// The app's one instance. The app supports multiple scenes (iPad
    /// windows), and each scene builds its own `RootView`; separate
    /// instances over the same `UserDefaults` would diverge in memory (one
    /// window finishes onboarding while another still shows it, and
    /// `pendingTutorialAdd` set in one is invisible to the other). Tests
    /// and previews inject their own instance instead.
    static let shared = FirstRunState()

    nonisolated static let hasCompletedOnboardingKey = "firstRun.hasCompletedOnboarding"
    nonisolated static let hasAddedFirstBodegaKey = "firstRun.hasAddedFirstBodega"

    private(set) var hasCompletedOnboarding: Bool
    private(set) var hasAddedFirstBodega: Bool

    /// Set when onboarding ends with "Add a Bodega You Know"; `BrowseView`
    /// consumes it (enters placement mode, then clears it). Not persisted:
    /// a relaunch mid-handoff simply lands on the map.
    var pendingTutorialAdd = false

    /// Whether `RootView` starts with the onboarding overlay up.
    var shouldShowOnboarding: Bool { !hasCompletedOnboarding }

    @ObservationIgnored private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        hasCompletedOnboarding = userDefaults.bool(forKey: Self.hasCompletedOnboardingKey)
        hasAddedFirstBodega = userDefaults.bool(forKey: Self.hasAddedFirstBodegaKey)
    }

    /// Every onboarding exit, first run or replay. Never touches
    /// `hasAddedFirstBodega`.
    func completeOnboarding(wantsToAdd: Bool) {
        hasCompletedOnboarding = true
        userDefaults.set(true, forKey: Self.hasCompletedOnboardingKey)
        pendingTutorialAdd = wantsToAdd
    }

    /// Records a successful add. Returns `true` only on the call that flips
    /// the flag, i.e. the first add on this device.
    @discardableResult
    func markFirstBodegaAdded() -> Bool {
        guard !hasAddedFirstBodega else { return false }
        hasAddedFirstBodega = true
        userDefaults.set(true, forKey: Self.hasAddedFirstBodegaKey)
        return true
    }
}
