//
//  WalkedLayerUITests.swift
//  BodegasNYCUITests
//
//  #119 on the simulator: the walked layer at close zoom over a dense
//  seeded patch never shows "Zoom in to see your blocks." (eng D10,
//  design DS3/DS10 in user terms).
//

import XCTest

final class WalkedLayerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// protects: with 600 walked blocks around Washington Square (seeded by
    /// `-UITestWalkedBlockCount`, matched in an in-memory store) and the map
    /// launched on a level 450 m camera over them (`-WalkedLaunchCamera`),
    /// the history is counted and the "Zoom in" card stays away through the
    /// settle that draws the layer, and through a pan.
    /// fails_when: the card appears at close zoom, or the seeded count
    /// never lands.
    /// no_claim: that the lines draw or how they look (the AC7 and DS4
    /// simulator captures), the cap's numbers (WalkedPieceCapTests), or the
    /// device cost.
    @MainActor
    func testCloseZoomOverADensePatchShowsNoZoomInCard() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestFixtures", "-UITestWalkedBlocks", "-UITestWalkedBlockCount", "600",
            "-WalkedLaunchCamera", "40.7308,-73.9973,450",
            "-firstRun.hasCompletedOnboarding", "YES",
            "-firstRun.hasSeenStreetsWalkedIntro", "YES",
            "-streetsWalked.isOverlayVisible", "YES",
            "-streetsWalked.isTrackingEnabled", "NO"
        ]
        app.launch()
        let menu = app.buttons["Streets Walked"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "the map never showed the Streets Walked menu")

        // The count lands when the summary (and so the layer) is built.
        menu.tap()
        app.buttons["Your Blocks"].firstMatch.tap()
        let manhattan = app.descendants(matching: .any)["yourBlocks.row.1"]
        XCTAssertTrue(manhattan.waitForExistence(timeout: 10), "the sheet never showed a Manhattan row")
        // About 600 blocks: "Manhattan, 599 of 9,300 blocks, 6 percent."
        let counted = NSPredicate(format: "label MATCHES 'Manhattan, (5[5-9]|6[0-9])[0-9] of .*'")
        expectation(for: counted, evaluatedWith: manhattan)
        waitForExpectations(timeout: 60)
        app.buttons["Done"].tap()

        let card = app.staticTexts["Zoom in to see your blocks."]
        XCTAssertFalse(card.waitForExistence(timeout: 3), "the Zoom in card showed at 450 m")
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45)))
        XCTAssertFalse(card.waitForExistence(timeout: 3), "the Zoom in card showed after a pan at close zoom")
    }
}
