import Foundation

/// A property value PostHog receives: only these three shapes, never a
/// coordinate, an address, a name, a caption or anything typed (#147 item 3).
nonisolated enum TelemetryValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    /// What the SDK's `[String: Any]` takes.
    var sdkValue: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .bool(let value): value
        }
    }
}

/// The app's only named events (16 after design DS3). The SDK adds its own
/// lifecycle events and default properties; nothing else leaves the app.
/// `bodega_id` (the public row UUID) appears on `bodega_opened` only: the
/// authorship events carry no id, so no vendor can tie an account to what
/// it added (eng E4).
nonisolated enum TelemetryEvent: Equatable, Sendable {
    nonisolated enum Tab: String, Sendable {
        case map
        case list
    }

    /// How the add sheet was reached (eng E6).
    nonisolated enum AddRoute: String, Sendable {
        /// Drop a Pin on Map, then the placement bar's confirm.
        case placement
        /// The toolbar's Use Current Location shortcut, which skips placement.
        case currentLocation = "current_location"
        /// Placement entered from onboarding's "Add a Bodega You Know".
        case onboarding

        /// The add sheet's single entry point (`presentAddBodegaSheet`) maps
        /// its caller to a route here.
        static func resolve(fromCurrentLocation: Bool, placementFromOnboarding: Bool) -> AddRoute {
            if fromCurrentLocation { return .currentLocation }
            return placementFromOnboarding ? .onboarding : .placement
        }

        /// Whether the placement in progress began from onboarding, for
        /// `BrowseView`. Cleared whenever placement ends (confirmed or
        /// cancelled) and when the sheet opens, so a later placement from
        /// Drop a Pin, the empty-state card or the Add tip reads "placement".
        nonisolated struct Tracker: Equatable, Sendable {
            private(set) var placementFromOnboarding = false

            /// Onboarding's "Add a Bodega You Know" is starting placement.
            mutating func onboardingStartsPlacement() { placementFromOnboarding = true }

            /// Drop a Pin (or the List tab's add): an ordinary placement.
            mutating func userStartsPlacement() { placementFromOnboarding = false }

            /// `isPlacingBodega` went false, by confirm or cancel.
            mutating func placementEnded() { placementFromOnboarding = false }

            /// The add sheet opens: its route, and the flag is spent.
            mutating func sheetPresented(fromCurrentLocation: Bool) -> AddRoute {
                defer { placementFromOnboarding = false }
                return AddRoute.resolve(
                    fromCurrentLocation: fromCurrentLocation,
                    placementFromOnboarding: placementFromOnboarding
                )
            }
        }
    }

    case onboardingCompleted(wantsToAdd: Bool)
    case tabSwitched(tab: Tab)
    case filterApplied(amenityCount: Int)
    case locateMeTapped
    case bodegaOpened(id: UUID, fromMap: Bool)
    case addStarted(route: AddRoute)
    case duplicateChosen
    case bodegaAdded(isFirst: Bool, amenityCount: Int)
    case photoAdded(hasCaption: Bool)
    case reviewAdded
    case flagSubmitted(kind: String)
    case walkStarted
    case walkStopped
    case signedIn
    case signedOut
    case accountDeleted

    var name: String {
        switch self {
        case .onboardingCompleted: "onboarding_completed"
        case .tabSwitched: "browse_tab_switched"
        case .filterApplied: "filter_applied"
        case .locateMeTapped: "locate_me_tapped"
        case .bodegaOpened: "bodega_opened"
        case .addStarted: "add_started"
        case .duplicateChosen: "add_duplicate_chosen"
        case .bodegaAdded: "bodega_added"
        case .photoAdded: "photo_added"
        case .reviewAdded: "review_added"
        case .flagSubmitted: "flag_submitted"
        case .walkStarted: "walk_started"
        case .walkStopped: "walk_stopped"
        case .signedIn: "signed_in"
        case .signedOut: "signed_out"
        case .accountDeleted: "account_deleted"
        }
    }

    var properties: [String: TelemetryValue] {
        switch self {
        case .onboardingCompleted(let wantsToAdd):
            ["wants_to_add": .bool(wantsToAdd)]
        case .tabSwitched(let tab):
            ["tab": .string(tab.rawValue)]
        case .filterApplied(let amenityCount):
            ["amenity_count": .int(amenityCount)]
        case .bodegaOpened(let id, let fromMap):
            ["bodega_id": .string(id.uuidString.lowercased()), "from_map": .bool(fromMap)]
        case .addStarted(let route):
            ["route": .string(route.rawValue)]
        case .bodegaAdded(let isFirst, let amenityCount):
            ["is_first_add": .bool(isFirst), "amenity_count": .int(amenityCount)]
        case .photoAdded(let hasCaption):
            ["has_caption": .bool(hasCaption)]
        case .flagSubmitted(let kind):
            ["kind": .string(kind)]
        case .locateMeTapped, .duplicateChosen, .reviewAdded, .walkStarted, .walkStopped,
             .signedIn, .signedOut, .accountDeleted:
            [:]
        }
    }
}
