import SwiftUI

/// The app's composition root: constructs `AppEnvironment` (which requires
/// `SupabaseEnvironment`'s async init to resolve first) behind a loading
/// state, then hands it down to `MapScreenView`. The entire scope of this
/// app's dependency injection — no router, no service locator.
struct RootView: View {
    enum LoadState {
        case loading
        case ready(AppEnvironment)
        case failed(String)
    }

    @State private var state: LoadState = .loading
    /// Owned here, not on `AppEnvironment`: the environment is built in
    /// `load()`, which re-runs on Retry (rebuilding this would drop
    /// `pendingTutorialAdd`), and onboarding must be decided in the very
    /// first frame, before any environment exists (eng review R2/R4).
    /// Created once in `init`, never in `load()`.
    @State private var firstRunState: FirstRunState
    /// Seeded in `init` from `firstRunState.shouldShowOnboarding`, so a
    /// first launch renders onboarding in the first frame with no
    /// map-only frame before it (spec AC 8).
    @State private var showingOnboarding: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Streets Walked's owner (#123): `load()` asks it for the one shared
    /// view model rather than building a recorder or store of its own.
    private let appDelegate: AppDelegate

    /// Defaults to `FirstRunState.shared` so every scene (iPad window)
    /// shares one in-memory state; see `FirstRunState.shared`.
    init(appDelegate: AppDelegate, firstRunState: FirstRunState = .shared) {
        self.appDelegate = appDelegate
        _firstRunState = State(initialValue: firstRunState)
        _showingOnboarding = State(initialValue: firstRunState.shouldShowOnboarding)
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    /// The onboarding overlay sits above the whole load-state switch, so
    /// nothing in the browse chrome (its toolbar lives inside
    /// `BrowseView`'s `NavigationStack`) can draw over it. The stack below
    /// is hidden from VoiceOver while it is up (design DD15).
    var body: some View {
        ZStack {
            content
                .accessibilityHidden(showingOnboarding)
            if showingOnboarding {
                OnboardingView(isLoading: isLoading) { wantsToAdd in
                    finishOnboarding(wantsToAdd: wantsToAdd)
                }
                .zIndex(1)
                .transition(OnboardingView.transition(reduceMotion: reduceMotion))
            }
        }
    }

    /// Every onboarding exit, first run or replay. `BrowseView` reacts to
    /// `showingOnboarding` going false (Map tab, pending tutorial add); if
    /// it doesn't exist yet, it picks the pending add up when it appears.
    private func finishOnboarding(wantsToAdd: Bool) {
        firstRunState.completeOnboarding(wantsToAdd: wantsToAdd)
        withAnimation(OnboardingView.animation(reduceMotion: reduceMotion)) {
            showingOnboarding = false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(AppCopy.rootLoading.copy.text)
                    .font(.subheadline)
                    .foregroundStyle(Color.textMuted)
            }
            .task { await load() }
        case .ready(let environment):
            BrowseView(
                bodegaService: environment.bodegaService,
                reviewService: environment.reviewService,
                photoService: environment.photoService,
                flagService: environment.flagService,
                sessionStore: environment.sessionStore,
                locationPermissionClient: environment.locationPermissionClient,
                streetsWalkedViewModel: environment.streetsWalkedViewModel,
                firstRunState: firstRunState,
                showingOnboarding: $showingOnboarding
            )
        case .failed(let message):
            VStack(spacing: 12) {
                Text(AppCopy.rootLoadFailed.copy.text)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Button("Retry") {
                    state = .loading
                }
            }
            .padding()
        }
    }

    private func load() async {
        // Hoisted out of the `do` block below and built independently of
        // the Supabase-dependent path: these are entirely local
        // (CoreLocation/SwiftData), and a corrupt/unavailable local store
        // shouldn't take down the app's core Supabase-backed bodega-finding
        // loop over a personal, on-device-only side feature.
        let locationPermissionClient = LocationPermissionClient()
        // The same instance on every call, Retry included (#123).
        let streetsWalkedViewModel = appDelegate.streetsWalkedViewModel(
            locationPermissionClient: locationPermissionClient
        )
        do {
            let config = try SupabaseConfig(bundle: .main)
            let supabaseEnvironment = await SupabaseEnvironment(config: config, urlSession: Self.urlSession())
            let environment = AppEnvironment(
                supabaseEnvironment: supabaseEnvironment,
                locationPermissionClient: locationPermissionClient,
                streetsWalkedViewModel: streetsWalkedViewModel
            )
            state = .ready(environment)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// `.shared`, except in a DEBUG build launched with `-UITestFixtures`
    /// (#101), where the Supabase clients get a fixture bodega instead of
    /// the network.
    private static func urlSession() -> URLSession {
        #if DEBUG
        if UITestFixtures.isEnabled {
            return UITestFixtures.urlSession()
        }
        #endif
        return .shared
    }
}

#Preview {
    RootView(appDelegate: AppDelegate())
}
