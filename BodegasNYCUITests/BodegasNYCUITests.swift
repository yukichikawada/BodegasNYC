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
    /// Must match `FixtureURLProtocol.captionedPhotoCaption`.
    private static let fixtureCaption = "The cat runs the counter."
    /// Must match `FixtureURLProtocol.longPhotoCaption`.
    private static let fixtureLongCaption = "The menu board is handwritten, mostly trustworthy. "
        + "Chopped cheese, unadvertised, is available anyway. Hot sauce lives behind the register."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches past onboarding, onto the map, with the fixture bodega, and
    /// past the Streets Walked intro (#126) unless `seenStreetsWalkedIntro`
    /// is false.
    @MainActor
    private func launchWithFixtures(
        _ extraArguments: [String] = [],
        seenStreetsWalkedIntro: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestFixtures",
            // NSArgumentDomain overrides UserDefaults: skip onboarding.
            "-firstRun.hasCompletedOnboarding", "YES",
            "-firstRun.hasSeenStreetsWalkedIntro", seenStreetsWalkedIntro ? "YES" : "NO"
        ] + extraArguments
        app.launch()
        return app
    }

    /// protects: on a map that has never shown the Streets Walked intro, with recording off, the sheet presents on
    /// its own; Not Now closes it with no permission prompt; the menu's How Streets Walked Works reopens it; a
    /// swipe down closes it (#126 AC1, AC7, AC8).
    /// fails_when: the sheet never appears, Not Now or the swipe leaves it up, Not Now shows a system location
    /// alert, or the menu has no How Streets Walked Works row.
    /// no_claim: the 1.5 s timing, the gate's other inputs (unit tests), that it shows only once across launches
    /// (the argument domain overrides the persisted flag), Start Recording's prompts (live QA), the layout. The
    /// pinned device's on-disk walk store is assumed empty and recording off (`-streetsWalked.isTrackingEnabled NO`).
    @MainActor
    func testStreetsWalkedIntroPresentsClosesAndReopens() throws {
        let app = launchWithFixtures(["-streetsWalked.isTrackingEnabled", "NO"], seenStreetsWalkedIntro: false)

        let headline = app.staticTexts["The blocks you walk, drawn in."]
        XCTAssertTrue(headline.waitForExistence(timeout: 20), "the intro never presented")
        let notNow = app.buttons["Not Now"]
        XCTAssertTrue(notNow.exists, "the intro has no Not Now")
        XCTAssertTrue(app.buttons["Start Recording"].exists, "the intro has no Start Recording")
        notNow.tap()
        XCTAssertTrue(headline.waitForNonExistence(timeout: 5), "Not Now left the intro up")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Not Now raised an alert")

        let menu = app.buttons["Streets Walked"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "Streets Walked menu never appeared")
        menu.tap()
        let howItWorks = app.buttons["How Streets Walked Works"].firstMatch
        XCTAssertTrue(howItWorks.waitForExistence(timeout: 5), "the menu has no How Streets Walked Works")
        howItWorks.tap()
        XCTAssertTrue(headline.waitForExistence(timeout: 5), "the menu row did not reopen the intro")

        // A drag from the sheet's title bar to the bottom of the screen (a
        // plain swipeDown on the bar did not move the sheet, 2026-10-29).
        let bar = app.navigationBars["Streets Walked"]
        let top = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let bottom = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        top.press(forDuration: 0.1, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(headline.waitForNonExistence(timeout: 5), "swipe down left the intro up")
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

    // MARK: Wide layouts (#160)

    /// Must match `BrowseView.principalModeSwitchID` / `trailingModeSwitchID`.
    private static let principalSwitchID = "browseMode.principal"
    private static let trailingSwitchID = "browseMode.trailing"

    /// Waits until the switch is in `expected` (principal or trailing) and the other form is gone.
    @MainActor
    private func assertOnlySwitch(
        _ expected: String, in app: XCUIApplication, _ step: String, line: UInt = #line
    ) -> XCUIElement {
        let other = expected == Self.principalSwitchID ? Self.trailingSwitchID : Self.principalSwitchID
        let shown = app.descendants(matching: .any)[expected].firstMatch
        let hidden = app.descendants(matching: .any)[other].firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 10), "\(step): \(expected) never appeared", line: line)
        XCTAssertTrue(hidden.waitForNonExistence(timeout: 5), "\(step): \(other) is still there", line: line)
        return shown
    }

    /// protects: on the iPhone 17 Pro in landscape (874 pt) the Map/List switch leaves the principal slot for the
    /// trailing group as a one-tap toggle naming the other tab, in the order Locate Me, Streets Walked, List,
    /// Account, Add; it goes to the List and back in one tap each, keeps its slot on the List tab while Locate Me
    /// and Streets Walked drop; rotating with the Account menu open closes the menu without changing the tab; and
    /// portrait puts the switch back in the centre, with exactly one form present at every step (#160 AC 4 to 6,
    /// DS1 to DS3).
    /// fails_when: the principal form survives in landscape, the trailing toggle is missing, misnamed or out of
    /// order, a tap does not switch tabs, the List tab keeps the map-only items, both forms or neither exist, a
    /// rotation with the menu open switches tabs or leaves the menu up, or portrait keeps the trailing toggle.
    /// no_claim: the haze (screenshots, live QA), the toggle's colour and glass look, widths between 540 pt and
    /// 874 pt (unit tests), the Duo, VoiceOver's spoken order; the fixture launch stands in for the network.
    @MainActor
    func testLandscapeMovesTheModeSwitchToTheTrailingGroup() throws {
        let app = launchWithFixtures()
        // Restored before any assertion can throw: a device left in landscape
        // fails the Streets Walked intro and photo viewer tests.
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["Locate Me"].firstMatch.waitForExistence(timeout: 20), "the map never appeared")
        _ = assertOnlySwitch(Self.principalSwitchID, in: app, "portrait launch")

        XCUIDevice.shared.orientation = .landscapeLeft
        let toggle = assertOnlySwitch(Self.trailingSwitchID, in: app, "landscape")
        XCTAssertEqual(toggle.label, "List", "on the map the toggle does not name the List")

        let order = ["Locate Me", "Streets Walked", "List", "Account", "Add Bodega"]
        let buttons = order.map { label -> XCUIElement in
            label == "List" ? toggle : app.buttons[label].firstMatch
        }
        for (label, button) in zip(order, buttons) {
            XCTAssertTrue(button.exists, "landscape: \(label) is missing from the toolbar")
        }
        let xs = buttons.map(\.frame.minX)
        XCTAssertEqual(xs, xs.sorted(), "landscape trailing order is not \(order): x origins \(xs)")

        toggle.tap()
        // The list page's search field (the map's pin shares the row's name, so a row match proves nothing).
        let listSearch = app.searchFields.firstMatch
        XCTAssertTrue(listSearch.waitForExistence(timeout: 10), "the List toggle did not show the list")
        let backToggle = assertOnlySwitch(Self.trailingSwitchID, in: app, "List tab")
        XCTAssertEqual(backToggle.label, "Map", "on the List tab the toggle does not name the Map")
        XCTAssertTrue(app.buttons["Locate Me"].waitForNonExistence(timeout: 5), "Locate Me stayed on the List tab")
        XCTAssertFalse(app.buttons["Streets Walked"].exists, "Streets Walked stayed on the List tab")

        backToggle.tap()
        let locateMe = app.buttons["Locate Me"].firstMatch
        XCTAssertTrue(locateMe.waitForExistence(timeout: 10), "the Map toggle did not return")
        XCTAssertTrue(listSearch.waitForNonExistence(timeout: 5), "the list stayed up after the Map toggle")
        XCTAssertEqual(assertOnlySwitch(Self.trailingSwitchID, in: app, "back on the map").label, "List")

        // DS3: an open menu dismisses on the slot swap; the tab stays.
        app.buttons["Account"].firstMatch.tap()
        let menuRow = app.buttons["Show Intro Again"].firstMatch
        XCTAssertTrue(menuRow.waitForExistence(timeout: 5), "the Account menu did not open")
        XCUIDevice.shared.orientation = .portrait
        _ = assertOnlySwitch(Self.principalSwitchID, in: app, "portrait with the menu open")
        XCTAssertTrue(menuRow.waitForNonExistence(timeout: 5), "the Account menu stayed up through the rotation")
        XCTAssertTrue(app.buttons["Locate Me"].firstMatch.exists, "the rotation changed the tab")
        XCTAssertFalse(listSearch.exists, "the rotation showed the list")
    }

    /// protects: at the largest accessibility text size in landscape the toolbar still shows all six controls,
    /// the switch included, so none is dropped or folded into an overflow menu (#160 eng D3).
    /// fails_when: any of Filters, the trailing toggle, Locate Me, Streets Walked, Account or Add is missing.
    /// no_claim: that they do not overlap or truncate (screenshots), other text sizes, the Duo's unfolded panel
    /// (owner-side capture).
    @MainActor
    func testLandscapeAtAccessibilitySizeKeepsEveryToolbarControl() throws {
        let app = launchWithFixtures([
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["Locate Me"].firstMatch.waitForExistence(timeout: 20), "the map never appeared")

        XCUIDevice.shared.orientation = .landscapeLeft
        let toggle = assertOnlySwitch(Self.trailingSwitchID, in: app, "AX5 landscape")
        XCTAssertEqual(toggle.label, "List")
        for label in ["Filters", "Locate Me", "Streets Walked", "Account", "Add Bodega"] {
            XCTAssertTrue(app.buttons[label].firstMatch.exists, "AX5 landscape: \(label) is missing from the toolbar")
        }
    }

    /// protects: a detail opened from the List shows the map preview and a Directions button, and Show on Map
    /// lands on the Map tab with the detail gone and the bodega's pin on screen to tap (#150 AC 1, AC 3, R5);
    /// the landing is pitched, MapKit's pitch toggle levels it, and the pin still opens its detail (#156 AC 8).
    /// fails_when: the preview or Directions is missing, Show on Map leaves the detail up or the List tab
    /// showing, the pin is not hittable afterwards (clustered away, under the page, never drawn), the pitch
    /// toggle is missing after the landing or does not switch to 3D, or the levelled pin no longer opens.
    /// no_claim: Apple Maps opening (never launched here), the camera's centre, pitch and flight (unit tests and
    /// the PR's simulator log), the pin's selected look, the announcement, the pin-opened path's pop-then-fly;
    /// portrait only (a landscape landing is level by design DS8, so the toggle offers 3D there).
    @MainActor
    func testShowOnMapFromAListOpenedDetail() throws {
        let app = launchWithFixtures()

        let listTab = app.buttons["List"].firstMatch
        XCTAssertTrue(listTab.waitForExistence(timeout: 10), "the List tab control never appeared")
        listTab.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", Self.fixtureBodegaName)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "fixture row never appeared on the list")
        row.tap()

        XCTAssertTrue(app.navigationBars[Self.fixtureBodegaName].waitForExistence(timeout: 10), "detail never opened")
        // `BodegaDetailMapPreview.accessibilityID`.
        let preview = app.buttons["bodegaDetail.mapPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "the detail has no map preview")
        XCTAssertEqual(preview.label, "Map", "the preview's VoiceOver label is not Map")
        XCTAssertTrue(app.buttons["Directions"].exists, "the detail has no Directions button")
        let showOnMap = app.buttons["Show on Map"]
        XCTAssertTrue(showOnMap.exists, "the detail has no Show on Map button")
        showOnMap.tap()

        XCTAssertTrue(
            app.navigationBars[Self.fixtureBodegaName].waitForNonExistence(timeout: 5),
            "Show on Map left the detail up"
        )
        XCTAssertTrue(app.buttons["Locate Me"].waitForExistence(timeout: 5), "Show on Map did not land on the Map tab")
        let pin = app.buttons[Self.fixtureBodegaName].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 10), "the fixture pin is not on the map after Show on Map")
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: pin)
        wait(for: [hittable], timeout: 5)

        // #156: the landing is pitched, so MapKit's pitch toggle offers 2D (design DS7); tapping it levels the
        // map, the toggle then offers 3D, and the spotlit pin is still there to tap through to its detail.
        // The identifiers are MapKit's own (`ModeButton2D` / `ModeButton3D`, labels "2D mode" / "3D mode").
        let toTwoD = app.buttons["ModeButton2D"]
        XCTAssertTrue(toTwoD.waitForExistence(timeout: 5), "no pitch toggle offering 2D after the pitched landing")
        toTwoD.tap()
        XCTAssertTrue(app.buttons["ModeButton3D"].waitForExistence(timeout: 5), "the pitch toggle did not level the map")
        let levelHittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: pin)
        wait(for: [levelHittable], timeout: 5)
        pin.tap()
        XCTAssertTrue(
            app.navigationBars[Self.fixtureBodegaName].waitForExistence(timeout: 10),
            "the spotlit pin did not open its detail after levelling"
        )
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

        // PR 2: photo 3's caption runs past three lines, so the band offers
        // More; expanded, the whole caption shows in a scroll capped at half
        // the screen (design D2).
        let more = app.buttons["photoViewer.captionMore"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "a long caption shows no More")
        more.tap()
        XCTAssertTrue(more.waitForNonExistence(timeout: 5), "More stayed after expanding")
        let expandedScroll = app.scrollViews["photoViewer.captionScroll"]
        XCTAssertTrue(expandedScroll.waitForExistence(timeout: 5), "the caption did not expand")
        let expandedText = app.staticTexts.matching(identifier: "photoViewer.captionText").firstMatch
        XCTAssertEqual(expandedText.label, Self.fixtureLongCaption, "the expanded caption is not the whole caption")
        let expandedFrame = settledFrame(of: expandedScroll)
        XCTAssertTrue(screen.contains(expandedFrame), "the expanded caption runs off the screen")
        XCTAssertTrue(expandedFrame.contains(expandedText.frame), "the expanded caption is clipped")
        XCTAssertLessThanOrEqual(expandedFrame.height, screen.height * 0.5, "the expanded caption is over half the screen")

        app.swipeLeft()
        XCTAssertTrue(waitForLabel(counter, "3 of 3"), "paged past the last photo")
        app.swipeRight()
        XCTAssertTrue(waitForLabel(counter, "2 of 3"), "swipe right did not page back")

        app.buttons["photoViewer.close"].tap()
        XCTAssertTrue(counter.waitForNonExistence(timeout: 5), "close button left the viewer up")

        app.buttons["Photo 1 of 3"].tap()
        XCTAssertTrue(counter.waitForExistence(timeout: 10), "viewer did not reopen")
        XCTAssertEqual(counter.label, "1 of 3", "viewer did not reopen on the first photo")

        // PR 2: the first fixture photo is captioned; the band shows with the
        // controls and hides with them (design D2). It overlays the bottom of
        // the page, so the page still fills the screen either way (QA P2).
        let caption = app.staticTexts[Self.fixtureCaption]
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "caption band missing on the captioned photo")
        let captionedPage = app.images["Photo 1 of 3"]
        XCTAssertTrue(captionedPage.waitForExistence(timeout: 10), "captioned page image never loaded")
        XCTAssertEqual(settledFrame(of: captionedPage), screen, "the caption band resized the page")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(caption.waitForNonExistence(timeout: 5), "caption band stayed up with the controls hidden")
        XCTAssertEqual(settledFrame(of: captionedPage), screen, "page moved when the band hid")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "caption band did not come back with the controls")

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

    /// protects: Streets Walked → Your Blocks opens the sheet, and a walk seeded by `-UITestWalkedBlocks` (one
    /// real Manhattan block from the bundle, in an in-memory store) is counted, matched and shown as one VoiceOver
    /// element per row: "Manhattan, 1 of 9,300 blocks, less than 1 percent." and the city row likewise (#108
    /// PR 2, design D5, D7, D11).
    /// fails_when: the menu has no Your Blocks, the sheet never opens, the count never lands, the row is not a
    /// single element with that label, or Done leaves the sheet up.
    /// no_claim: the layout, colors, detents or the 0.5s counting line (screenshots, live QA); the bundle's
    /// totals (StreetGridTests); that the fixture walks one block (YourBlocksTests).
    @MainActor
    func testYourBlocksShowsTheSeededManhattanBlock() throws {
        let app = launchWithFixtures(["-UITestWalkedBlocks"])

        let menu = app.buttons["Streets Walked"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "Streets Walked menu never appeared")
        menu.tap()
        let yourBlocks = app.buttons["Your Blocks"].firstMatch
        XCTAssertTrue(yourBlocks.waitForExistence(timeout: 5), "the menu has no Your Blocks")
        yourBlocks.tap()

        let manhattan = app.descendants(matching: .any)["yourBlocks.row.1"]
        XCTAssertTrue(manhattan.waitForExistence(timeout: 10), "the sheet never showed a Manhattan row")
        XCTAssertTrue(
            waitForLabel(manhattan, "Manhattan, 1 of 9,300 blocks, less than 1 percent.", timeout: 20),
            "Manhattan row reads \"\(manhattan.label)\""
        )
        let city = app.descendants(matching: .any)["yourBlocks.row.0"]
        XCTAssertEqual(city.label, "New York City, 1 of 99,360 blocks, less than 1 percent.")

        app.buttons["Done"].tap()
        XCTAssertTrue(manhattan.waitForNonExistence(timeout: 5), "Done left the sheet up")
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

    /// protects: the Add Photos sheet end to end on fixtures (#107 eng O4, AC 5, AC 8): a row is removed by swipe,
    /// captions are typed, Upload sends the rest, the 2nd photo's injected failure shows "Didn't go through", a
    /// locked caption and "Retry 1", and the retry (whose Storage object already exists) finishes and closes the
    /// sheet, with both photos in the gallery.
    /// fails_when: a row can't be removed, the failure isn't shown, the retry count is wrong, the failed caption
    /// stays editable, the retry doesn't close the sheet, or the gallery doesn't gain the two photos.
    /// no_claim: the system PhotosPicker (out of process), real Storage/Postgres, the Stop and discard paths
    /// (unit tests, live QA), and anything visual.
    @MainActor
    func testAddPhotosSheetRemovesCaptionsFailsAndRetries() throws {
        let app = launchWithFixtures(["-UITestAddPhotos"])

        let pin = app.buttons[Self.fixtureBodegaName].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 20), "fixture pin never appeared on the map")
        pin.tap()

        let firstCaption = app.descendants(matching: .any)["addPhoto.caption.0"]
        XCTAssertTrue(firstCaption.waitForExistence(timeout: 15), "upload sheet never filled in its rows")
        let thirdCaption = app.descendants(matching: .any)["addPhoto.caption.2"]
        XCTAssertTrue(thirdCaption.waitForExistence(timeout: 10), "third row never filled in")
        // The visible placeholder is a wrapping overlay; the field's own
        // (clear) prompt keeps the placeholder for VoiceOver (QA round 1).
        XCTAssertEqual(firstCaption.placeholderValue, "What's in the shot?")

        app.cells.element(boundBy: 2).swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "swipe did not reveal Remove")
        remove.tap()
        XCTAssertTrue(thirdCaption.waitForNonExistence(timeout: 5), "third row was not removed")

        firstCaption.tap()
        firstCaption.typeText("Front door")
        let secondCaption = app.descendants(matching: .any)["addPhoto.caption.1"]
        secondCaption.tap()
        secondCaption.typeText("The counter")

        let upload = app.buttons["addPhoto.upload"]
        upload.tap()
        XCTAssertTrue(waitForLabel(upload, "Retry 1", timeout: 15), "partial failure did not offer Retry 1")
        XCTAssertTrue(app.staticTexts["Didn't go through"].exists, "failed row shows no failure")
        XCTAssertEqual(app.staticTexts["addPhoto.passFailed"].label, "1 went up. 1 didn't. Try again.")
        let lockedCaption = app.staticTexts["addPhoto.lockedCaption.1"]
        XCTAssertTrue(lockedCaption.exists, "failed row's caption is still editable")
        XCTAssertEqual(lockedCaption.label, "The counter")

        upload.tap()
        XCTAssertTrue(upload.waitForNonExistence(timeout: 15), "retry did not finish and close the sheet")
        XCTAssertTrue(app.buttons["Photo 1 of 5"].waitForExistence(timeout: 5), "gallery did not gain both photos")
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
