import CoreLocation
import SwiftUI
import TipKit

// Distances (#68): when `BrowseView` asks `UserLocationProvider` for a fresh
// fix, and the Distances tip's mirroring. Kept out of `BrowseView.swift` so
// that file stays within its length budget.

extension BrowseView {
    /// The refresh triggers, fed from `BrowseView`'s state.
    var userLocationRefresh: UserLocationRefresh {
        UserLocationRefresh(
            provider: userLocation,
            showsList: activeTab == .list,
            pathCount: path.count,
            authorizationStatus: locationPermissionClient.authorizationStatus
        )
    }
}

/// A fresh fix whenever the List tab is shown, the navigation path changes
/// (a detail pushed, or popped back to the list), authorization changes (a
/// Locate Me grant fills the list in; a revocation clears it), or the app
/// returns to the foreground with the list or a detail on screen, plus once
/// on first appearance if the list is already showing (eng D6, D9). Never
/// prompts: `UserLocationProvider.refresh()` reads a fix only when location
/// is already authorized. Not continuous tracking.
///
/// Also mirrors authorization into `TutorialTips.isLocationAuthorized` and
/// retires `DistancesTip` (`.actionPerformed`) the first time a coordinate
/// is published (design D4).
struct UserLocationRefresh: ViewModifier {
    let provider: UserLocationProvider
    let showsList: Bool
    let pathCount: Int
    let authorizationStatus: CLAuthorizationStatus

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: showsList) { _, showsList in
                if showsList { refresh() }
            }
            .onChange(of: pathCount) { refresh() }
            .onChange(of: authorizationStatus) { refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, showsList || pathCount > 0 { refresh() }
            }
            .task {
                if showsList { await provider.refresh() }
            }
            .onAppear { TutorialTips.isLocationAuthorized = provider.isAuthorized }
            .onChange(of: provider.isAuthorized) { _, isAuthorized in
                TutorialTips.isLocationAuthorized = isAuthorized
            }
            .onChange(of: provider.coordinate != nil, initial: true) { _, hasCoordinate in
                if hasCoordinate { DistancesTip().invalidate(reason: .actionPerformed) }
            }
    }

    private func refresh() {
        Task { await provider.refresh() }
    }
}
