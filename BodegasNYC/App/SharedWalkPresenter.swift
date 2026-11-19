import SwiftUI
import UIKit

/// Presents the inbox's pending shared walk from `RootView` (#177 eng E2)
/// with `.sheet(item:)`, only when `SharedWalkPresentation` allows: the
/// environment ready, onboarding gone, and the key window's root view
/// controller presenting nothing (a read-only check, never UIKit
/// presentation), re-run every 0.5 s while a walk waits and on scene
/// activation. A newer link replaces the shown walk in place (the item
/// keeps its `id`). Closing the sheet discards the walk.
struct SharedWalkPresenter: ViewModifier {
    let inbox: SharedWalkInbox
    let isEnvironmentReady: Bool
    let isOnboardingShowing: Bool
    @State private var isShowing = false
    @State private var gate = SharedWalkPresentation()
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onOpenURL { inbox.receive($0) }
            .sheet(item: shown, onDismiss: inbox.close, content: SharedWalkSheet.init(item:))
            .environment(inbox)
            .task(id: waitKey) {
                await waitToPresent()
            }
    }

    /// What restarts the wait: a new walk, the sheet closing, the scene
    /// becoming active, the environment or onboarding changing (the task
    /// reads this struct's `let`s as they were when it started).
    private struct WaitKey: Hashable {
        let item: Int?
        let isShowing: Bool
        let scenePhase: ScenePhase
        let isEnvironmentReady: Bool
        let isOnboardingShowing: Bool
    }

    private var waitKey: WaitKey {
        WaitKey(
            item: inbox.pending?.id,
            isShowing: isShowing,
            scenePhase: scenePhase,
            isEnvironmentReady: isEnvironmentReady,
            isOnboardingShowing: isOnboardingShowing
        )
    }

    /// The inbox's walk while the sheet is up; setting `nil` (Done, a swipe)
    /// ends the showing, and `onDismiss` discards the walk.
    private var shown: Binding<SharedWalkInbox.Item?> {
        Binding(
            get: { isShowing ? inbox.pending : nil },
            set: { if $0 == nil { isShowing = false } }
        )
    }

    private func waitToPresent() async {
        gate = SharedWalkPresentation()
        while inbox.pending != nil, !isShowing, !Task.isCancelled {
            if scenePhase == .active, gate.check(inputs, now: Date()) {
                isShowing = true
                return
            }
            guard (try? await Task.sleep(for: SharedWalkPresentation.pollInterval)) != nil else { return }
        }
    }

    private var inputs: SharedWalkPresentation.Inputs {
        SharedWalkPresentation.Inputs(
            isEnvironmentReady: isEnvironmentReady,
            isOnboardingShowing: isOnboardingShowing,
            isSomethingPresented: Self.isSomethingPresented()
        )
    }

    /// The key window's root view controller is presenting a sheet, cover
    /// or alert. Read only.
    static func isSomethingPresented() -> Bool {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow) ?? windows.first
        return window?.rootViewController?.presentedViewController != nil
    }
}
