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
            MapScreenView(
                bodegaService: environment.bodegaService,
                locationPermissionClient: environment.locationPermissionClient
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
        do {
            let config = try SupabaseConfig(bundle: .main)
            let supabaseEnvironment = await SupabaseEnvironment(config: config)
            let environment = AppEnvironment(
                supabaseEnvironment: supabaseEnvironment,
                locationPermissionClient: LocationPermissionClient()
            )
            state = .ready(environment)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

#Preview {
    RootView()
}
