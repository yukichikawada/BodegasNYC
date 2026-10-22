//
//  BodegasNYCUITests.swift
//  BodegasNYCUITests
//
//  Created by Yukichi Kawada on 7/21/26.
//

import XCTest

/// Runs against the app's DEBUG `-UITestFixtures` seam (#101): one fixture
/// bodega served locally, no network or hosted database.
final class BodegasNYCUITests: XCTestCase {
    /// Must match `UITestFixtures.bodegaName` in the app target.
    private static let fixtureBodegaName = "Fixture Deli"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches past onboarding, onto the map, with the fixture bodega.
    @MainActor
    private func launchWithFixtures() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestFixtures",
            // NSArgumentDomain overrides UserDefaults: skip onboarding.
            "-firstRun.hasCompletedOnboarding", "YES"
        ]
        app.launch()
        return app
    }

    /// Tapping a bodega's pin pushes its detail (the Marker-to-Annotation
    /// and pin-to-detail paths, #23/#24).
    @MainActor
    func testTappingPinOpensBodegaDetail() throws {
        let app = launchWithFixtures()

        let pin = app.buttons[Self.fixtureBodegaName].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 20), "fixture pin never appeared on the map")
        pin.tap()

        let detailTitle = app.navigationBars[Self.fixtureBodegaName]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 10), "detail title never appeared after tapping the pin")
    }
}
