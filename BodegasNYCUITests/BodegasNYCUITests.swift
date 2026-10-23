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
    private func launchWithFixtures(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestFixtures",
            // NSArgumentDomain overrides UserDefaults: skip onboarding.
            "-firstRun.hasCompletedOnboarding", "YES"
        ] + extraArguments
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

        // QA P2: the page fills the screen whether or not the controls show,
        // so the photo is centred and does not move when they toggle.
        let page = app.images["Photo 2 of 3"]
        XCTAssertTrue(page.waitForExistence(timeout: 10), "viewer page image never loaded")
        let screen = app.windows.firstMatch.frame
        XCTAssertEqual(page.frame, screen, "page does not fill the screen with the controls shown")
        page.tap()
        XCTAssertTrue(counter.waitForNonExistence(timeout: 5), "single tap did not hide the controls")
        XCTAssertEqual(settledFrame(of: page), screen, "page moved when the controls hid")
        page.tap()
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "single tap did not show the controls again")
        XCTAssertEqual(settledFrame(of: page), screen, "page moved when the controls came back")

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

    /// protects: a viewer page whose image fails shows the voice body and a Retry that reloads that page
    /// (#107 design D17, DT3).
    /// fails_when: the failure shows no body or no Retry, or Retry does not request the image again and show it.
    /// no_claim: the failure state's look or a real network failure; the fixture answers 404 to the first two
    /// requests for photo 3 (gallery thumbnail, then the viewer page) and serves the third.
    @MainActor
    func testPhotoViewerRetriesAFailedPhoto() throws {
        let app = launchWithFixtures(["-UITestPhotoFailures", "2"])

        let pin = app.buttons[Self.fixtureBodegaName].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 20), "fixture pin never appeared on the map")
        pin.tap()

        let thirdThumbnail = app.buttons["Photo 3 of 3"]
        XCTAssertTrue(thirdThumbnail.waitForExistence(timeout: 10), "gallery thumbnails never appeared")
        thirdThumbnail.tap()

        let failureBody = app.staticTexts["That one didn't load."]
        XCTAssertTrue(failureBody.waitForExistence(timeout: 10), "failed photo shows no failure body")
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.exists, "failed photo shows no Retry")
        XCTAssertFalse(app.images["Photo 3 of 3"].exists, "failed photo shows an image")

        retry.tap()
        XCTAssertTrue(app.images["Photo 3 of 3"].waitForExistence(timeout: 10), "Retry did not reload the photo")
        XCTAssertFalse(failureBody.exists, "failure body stayed after a successful retry")
    }

    /// The element's frame once it has stopped changing (the controls fade
    /// over 0.2s), polled every 0.25s for up to 2s.
    @MainActor
    private func settledFrame(of element: XCUIElement) -> CGRect {
        var last = element.frame
        for _ in 0..<8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let current = element.frame
            print("settledFrame poll: \(current)")
            if current == last { return current }
            last = current
        }
        return last
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
