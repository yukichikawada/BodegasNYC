import Foundation

/// Bag of app-wide dependencies, constructed once `SupabaseEnvironment`'s
/// async init resolves — see `RootView`. A plain struct, not a DI framework
/// or service locator: the minimal composition root needed to hand a
/// `BodegaService` and `LocationPermissionClient` down to the map screen.
/// MainActor-isolated by this project's default
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION`), same as the SwiftUI views that consume
/// it — unlike the `Networking/` layer, there's no reason to opt this out
/// to `nonisolated`.
struct AppEnvironment {
    let supabaseEnvironment: SupabaseEnvironment
    let bodegaService: BodegaService
    let locationPermissionClient: LocationPermissionClient

    init(supabaseEnvironment: SupabaseEnvironment, locationPermissionClient: LocationPermissionClient) {
        self.supabaseEnvironment = supabaseEnvironment
        bodegaService = BodegaService(postgrest: supabaseEnvironment.postgrest)
        self.locationPermissionClient = locationPermissionClient
    }
}
