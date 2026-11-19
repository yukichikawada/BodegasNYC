import Foundation

/// When a pending shared walk may present (#177 eng E2, design "First
/// run"): only once the environment is ready, onboarding is not showing and
/// nothing else is presented, so nothing the person was doing is covered.
/// A walk held behind another sheet presents no sooner than 0.5 s after
/// that sheet has finished going. Pure: `RootView` feeds it a read-only
/// check of the key window every 0.5 s while a walk is pending and on
/// scene activation.
///
/// The Streets Walked intro (#126) yields to a pending walk through its own
/// gate (`StreetsWalkedIntro.Inputs.isSharedWalkPending`), so a walk that
/// arrives first presents first and the intro's 1.5 s clock restarts only
/// after the Shared Walk sheet closes.
nonisolated struct SharedWalkPresentation: Equatable {
    /// What a check sees.
    struct Inputs: Equatable {
        var isEnvironmentReady: Bool
        var isOnboardingShowing: Bool
        /// The key window's root view controller has a
        /// `presentedViewController`: a sheet, cover or alert is up.
        var isSomethingPresented: Bool
    }

    /// The least time between seeing nothing presented after a blocking
    /// presentation and presenting.
    static let gap: TimeInterval = 0.5
    /// How often a pending walk re-checks.
    static let pollInterval: Duration = .milliseconds(500)

    /// A presentation was seen since the walk arrived, so the gap applies.
    private(set) var wasBlocked = false
    /// The first check that saw nothing presented after a block.
    private(set) var clearSince: Date?

    /// Whether to present now. A blocking presentation arms the gap; the
    /// first clear check after it starts the gap; a check at least `gap`
    /// later presents.
    mutating func check(_ inputs: Inputs, now: Date) -> Bool {
        guard inputs.isEnvironmentReady, !inputs.isOnboardingShowing else {
            clearSince = nil
            return false
        }
        guard !inputs.isSomethingPresented else {
            wasBlocked = true
            clearSince = nil
            return false
        }
        guard wasBlocked else { return true }
        guard let clearSince else {
            clearSince = now
            return false
        }
        guard now.timeIntervalSince(clearSince) >= Self.gap else { return false }
        self = SharedWalkPresentation()
        return true
    }
}
