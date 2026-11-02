//
//  TelemetryEventTests.swift
//  BodegasNYCTests
//
//  The event contract (#147 item 3 table, eng E4/E6, design DS3): every
//  case's name and exact property keys, the allowed value types, and the
//  keys no event may ever carry.
//

import Foundation
import Testing

@testable import BodegasNYC

struct TelemetryEventTests {
    private static let bodegaID = UUID(uuidString: "8f14e45f-ceea-467e-adc9-15476f4eaa15")!

    /// One fixture per case, with its expected name and keys. `expected(for:)`
    /// switches exhaustively, so a new case does not compile until it has a
    /// row here.
    private static let fixtures: [TelemetryEvent] = [
        .onboardingCompleted(wantsToAdd: true),
        .tabSwitched(tab: .list),
        .filterApplied(amenityCount: 3),
        .locateMeTapped,
        .bodegaOpened(id: bodegaID, fromMap: true),
        .addStarted(route: .currentLocation),
        .duplicateChosen,
        .bodegaAdded(isFirst: true, amenityCount: 2),
        .photoAdded(hasCaption: false),
        .reviewAdded,
        .flagSubmitted(kind: "Wrong details"),
        .walkStarted,
        .walkStopped,
        .signedIn,
        .signedOut,
        .accountDeleted,
        .directionsOpened,
        .showOnMap(fromMap: false)
    ]

    private static func expected(for event: TelemetryEvent) -> (name: String, keys: Set<String>) {
        switch event {
        case .onboardingCompleted: ("onboarding_completed", ["wants_to_add"])
        case .tabSwitched: ("browse_tab_switched", ["tab"])
        case .filterApplied: ("filter_applied", ["amenity_count"])
        case .locateMeTapped: ("locate_me_tapped", [])
        case .bodegaOpened: ("bodega_opened", ["bodega_id", "from_map"])
        case .addStarted: ("add_started", ["route"])
        case .duplicateChosen: ("add_duplicate_chosen", [])
        case .bodegaAdded: ("bodega_added", ["is_first_add", "amenity_count"])
        case .photoAdded: ("photo_added", ["has_caption"])
        case .reviewAdded: ("review_added", [])
        case .flagSubmitted: ("flag_submitted", ["kind"])
        case .walkStarted: ("walk_started", [])
        case .walkStopped: ("walk_stopped", [])
        case .signedIn: ("signed_in", [])
        case .signedOut: ("signed_out", [])
        case .accountDeleted: ("account_deleted", [])
        case .directionsOpened: ("directions_opened", [])
        case .showOnMap: ("show_on_map", ["from_map"])
        }
    }

    /// protects=the declared contract: 18 events (no `telemetry_disabled`,
    /// DS3; #150 R4 added `directions_opened` and `show_on_map`), each with
    /// its table name and exactly its table keys, and no `bodega_id` on the
    /// authorship events (E4); fails_when=a case is renamed, gains or loses a
    /// key, or a 19th event appears without a row;
    /// no_claim=what the SDK adds on its own (lifecycle events, default
    /// properties), which only the live dashboard shows.
    @Test func everyEventMatchesTheTable() {
        #expect(Self.fixtures.count == 18)
        #expect(Set(Self.fixtures.map(\.name)).count == 18)
        for event in Self.fixtures {
            let expected = Self.expected(for: event)
            #expect(event.name == expected.name)
            #expect(Set(event.properties.keys) == expected.keys, "\(event.name)")
        }
    }

    /// protects=names and keys are snake_case and no key is ever a
    /// coordinate, address, name, caption, free text or email; fails_when=a
    /// key such as `lat` or `caption` is added to any event; no_claim=the
    /// values' content (a `kind` string is the flag reason's raw value).
    @Test func noEventCarriesAForbiddenKey() {
        let forbidden: Set<String> = [
            "lat", "lon", "lng", "latitude", "longitude", "coordinate", "address",
            "name", "caption", "text", "body", "email", "details"
        ]
        let snakeCase = /^[a-z]+(_[a-z]+)*$/
        for event in Self.fixtures {
            #expect(event.name.wholeMatch(of: snakeCase) != nil, "\(event.name)")
            for key in event.properties.keys {
                #expect(!forbidden.contains(key), "\(event.name).\(key)")
                #expect(key.wholeMatch(of: snakeCase) != nil, "\(event.name).\(key)")
            }
        }
    }

    /// protects=property values reach the SDK as plain String, Int or Bool,
    /// with the fixture's value (`bodega_id` lowercased, the route's raw
    /// value); fails_when=a value is wrapped, stringified or mistyped;
    /// no_claim=PostHog's own serialization.
    @Test func valuesAreStringIntOrBool() {
        let opened = TelemetryEvent.bodegaOpened(id: Self.bodegaID, fromMap: false).properties
        #expect(opened["bodega_id"] == .string("8f14e45f-ceea-467e-adc9-15476f4eaa15"))
        #expect(opened["from_map"]?.sdkValue as? Bool == false)
        #expect(TelemetryEvent.showOnMap(fromMap: true).properties["from_map"]?.sdkValue as? Bool == true)
        #expect(TelemetryEvent.filterApplied(amenityCount: 6).properties["amenity_count"]?.sdkValue as? Int == 6)
        #expect(TelemetryEvent.addStarted(route: .currentLocation).properties["route"] == .string("current_location"))
    }

    /// protects=`add_started`'s route for the add sheet's three ways in
    /// (E6): the Use Current Location shortcut, placement, and placement
    /// begun from onboarding; fails_when=the shortcut reads as placement, or
    /// an onboarding placement reads as plain placement; no_claim=that
    /// `BrowseView` passes the right flags (live QA through the three routes).
    /// protects=a placement begun from onboarding and then cancelled does
    /// not leave a later placement (from the empty-state card or the Add
    /// tip, which never call Drop a Pin's path) reading "onboarding"; the
    /// onboarding route survives until its own sheet opens, and is spent
    /// there; fails_when=cancel-then-re-enter logs "onboarding", or the
    /// onboarding placement itself logs "placement"; no_claim=that
    /// `BrowseView` calls `placementEnded()` on every `isPlacingBodega`
    /// false (its `onChange`; live QA through the cancel path).
    @Test func addRouteTrackerForgetsOnboardingWhenPlacementEnds() {
        var tracker = TelemetryEvent.AddRoute.Tracker()
        tracker.onboardingStartsPlacement()
        tracker.placementEnded() // Cancel on the placement bar
        // Re-entered from the empty-state card: no tracker call.
        #expect(tracker.sheetPresented(fromCurrentLocation: false) == .placement)

        tracker.onboardingStartsPlacement()
        #expect(tracker.sheetPresented(fromCurrentLocation: false) == .onboarding)
        #expect(tracker.sheetPresented(fromCurrentLocation: false) == .placement)

        tracker.onboardingStartsPlacement()
        tracker.userStartsPlacement()
        #expect(tracker.sheetPresented(fromCurrentLocation: false) == .placement)
        tracker.onboardingStartsPlacement()
        #expect(tracker.sheetPresented(fromCurrentLocation: true) == .currentLocation)
    }

    @Test func addRouteMapping() {
        typealias Route = TelemetryEvent.AddRoute
        #expect(Route.resolve(fromCurrentLocation: true, placementFromOnboarding: false) == .currentLocation)
        #expect(Route.resolve(fromCurrentLocation: true, placementFromOnboarding: true) == .currentLocation)
        #expect(Route.resolve(fromCurrentLocation: false, placementFromOnboarding: false) == .placement)
        #expect(Route.resolve(fromCurrentLocation: false, placementFromOnboarding: true) == .onboarding)
        #expect([Route.placement, .currentLocation, .onboarding].map(\.rawValue)
            == ["placement", "current_location", "onboarding"])
    }
}
