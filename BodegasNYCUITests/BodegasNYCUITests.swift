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

    /// protects: tapping a thumbnail opens the viewer on that photo, swipes page in gallery order with the
    /// counter right at the last photo, and both the close button and a swipe down close it (#107 AC 1, AC 3).
    /// fails_when: the viewer opens on another photo, a swipe does not page or pages past the end, the counter
    /// is wrong, or either close path leaves the viewer up.
    /// no_claim: zoom, gesture feel, the zoom transition's look, VoiceOver (live QA); fixture photos are 3
    /// generated greys served by `FixtureURLProtocol`.
    @MainActor
    func testThumbnailOpensPagingPhotoViewer() throws {
        let app = launchWithFixtures()

        let pin = app.buttons[Self.fixtureBodegaName].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 20), "fixture pin never appeared on the map")
        pin.tap()

        let secondThumbnail = app.buttons["Photo 2 of 3"]
        XCTAssertTrue(secondThumbnail.waitForExistence(timeout: 10), "gallery thumbnails never appeared")
        secondThumbnail.tap()

        let counter = app.staticTexts["photoViewer.counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10), "viewer never opened")
        XCTAssertEqual(counter.label, "2 of 3", "viewer did not open on the tapped photo")

        app.swipeLeft()
        XCTAssertTrue(waitForLabel(counter, "3 of 3"), "swipe left did not page forward")
        app.swipeLeft()
        XCTAssertTrue(waitForLabel(counter, "3 of 3"), "paged past the last photo")
        app.swipeRight()
        XCTAssertTrue(waitForLabel(counter, "2 of 3"), "swipe right did not page back")

        app.buttons["photoViewer.close"].tap()
        XCTAssertTrue(counter.waitForNonExistence(timeout: 5), "close button left the viewer up")

        app.buttons["Photo 1 of 3"].tap()
        XCTAssertTrue(counter.waitForExistence(timeout: 10), "viewer did not reopen")
        XCTAssertEqual(counter.label, "1 of 3", "viewer did not reopen on the first photo")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(counter.waitForNonExistence(timeout: 5), "swipe down left the viewer up")
        XCTAssertTrue(app.navigationBars[Self.fixtureBodegaName].exists, "did not return to the detail")
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
