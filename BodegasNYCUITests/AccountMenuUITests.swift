//
//  AccountMenuUITests.swift
//  BodegasNYCUITests
//
//  The Account menu's version row (#191), on the `-UITestFixtures` seam:
//  no network and no session, so the menu is the signed-out one.
//

import XCTest

final class AccountMenuUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// protects: signed out, the Account menu shows the installed version under Privacy Policy, VoiceOver hears
    /// "Version <version>, build <build>" with this build's values (#191 AC 1, AC 2, AC 4).
    /// fails_when: the row is missing, sits above Privacy Policy, reads the parenthesised form to VoiceOver, or
    /// carries a version or build other than the bundle's.
    /// no_claim: the row's look and that it does nothing on tap (live QA captures), accessibility text sizes
    /// (capture). The expected values come from this test bundle's Info.plist, which the project builds from the
    /// same MARKETING_VERSION and CURRENT_PROJECT_VERSION as the app target; a bump to one target alone fails here.
    @MainActor
    func testVersionRowIsInTheSignedOutAccountMenu() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestFixtures",
            "-firstRun.hasCompletedOnboarding", "YES",
            "-firstRun.hasSeenStreetsWalkedIntro", "YES"
        ]
        app.launch()

        let account = app.buttons["Account"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 20), "the Account menu never appeared")
        account.tap()
        XCTAssertTrue(app.buttons["Sign In"].firstMatch.waitForExistence(timeout: 5), "the menu is not signed out")

        let row = app.descendants(matching: .any)["account.version"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the Account menu has no version row")

        let info = Bundle(for: Self.self).infoDictionary
        let version = try XCTUnwrap(info?["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info?["CFBundleVersion"] as? String)
        XCTAssertEqual(row.label, "Version \(version), build \(build)")

        let privacy = app.descendants(matching: .any)["Privacy Policy"].firstMatch
        XCTAssertTrue(privacy.exists, "the menu has no Privacy Policy")
        XCTAssertLessThan(privacy.frame.minY, row.frame.minY, "the version row is not under Privacy Policy")
        XCTAssertFalse(row.isEnabled, "the version row can be tapped")
    }
}
