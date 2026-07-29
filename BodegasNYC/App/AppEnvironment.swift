import Foundation

/// Bag of app-wide dependencies, constructed once `SupabaseEnvironment`'s
/// async init resolves — see `RootView`. A plain struct, not a DI framework
/// or service locator: the minimal composition root needed to hand services
/// and `LocationPermissionClient` down to `BrowseView`. MainActor-isolated
/// by this project's default (`SWIFT_DEFAULT_ACTOR_ISOLATION`), same as the
/// SwiftUI views that consume it — unlike the `Networking/` layer, there's
/// no reason to opt this out to `nonisolated`.
struct AppEnvironment {
    let supabaseEnvironment: SupabaseEnvironment
    let bodegaService: BodegaService
    let reviewService: ReviewService
    let photoService: PhotoService
    let locationPermissionClient: LocationPermissionClient
    /// `nil` if the local SwiftData store failed to open — a rare,
    /// isolated failure in this personal, on-device-only feature that
    /// shouldn't take down the app's core (Supabase-backed) bodega-finding
    /// loop. See `RootView.load()`.
    let streetsWalkedViewModel: StreetsWalkedViewModel?

    init(
        supabaseEnvironment: SupabaseEnvironment,
        locationPermissionClient: LocationPermissionClient,
        streetsWalkedViewModel: StreetsWalkedViewModel?
    ) {
        self.supabaseEnvironment = supabaseEnvironment
        bodegaService = BodegaService(postgrest: supabaseEnvironment.postgrest)
        reviewService = ReviewService(postgrest: supabaseEnvironment.postgrest)
        photoService = PhotoService(postgrest: supabaseEnvironment.postgrest, storage: supabaseEnvironment.storage)
        self.locationPermissionClient = locationPermissionClient
        self.streetsWalkedViewModel = streetsWalkedViewModel
    }
}
