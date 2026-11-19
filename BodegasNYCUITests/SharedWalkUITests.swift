//
//  SharedWalkUITests.swift
//  BodegasNYCUITests
//
//  Opening a walk link (#177 PR 2, AC 6, AC 7) through the app's DEBUG
//  `-UITestOpenURL` seam, which hands the URL to the same inbox
//  `.onOpenURL` feeds (XCUIApplication.open is unreliable for universal
//  links, eng review). Runs on `-UITestFixtures`: no network, so the map
//  shows its ground without tiles; these tests read the sheet's text and
//  VoiceOver values, not the drawing.
//

import XCTest

final class SharedWalkUITests: XCTestCase {
    /// Must match `SharedWalkLinkTests.uiTestLink`: the 53 fixture blocks,
    /// Nov 3 to 9, 2026, 3,380 m, 6 new, no estimate.
    static let validLink = "https://yukichikawada.github.io/BodegasNYC/walk/#1.e3_xCifbFik2BtNfrIHLGBMZ0YD-NkYFNuZpYk8T7"
        + "FhVmH5uYZ5jwcqozK_DlMJ3ioN5Y-3MJYzLlzHdrH_E5zjJ_IJgwV8rAA.w"
    /// The valid link cut short, as a clipped paste would leave it.
    static var truncatedLink: String { String(validLink.dropLast(12)) }
    static let newerLink = "https://yukichikawada.github.io/BodegasNYC/walk/#2.AAAAAAAA.w"
    static let expectedValue = "November 3 to November 9, 2026, 53 blocks, 6 new to them, 2.1 miles."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String], onboarded: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestFixtures",
            "-firstRun.hasCompletedOnboarding", onboarded ? "YES" : "NO",
            "-firstRun.hasSeenStreetsWalkedIntro", "YES"
        ] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func sharedWalkMap(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Map of a shared walk."].firstMatch
    }

    @MainActor
    private func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// protects: AC 6: launched with a valid link, the Shared Walk sheet presents with the link's dates as its
    /// subtitle ("Nov 3–9, 2026"), the sender's counts in the bar ("53 blocks", "6 new to them", "2.1 miles"),
    /// "This walk isn't saved." and the map's VoiceOver value; Done closes it.
    /// fails_when: the sheet never presents, any count or date differs from the link, or Done leaves it up.
    /// no_claim: the violet drawing and MapKit tiles (no network under -UITestFixtures; captures cover the
    /// colour), a real universal-link tap (the owner's AC 11 device check).
    @MainActor
    func testAValidLinkShowsTheSendersWalk() throws {
        let app = launch(["-UITestOpenURL", Self.validLink])
        let map = sharedWalkMap(app)
        XCTAssertTrue(map.waitForExistence(timeout: 30), "the Shared Walk sheet never presented")
        XCTAssertEqual(map.value as? String, Self.expectedValue)
        XCTAssertTrue(app.staticTexts["Shared Walk"].exists, "no Shared Walk title")
        XCTAssertTrue(app.staticTexts["Nov 3\u{2013}9, 2026"].exists, "no dates subtitle")
        XCTAssertTrue(app.staticTexts["53 blocks"].exists, "no block count")
        XCTAssertTrue(app.staticTexts["6 new to them"].exists, "no new count")
        XCTAssertTrue(app.staticTexts["2.1 miles"].exists, "no distance")
        XCTAssertTrue(app.staticTexts["This walk isn't saved. Open the link to see it again."].exists)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(map.waitForNonExistence(timeout: 5), "Done left the sheet up")
    }

    /// protects: AC 6 with onboarding pending: the link waits while onboarding shows and the sheet presents only
    /// after Skip ends it.
    /// fails_when: the sheet covers onboarding, or never presents after it.
    /// no_claim: the other onboarding exits (they share `finishOnboarding`).
    @MainActor
    func testALinkWaitsForOnboarding() throws {
        let app = launch(["-UITestOpenURL", Self.validLink], onboarded: false)
        let skip = app.buttons["Skip"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 30), "onboarding never showed")
        wait(3)
        XCTAssertFalse(sharedWalkMap(app).exists, "the Shared Walk sheet presented over onboarding")
        skip.tap()
        XCTAssertTrue(sharedWalkMap(app).waitForExistence(timeout: 15), "the sheet never presented after onboarding")
    }

    /// protects: eng E2 / amended AC 6: with Your Blocks open when the link lands (handed over 12 s after launch),
    /// the Shared Walk sheet does not present over it and does present once Your Blocks is closed.
    /// fails_when: the sheet presents while Your Blocks is up, dismisses it, or never presents after Done.
    /// no_claim: the exact 0.5 s gap (SharedWalkInboxTests), alerts and covers (same read-only check).
    @MainActor
    func testALinkWaitsForAnOpenSheet() throws {
        let app = launch(["-UITestWalkedBlocks", "-UITestOpenURL", Self.validLink, "-UITestOpenURLDelay", "12"])
        let launched = Date()
        let menu = app.buttons["Streets Walked"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "Streets Walked menu never appeared")
        menu.tap()
        let yourBlocks = app.buttons["Your Blocks"].firstMatch
        XCTAssertTrue(yourBlocks.waitForExistence(timeout: 5), "the menu has no Your Blocks")
        yourBlocks.tap()
        let row = app.descendants(matching: .any)["yourBlocks.row.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Your Blocks never opened")
        XCTAssertLessThan(Date().timeIntervalSince(launched), 12, "Your Blocks opened after the link landed")

        wait(max(0, 16 - Date().timeIntervalSince(launched)))
        XCTAssertFalse(sharedWalkMap(app).exists, "the Shared Walk sheet presented over Your Blocks")
        XCTAssertTrue(row.exists, "Your Blocks was dismissed by the link")

        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Done left Your Blocks up")
        XCTAssertTrue(sharedWalkMap(app).waitForExistence(timeout: 10), "the sheet never presented after Your Blocks")
        XCTAssertEqual(sharedWalkMap(app).value as? String, Self.expectedValue)
    }

    /// protects: AC 7 (design wording): a truncated link shows "This link couldn't be opened. Ask them to send it
    /// again." and no Update row; Done closes it.
    /// fails_when: a truncated link shows a walk, another line, or an Update row.
    /// no_claim: every damaged shape (SharedWalkLinkTests).
    @MainActor
    func testATruncatedLinkShowsTheDamagedLine() throws {
        let app = launch(["-UITestOpenURL", Self.truncatedLink])
        let message = app.staticTexts["sharedWalk.message"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 30), "the sheet never showed a line")
        XCTAssertEqual(message.label, "This link couldn't be opened. Ask them to send it again.")
        XCTAssertFalse(app.buttons["Update"].exists, "a damaged link offers Update")
        XCTAssertFalse(sharedWalkMap(app).exists, "a damaged link shows a map")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5), "Done left the sheet up")
    }

    /// protects: AC 7 (design wording): a version-2 link shows "This walk needs a newer version of the app.
    /// Update, then tap the link again." and an Update row.
    /// fails_when: the line differs, it reads as damaged, or there is no Update row.
    /// no_claim: that Update opens the App Store (out of process; the URL is unit-tested).
    @MainActor
    func testANewerLinkOffersUpdate() throws {
        let app = launch(["-UITestOpenURL", Self.newerLink])
        let message = app.staticTexts["sharedWalk.message"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 30), "the sheet never showed a line")
        XCTAssertEqual(message.label, "This walk needs a newer version of the app. Update, then tap the link again.")
        XCTAssertTrue(app.buttons["Update"].exists, "no Update row")
    }
}
