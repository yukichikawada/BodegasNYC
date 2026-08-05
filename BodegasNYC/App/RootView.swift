import SwiftData
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

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .task { await load() }
        case .ready(let environment):
            BrowseView(
                bodegaService: environment.bodegaService,
                reviewService: environment.reviewService,
                photoService: environment.photoService,
                sessionStore: environment.sessionStore,
                locationPermissionClient: environment.locationPermissionClient,
                streetsWalkedViewModel: environment.streetsWalkedViewModel
            )
        case .failed(let message):
            VStack(spacing: 12) {
                Text("Couldn't connect")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        let streetsWalkedViewModel = Self.makeStreetsWalkedViewModel(locationPermissionClient: locationPermissionClient)
        do {
            let config = try SupabaseConfig(bundle: .main)
            let supabaseEnvironment = await SupabaseEnvironment(config: config)
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

    /// `nil` on a `ModelContainer` failure (rare — corrupt/unavailable
    /// local store) rather than propagating into `RootView`'s `.failed`
    /// state, which is otherwise reserved for the Supabase connection.
    private static func makeStreetsWalkedViewModel(
        locationPermissionClient: LocationPermissionClient
    ) -> StreetsWalkedViewModel? {
        guard let container = try? ModelContainer(for: WalkedPoint.self) else { return nil }
        let viewModel = StreetsWalkedViewModel(
            locationPermissionClient: locationPermissionClient,
            modelContainer: container
        )
        viewModel.resumeTrackingIfPreviouslyEnabled()
        return viewModel
    }
}

#Preview {
    RootView()
}
