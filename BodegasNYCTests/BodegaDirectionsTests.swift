//
//  BodegaDirectionsTests.swift
//  BodegasNYCTests
//
//  The detail's Apple Maps hand-off (#150): the map item, the walking
//  launch option, and what a failed hand-off does (design DS10, eng R4).
//  Maps is never launched: `openInMaps` is injected.
//

import MapKit
import Testing

@testable import BodegasNYC

@MainActor
struct BodegaDirectionsTests {
    /// protects=Maps is sent the pin's coordinate, titled with the bodega's
    /// name (spec D2: coordinates, not the address); fails_when=the item
    /// carries another point, no name, or the address string;
    /// no_claim=what Maps draws for it.
    @Test func mapItemIsThePinNamedForTheBodega() throws {
        let bodega = try makeTestBodega(
            name: "Fixture Deli", latitude: 40.7128, longitude: -74.006, address: "1 Main St"
        )
        let item = BodegaDirections.makeMapItem(for: bodega)
        #expect(item.name == "Fixture Deli")
        #expect(item.location.coordinate.latitude == 40.7128)
        #expect(item.location.coordinate.longitude == -74.006)
    }

    /// protects=Directions asks Maps for a walking route (spec D2);
    /// fails_when=the mode is missing or is driving or transit;
    /// no_claim=that Maps honours it.
    @Test func launchOptionsAreWalking() {
        #expect(
            BodegaDirections.launchOptions == [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
        )
    }

    /// protects=a false `openInMaps` shows "Maps didn't open.", announces it
    /// and records the failure with context `directions.open`, and the next
    /// tap clears the line; every tap captures `directions_opened` (R4,
    /// DS10); fails_when=a failure is silent, unrecorded or sticks after a
    /// tap that opened Maps; no_claim=the line's rendering or VoiceOver
    /// speech (live QA), or when iOS returns false.
    @Test func aFailedHandOffShowsTheLineUntilTheNextTap() throws {
        let bodega = try makeTestBodega(name: "Fixture Deli")
        let (telemetry, sink) = makeRecordingTelemetry()
        var opens = [false, true]
        var announcements: [String] = []
        var opened: [MKMapItem] = []
        let directions = BodegaDirections(
            telemetry: telemetry,
            openInMaps: { item in
                opened.append(item)
                return opens.removeFirst()
            },
            announce: { announcements.append($0) }
        )
        #expect(!directions.didNotOpen)

        directions.open(bodega)
        #expect(directions.didNotOpen)
        #expect(announcements == ["Maps didn't open."])
        #expect(sink.reports.map(\.context) == ["directions.open"])

        directions.open(bodega)
        #expect(!directions.didNotOpen)
        #expect(announcements.count == 1)
        #expect(sink.reports.count == 1)
        #expect(sink.events == [.directionsOpened, .directionsOpened])
        #expect(opened.map(\.name) == ["Fixture Deli", "Fixture Deli"])
    }
}
