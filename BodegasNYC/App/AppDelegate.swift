import CoreLocation
import SwiftData
import UIKit

/// Owns Streets Walked's process-lifetime pieces (#123): the store, the one
/// `WalkRecorder`, and the one `StreetsWalkedViewModel`. Recording resumes
/// in `didFinishLaunching`, which also runs on a background relaunch with
/// no UI scene, so the location sessions are re-taken before it returns.
///
/// The view model is built lazily on the first UI request (`RootView`), never
/// at a background launch, and shared by every window (eng R5). A `nil`
/// store leaves both `nil`: a corrupt local store must not take down the
/// bodega-finding core.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private(set) var streetsWalkedContainer: ModelContainer?
    private(set) var walkRecorder: WalkRecorder?
    /// Read for its authorization status only (eng C2); never started.
    private let statusManager = CLLocationManager()
    private var streetsWalkedViewModel: StreetsWalkedViewModel?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        setUpStreetsWalked(
            container: Self.makeStreetsWalkedContainer(),
            isBackgroundLaunch: application.applicationState == .background
        )
        return true
    }

    /// Builds the recorder over `container` and resumes it, synchronously.
    /// Split out of `didFinishLaunching` so a test can run it over an
    /// in-memory store and a scripted backend.
    func setUpStreetsWalked(
        container: ModelContainer?,
        backend: any WalkLocationBackend = LiveWalkLocationBackend(),
        userDefaults: UserDefaults = .standard,
        isBackgroundLaunch: Bool
    ) {
        // Walked blocks and the match state (#108) live beside the raw fixes,
        // so one `save()` can move masks and `isMatched` flips together.
        guard let container else { return }
        streetsWalkedContainer = container
        let statusManager = statusManager
        let recorder = WalkRecorder(
            modelContainer: container,
            userDefaults: userDefaults,
            authorizationStatus: { statusManager.authorizationStatus },
            backend: backend
        )
        walkRecorder = recorder
        recorder.resumeIfPreviouslyEnabled(isBackgroundLaunch: isBackgroundLaunch)
    }

    /// The shared view model, built on the first call. `RootView`'s Retry
    /// gets the same instance back, so it never builds a second matcher.
    func streetsWalkedViewModel(locationPermissionClient: LocationPermissionClient) -> StreetsWalkedViewModel? {
        if let streetsWalkedViewModel { return streetsWalkedViewModel }
        guard let streetsWalkedContainer, let walkRecorder else { return nil }
        let viewModel = StreetsWalkedViewModel(
            locationPermissionClient: locationPermissionClient,
            modelContainer: streetsWalkedContainer,
            recorder: walkRecorder
        )
        streetsWalkedViewModel = viewModel
        return viewModel
    }

    /// The on-disk store, except in a DEBUG build launched with
    /// `-UITestFixtures -UITestWalkedBlocks`, where it is an in-memory store
    /// holding the fixture walk (#108 PR 2).
    private static func makeStreetsWalkedContainer() -> ModelContainer? {
        #if DEBUG
        if UITestFixtures.seedsWalkedBlocks {
            return UITestFixtures.makeWalkedBlocksContainer()
        }
        #endif
        return try? ModelContainer(for: Schema(StreetsWalkedSchema.models))
    }
}
