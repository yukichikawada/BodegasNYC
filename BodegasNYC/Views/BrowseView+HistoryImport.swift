import SwiftUI

/// A walk history file opened from outside (#180 design D8) lands on the
/// map: once onboarding is gone and nothing is presented over the browse
/// stack (a sheet holding input keeps the file waiting until it closes),
/// the List tab switches to the Map tab and a pushed detail is popped, so
/// the map's Streets Walked item and its import sheet are in front. The map
/// window then claims the file (`MapScreenView+WalkHistoryImport.swift`).
struct HistoryFileLanding: ViewModifier {
    @Binding var activeTab: BrowseView.Tab
    @Binding var path: [Bodega]
    let isOnboardingShowing: Bool
    @Environment(SharedWalkInbox.self) private var inbox: SharedWalkInbox?
    @Environment(\.scenePhase) private var scenePhase

    init(activeTab: Binding<BrowseView.Tab>, path: Binding<[Bodega]>, onboarding: Bool) {
        _activeTab = activeTab
        _path = path
        isOnboardingShowing = onboarding
    }

    private struct Key: Hashable {
        let file: Int?
        let isOnboardingShowing: Bool
        let scenePhase: ScenePhase
    }

    func body(content: Content) -> some View {
        content.task(id: Key(
            file: inbox?.pendingHistoryFile?.id,
            isOnboardingShowing: isOnboardingShowing,
            scenePhase: scenePhase
        )) {
            await land()
        }
    }

    /// Re-checks every 0.5 s while the file waits and this window is not
    /// yet on the map.
    private func land() async {
        while inbox?.pendingHistoryFile != nil, activeTab != .map || !path.isEmpty, !Task.isCancelled {
            if scenePhase == .active, !isOnboardingShowing, !SharedWalkPresenter.isSomethingPresented() {
                path = []
                activeTab = .map
                return
            }
            guard (try? await Task.sleep(for: SharedWalkPresentation.pollInterval)) != nil else { return }
        }
    }
}
