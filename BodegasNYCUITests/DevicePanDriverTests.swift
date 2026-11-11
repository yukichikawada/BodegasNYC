//
//  DevicePanDriverTests.swift
//  BodegasNYCUITests
//
//  The scripted pan driver for the walked-layer device A/B (#119, moved from
//  the #113 session's scratch driver in Phase 0). Opt-in: every test skips
//  unless the runner's environment has BODEGAS_DEVICE_PAN=1, which reaches
//  the tests as TEST_RUNNER_BODEGAS_DEVICE_PAN=1 on the xcodebuild command
//  line (#119 eng correction). It drives only gestures from the app's
//  launch camera, so the same driver runs unchanged against `main` and the
//  #119 build; the trace analysis is done by hand (#119 Phase 0 step 5).
//
//  testPans: the #113 script. Three pinch-ins over the launch camera (about
//  5.2 km of visible height on the iPhone 17 Pro Max in Phase 0), then
//  PAN_EXTRA_ZOOM more pinch-ins of 2x (default 0; by Phase 0's pinch
//  response, about 1.65x each on the map, 2 lands near 1.9 km at the edge of
//  the 5pt breadcrumb band and 3 near 1.2 km inside it), then pans of
//  10-30% of the screen with a pinch out or in every 12 pans, for
//  PAN_SECONDS (default 60; the trace records 30 s of it).
//  testCapHeights: #119 Phase 0 step 4. All of Manhattan in view first;
//  then back over the launch centre, lower Manhattan, where the 5,006-block
//  seed is, before zooming in, so the closer stages stay over walked
//  blocks (Phase 0's version zoomed in over upper Manhattan and drew
//  nothing below 16 km). Then about 6 km and about 2 km, five pans at each.
//  The heights come from pinch scales calibrated on Phase 0's device run (a
//  pinch of scale s zoomed about s^0.72 there); read the heights reached
//  from the app's log (WALKED_SETTLE heightM=) and retune with the knobs.
//
//  Environment (each also accepted with the TEST_RUNNER_ prefix, which is
//  how xcodebuild hands them over):
//    PAN_WAIT          seconds after launch before the first gesture (12)
//    PAN_SECONDS       testPans duration (60)
//    PAN_SCALE         testPans pan size multiplier (1.0)
//    PAN_PAUSE_MS      rest after each testPans pan (600)
//    PAN_EXTRA_ZOOM    testPans pinch-ins of 2x after the three setup ones (0;
//                      3 for the 5pt band)
//    CAP_PAUSE_MS      rest after each testCapHeights gesture (1500)
//    CAP_PINCHES_6KM   pinch scales from the launch height to ~6 km ("2,2,2.2")
//    CAP_PINCHES_2KM   pinch scales from ~6 km to ~2 km ("2,2,1.6")
//
//  The driver prints "PANS_BEGIN test=<name> stage=<stage> <unix time>"
//  right before each run of measured gestures (the app may have been
//  relaunched by XCUITest before it: attach the trace after this line), one
//  "GESTURE <kind> <unix time>" line per gesture and, last, "DRIVER
//  test=<name> settles=<n> pans=<n> pinches=<n>": settles is the gesture
//  count, every pan and pinch ending at rest.
//
//  protects: nothing in CI (skipped); on device it produces the same
//  gesture sequence for both builds of the A/B.
//  fails_when: the app never shows the map (no Streets Walked menu).
//  no_claim: any timing; the heights reached (read them from the app's log
//  or the attached screenshots).
//

import XCTest

final class DevicePanDriverTests: XCTestCase {
    private var settles = 0
    private var pans = 0
    private var pinches = 0

    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(Self.env("BODEGAS_DEVICE_PAN") == "1", "device pan driver: set BODEGAS_DEVICE_PAN=1")
    }

    /// The #113 driver's script, unchanged in its moves and timings, with
    /// an optional closer start.
    @MainActor
    func testPans() throws {
        let app = launch()
        attach(app, "start")
        for _ in 0 ..< 3 {
            pinch(app, scale: 2.0, "pinch-in-setup")
            usleep(800_000)
        }
        for _ in 0 ..< Int(Self.double("PAN_EXTRA_ZOOM", 0)) {
            pinch(app, scale: 2.0, "pinch-in-extra")
            usleep(800_000)
        }
        attach(app, "zoomed")
        let moves: [(Double, Double)] = [
            (0.20, 0), (-0.20, 0), (0, 0.15), (0, -0.15), (0.12, 0.10), (-0.12, -0.10),
            (0.30, 0), (-0.30, 0), (0, 0.25), (0, -0.25), (-0.15, 0.12), (0.15, -0.12),
            (0.10, 0), (-0.10, 0), (0.25, 0.20), (-0.25, -0.20)
        ]
        let scale = Self.double("PAN_SCALE", 1.0)
        let pause = UInt32(Self.double("PAN_PAUSE_MS", 600) * 1_000)
        begin(app, test: "testPans", stage: "pans")
        let deadline = Date().addingTimeInterval(Self.double("PAN_SECONDS", 60))
        var step = 0
        var zoomedOut = false
        while Date() < deadline {
            if step > 0 && step % 12 == 0 {
                pinch(app, scale: zoomedOut ? 2.0 : 0.5, zoomedOut ? "pinch-in" : "pinch-out")
                zoomedOut.toggle()
                usleep(700_000)
            }
            let (dx, dy) = moves[step % moves.count]
            pan(app, dx: dx * scale, dy: dy * scale)
            usleep(pause)
            step += 1
            if step % 30 == 0 { attach(app, "pan-\(step)") }
        }
        attach(app, "end-\(step)")
        report("testPans")
    }

    /// Phase 0 step 4: five settles at each of three camera heights.
    @MainActor
    func testCapHeights() throws {
        let app = launch()
        attach(app, "start")
        let pause = UInt32(Self.double("CAP_PAUSE_MS", 1_500) * 1_000)
        // Small pans whose sum is zero, so each stage ends where it began.
        let moves: [(Double, Double)] = [(0.12, 0), (-0.06, 0.08), (-0.06, -0.08), (0, 0.10), (0, -0.10)]
        // The launch camera is centred on lower Manhattan (40.71, -74.01),
        // about 29 km tall: move it north-east so all of Manhattan is in
        // view (the content moves down and left), and back afterwards.
        pan(app, dx: -0.20, dy: 0.23, kind: "pan-to-manhattan")
        usleep(pause)
        runStage(app, "manhattan", pinches: [], moves: moves, pause: pause)
        pan(app, dx: 0.20, dy: -0.23, kind: "pan-back-to-launch-centre")
        usleep(pause)
        runStage(app, "6km", pinches: Self.scales("CAP_PINCHES_6KM", [2, 2, 2.2]), moves: moves, pause: pause)
        runStage(app, "2km", pinches: Self.scales("CAP_PINCHES_2KM", [2, 2, 1.6]), moves: moves, pause: pause)
        report("testCapHeights")
    }

    @MainActor
    private func runStage(_ app: XCUIApplication, _ name: String, pinches: [Double], moves: [(Double, Double)], pause: UInt32) {
        for scale in pinches {
            pinch(app, scale: scale, "pinch-\(name)")
            usleep(pause)
        }
        attach(app, "height-\(name)")
        begin(app, test: "testCapHeights", stage: name)
        for (index, move) in moves.enumerated() {
            pan(app, dx: move.0, dy: move.1, kind: "pan-\(name)-\(index + 1)")
            usleep(pause)
        }
        attach(app, "height-\(name)-end")
    }

    /// The line to start reading a trace from: printed right before the
    /// measured gestures, with the app's state, so a relaunch by XCUITest
    /// earlier in the test cannot be mistaken for the measured process.
    @MainActor
    private func begin(_ app: XCUIApplication, test: String, stage: String) {
        print(String(
            format: "PANS_BEGIN test=%@ stage=%@ appState=%ld %.3f",
            test, stage, app.state.rawValue, Date().timeIntervalSince1970
        ))
    }

    // MARK: Gestures

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // The A/B installs test builds beside the App Store app under another
        // bundle id, so the container is fresh apart from the copied store:
        // skip onboarding and the intro, keep the layer on, recording and
        // telemetry off.
        app.launchArguments += [
            "-firstRun.hasCompletedOnboarding", "YES",
            "-firstRun.hasSeenStreetsWalkedIntro", "YES",
            "-streetsWalked.isOverlayVisible", "YES",
            "-streetsWalked.isTrackingEnabled", "NO",
            "-telemetry.isEnabled", "NO"
        ]
        addUIInterruptionMonitor(withDescription: "location") { alert in
            for label in ["Allow While Using App", "Allow Once", "Don't Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        let menu = app.buttons["Streets Walked"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "the map never showed the Streets Walked menu")
        sleep(UInt32(Self.double("PAN_WAIT", 12)))
        return app
    }

    @MainActor
    private func pan(_ app: XCUIApplication, dx: Double, dy: Double, kind: String = "pan") {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5 - dx / 2, dy: 0.5 - dy / 2))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + dx / 2, dy: 0.5 + dy / 2))
        // The hold at the end stops the map without momentum.
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: 900, thenHoldForDuration: 0.05)
        pans += 1
        settles += 1
        log(kind)
    }

    @MainActor
    private func pinch(_ app: XCUIApplication, scale: Double, _ kind: String) {
        app.pinch(withScale: scale, velocity: scale >= 1 ? 2.0 : -2.0)
        pinches += 1
        settles += 1
        log(kind)
    }

    private func log(_ kind: String) {
        print(String(format: "GESTURE %@ %.3f", kind, Date().timeIntervalSince1970))
    }

    private func report(_ test: String) {
        let line = "DRIVER test=\(test) settles=\(settles) pans=\(pans) pinches=\(pinches)"
        print(line)
        XCTContext.runActivity(named: line) { _ in }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: Environment

    private static func env(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        return environment[name] ?? environment["TEST_RUNNER_" + name]
    }

    private static func double(_ name: String, _ fallback: Double) -> Double {
        env(name).flatMap(Double.init) ?? fallback
    }

    private static func scales(_ name: String, _ fallback: [Double]) -> [Double] {
        guard let value = env(name) else { return fallback }
        return value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
}
