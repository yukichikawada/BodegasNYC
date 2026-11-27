//
//  DataPointsUITests.swift
//  BodegasNYCUITests
//
//  The detail screen's data points in their grid form (#196), on the
//  `-UITestFixtures` seam: one fixture bodega served locally.
//

import XCTest

final class DataPointsUITests: XCTestCase {
    /// Must match `UITestFixtures.bodegaName` in the app target.
    private static let fixtureBodegaName = "Fixture Deli"
    /// `BodegaFilter.Amenity` order; the grid's first row is the first four.
    private static let captions = ["Cat", "Hot Food", "Nicotine", "Beer", "Lotto", "ATM", "Bathroom"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// protects: on the pinned 402 pt iPhone 17 Pro at xLarge, where one row of seven does not fit, the data
    /// points show as the grid (#196 DS1, DS2, AC 6): Cat, Hot Food, Nicotine and Beer on one line, Lotto, ATM
    /// and Bathroom on the line below, each second-row cell centred under the first-row cell of its column
    /// (DS3); every caption is one accessibility element whose value is Yes or No from the fixture's
    /// `-UITestDataPoints mixed` set (first row present, second absent; DS9).
    /// fails_when: the row is squeezed in instead of falling through, the stacked rows win where the grid fits,
    /// the rows split elsewhere, the second row is centred as a group, or a caption loses its Yes/No value.
    /// no_claim: the other widths and sizes (captures in `build/qa-196/`), the 4 pt and 12 pt spacing, the
    /// strikethrough's look, VoiceOver's spoken order (a tree check, not a walk).
    @MainActor
    func testDetailDataPointsUseTheGridWhenTheRowDoesNotFit() throws {
        // A device another test left in landscape would fail this one.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestFixtures",
            "-UITestDataPoints", "mixed",
            // NSArgumentDomain overrides UserDefaults: skip onboarding and the intro.
            "-firstRun.hasCompletedOnboarding", "YES",
            "-firstRun.hasSeenStreetsWalkedIntro", "YES",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXL"
        ]
        app.launch()

        let pin = app.buttons[Self.fixtureBodegaName].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 20), "fixture pin never appeared on the map")
        pin.tap()
        XCTAssertTrue(app.navigationBars[Self.fixtureBodegaName].waitForExistence(timeout: 10), "detail never opened")

        let cells = Self.captions.map { app.staticTexts[$0].firstMatch }
        for (caption, cell) in zip(Self.captions, cells) {
            XCTAssertTrue(cell.waitForExistence(timeout: 5), "no \(caption) data point")
        }
        let frames = cells.map(\.frame)
        let firstRow = frames[0..<4]
        let secondRow = frames[4..<7]
        for frame in firstRow {
            XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 1, "the first row is not one line: \(frames)")
        }
        for frame in secondRow {
            XCTAssertEqual(frame.midY, frames[4].midY, accuracy: 1, "the second row is not one line: \(frames)")
        }
        XCTAssertGreaterThan(frames[4].minY, frames[0].maxY, "Lotto is not below the first row: \(frames)")
        for column in 0..<3 {
            XCTAssertEqual(
                frames[column + 4].midX, frames[column].midX, accuracy: 1,
                "\(Self.captions[column + 4]) is not centred under \(Self.captions[column]): \(frames)"
            )
        }
        for (index, cell) in cells.enumerated() {
            XCTAssertEqual(cell.value as? String, index < 4 ? "Yes" : "No", "\(Self.captions[index]) has the wrong value")
        }
    }

    /// protects: in landscape (874 pt on the pinned iPhone 17 Pro) the data points keep the one row of seven
    /// (#196 DS1, DS8 and AC 8's landscape capture, attached to the result as "data points landscape").
    /// fails_when: the grid or the stacked rows win at a width that holds the row, or a caption is missing.
    /// no_claim: portrait widths (the other test and `build/qa-196/`), the text size the device is set to
    /// (the pinned device's default, Large).
    @MainActor
    func testDetailDataPointsKeepTheRowInLandscape() throws {
        // A device another test left in landscape would fail this one.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestFixtures",
            "-UITestDataPoints", "mixed",
            "-firstRun.hasCompletedOnboarding", "YES",
            "-firstRun.hasSeenStreetsWalkedIntro", "YES"
        ]
        app.launch()
        let pin = app.buttons[Self.fixtureBodegaName].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 20), "fixture pin never appeared on the map")
        pin.tap()
        XCTAssertTrue(app.navigationBars[Self.fixtureBodegaName].waitForExistence(timeout: 10), "detail never opened")

        // Restored before any assertion can fail: a device left in landscape
        // fails other UI tests (#160).
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft

        let cells = Self.captions.map { app.staticTexts[$0].firstMatch }
        for (caption, cell) in zip(Self.captions, cells) {
            XCTAssertTrue(cell.waitForExistence(timeout: 5), "no \(caption) data point in landscape")
        }
        // Rotation settles after the elements exist (a KVC predicate cannot
        // read `frame`, so poll it).
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(10)
        while window.frame.width < 800, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertGreaterThan(window.frame.width, 800, "the device never turned to landscape: \(window.frame)")
        let frames = cells.map(\.frame)
        for frame in frames {
            XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 1, "the data points are not one row: \(frames)")
        }
        // In landscape the points sit below the fold: drag them up to about
        // a third of the way down the screen for the capture (a swipe
        // overshoots under the navigation bar).
        let lift = max(0, frames[0].minY - window.frame.height / 3)
        if lift > 0 {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            let end = start.withOffset(CGVector(dx: 0, dy: -lift))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "data points landscape"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
