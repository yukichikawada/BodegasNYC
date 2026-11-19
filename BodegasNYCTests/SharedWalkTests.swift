//
//  SharedWalkTests.swift
//  BodegasNYCTests
//
//  Share a Walk (#177 PR 1): `WalkedHistory.shareSummary` (eng E6, E7),
//  the share copy (design DS5, DS7), `walk_shared` and the picture
//  (`SharedWalkCard`, DS2, DS3) over stubbed snapshots. No views.
//

import CoreGraphics
import MapKit
import Testing
import UIKit

@testable import BodegasNYC

@Suite
@MainActor
struct SharedWalkTests {
    private typealias F = StreetFixtures

    private static let day1 = WalkedDayKey(value: 20261102)
    private static let day2 = WalkedDayKey(value: 20261103)
    private static let day3 = WalkedDayKey(value: 20261104)

    /// Blocks 100, 200, 201, 300 and 400 exist (`StreetFixtures.cornerGrid`).
    private static func build(
        _ masks: [WalkedDayKey: [UInt32: UInt16]],
        meters: [WalkedDayKey: Double] = [:],
        estimatedThroughDay: WalkedDayKey? = nil
    ) -> WalkedHistory {
        WalkedHistory.build(
            dayMasks: masks,
            dayMeters: meters,
            grid: F.cornerGrid(),
            estimatedThroughDay: estimatedThroughDay,
            version: 1
        )
    }

    // MARK: shareSummary (eng E6, E7)

    /// protects=a one-day share is that day's own summary: its walked ids,
    /// new count and distance (rounded to the metre), the day as both ends;
    /// fails_when=a single day reads other days' blocks, drops its new
    /// count or its metres; no_claim=how the day's summary is built
    /// (YourWalksTests).
    @Test func aSingleDayIsThatDaysSummary() throws {
        let history = Self.build(
            [Self.day1: [100: 0x3FF], Self.day2: [100: 0x3FF, 200: 0x3FF], Self.day3: [300: 0x3FF]],
            meters: [Self.day1: 400, Self.day2: 1_234.6, Self.day3: 90]
        )
        let summary = try #require(history.summary(for: Self.day2))
        let walk = history.shareSummary(from: Self.day2, to: Self.day2)
        #expect(walk.firstDay == Self.day2 && walk.lastDay == Self.day2)
        #expect(walk.blockIDs == summary.walkedIDs)
        #expect(walk.newCount == summary.newCount)
        #expect(walk.meters == Int(summary.meters.rounded()))
        #expect(walk.meters == 1_235)
        #expect(!walk.isEstimate)
    }

    /// protects=a three-day range: the union of the days' ids (a repeat
    /// counts once), the summed new counts, and metres summed over the
    /// walked days then rounded once; fails_when=a repeat counts twice, new
    /// counts are not summed, or each day is rounded before summing (three
    /// 100.4 m days must give 301, not 300); no_claim=the copy that shows it.
    @Test func aRangeUnitesIdsAndSumsCountsAndMetres() {
        let history = Self.build(
            [
                Self.day1: [100: 0x3FF, 200: 0x3FF],
                Self.day2: [100: 0x3FF, 300: 0x3FF],
                Self.day3: [400: 0x3FF]
            ],
            meters: [Self.day1: 100.4, Self.day2: 100.4, Self.day3: 100.4]
        )
        let walk = history.shareSummary(from: Self.day1, to: Self.day3)
        #expect(walk.blockIDs == [100, 200, 300, 400])
        #expect(walk.blockCount == 4)
        #expect(walk.newCount == 4)
        #expect(walk.meters == 301)
    }

    /// protects=E6: a day in range with distance but no walked block adds no
    /// metres (and no ids or new blocks); fails_when=the share reads "3
    /// blocks, 14 miles" because an unmatched day's distance is counted;
    /// no_claim=which days count as walked (YourWalksTests, eng E3).
    @Test func aDayWithNoBlockAddsNoMetres() {
        let history = Self.build(
            [Self.day1: [100: 0x3FF], Self.day2: [200: 0b111]],
            meters: [Self.day1: 500, Self.day2: 9_000, Self.day3: 4_000]
        )
        #expect(history.summary(for: Self.day2)?.isWalked == false)
        let walk = history.shareSummary(from: Self.day1, to: Self.day3)
        #expect(walk.meters == 500)
        #expect(walk.blockIDs == [100])
        #expect(walk.newCount == 1)
    }

    /// protects=E7: a range touching an estimated day carries the flag; one
    /// that starts after the last estimated day does not; fails_when=an
    /// estimated day reaches a friend as a definite walk, or a later range
    /// is flagged; no_claim=how `estimatedThroughDay` is found
    /// (WalkedDayKeyTests).
    @Test func anEstimatedDaySetsTheFlag() {
        let history = Self.build(
            [Self.day1: [100: 0x3FF], Self.day3: [300: 0x3FF]],
            estimatedThroughDay: Self.day1
        )
        #expect(history.shareSummary(from: Self.day1, to: Self.day3).isEstimate)
        #expect(history.shareSummary(from: Self.day1, to: Self.day1).isEstimate)
        #expect(!history.shareSummary(from: Self.day2, to: Self.day3).isEstimate)
    }

    /// protects=a range with no rows, and an inverted one, hold no blocks,
    /// no new blocks and no metres; fails_when=an empty range borrows a
    /// neighbouring day; no_claim=the form's disabled state (ShareWalkFormTests).
    @Test func anEmptyRangeHasNoBlocks() {
        let history = Self.build([Self.day1: [100: 0x3FF]], meters: [Self.day1: 300])
        let empty = history.shareSummary(from: WalkedDayKey(value: 20261110), to: WalkedDayKey(value: 20261112))
        #expect(empty.blockIDs.isEmpty && empty.newCount == 0 && empty.meters == 0)
        let inverted = history.shareSummary(from: Self.day3, to: Self.day1)
        #expect(inverted.blockIDs.isEmpty && inverted.meters == 0)
    }

    // MARK: Copy (DS5, DS7)

    private static func walk(
        _ first: Int,
        _ last: Int,
        blocks: Int = 38,
        new: Int = 6,
        meters: Int = 3_380,
        estimate: Bool = false
    ) -> SharedWalk {
        SharedWalk(
            firstDay: WalkedDayKey(value: first),
            lastDay: WalkedDayKey(value: last),
            blockIDs: Set((1 ... UInt32(max(blocks, 1))).prefix(blocks)),
            meters: meters,
            newCount: new,
            isEstimate: estimate
        )
    }

    /// protects=DS7's four date shapes as values with an unspaced en dash,
    /// and VoiceOver's spoken form ("November 3 to November 9, 2026");
    /// fails_when=a spaced or hyphen dash, a repeated month or year, a
    /// missing year at a year change, or abbreviations read aloud;
    /// no_claim=how VoiceOver pronounces the value.
    @Test func dateRangesInEveryShape() {
        let shapes: [(Int, Int, String, String)] = [
            (20261103, 20261103, "Nov 3, 2026", "November 3, 2026"),
            (20261103, 20261109, "Nov 3\u{2013}9, 2026", "November 3 to November 9, 2026"),
            (20261128, 20261202, "Nov 28\u{2013}Dec 2, 2026", "November 28 to December 2, 2026"),
            (20261230, 20270102, "Dec 30, 2026\u{2013}Jan 2, 2027", "December 30, 2026 to January 2, 2027")
        ]
        for (first, last, shown, spoken) in shapes {
            let range = AppCopy.sharedWalkDates(first: WalkedDayKey(value: first), last: WalkedDayKey(value: last))
            #expect(range == CopyString(kind: .value, text: shown))
            #expect(AppCopy.sharedWalkSpokenDates(first: WalkedDayKey(value: first), last: WalkedDayKey(value: last)) == spoken)
        }
    }

    /// protects=DS5's text item and link title, and the picture's second
    /// line and VoiceOver value: "new" left out at zero, miles spelled out,
    /// "estimate" at the end of the VoiceOver value when flagged;
    /// fails_when="0 new", "mi", a missing date, or a missing estimate;
    /// no_claim=what each share destination does with the text.
    @Test func shareTextAndPictureLines() {
        let week = Self.walk(20261103, 20261109)
        #expect(AppCopy.sharedWalkText(week) == CopyString(kind: .body, text: "38 blocks, 6 new, 2.1 miles. Nov 3\u{2013}9, 2026."))
        #expect(AppCopy.sharedWalkLinkTitle(week).text == "Walk, Nov 3\u{2013}9, 2026")
        #expect(AppCopy.sharedWalkPictureCounts(week) == "6 new \u{00B7} 2.1 miles")
        #expect(
            AppCopy.sharedWalkPictureValue(week).text
                == "November 3 to November 9, 2026, 38 blocks, 6 new, 2.1 miles."
        )

        let repeatDay = Self.walk(20261103, 20261103, blocks: 1, new: 0, meters: 1_609, estimate: true)
        #expect(AppCopy.sharedWalkText(repeatDay).text == "1 block, 1 mile. Nov 3, 2026.")
        #expect(AppCopy.sharedWalkPictureCounts(repeatDay) == "1 mile")
        #expect(AppCopy.sharedWalkPictureValue(repeatDay).text == "November 3, 2026, 1 block, 1 mile, estimate.")
    }

    // MARK: Telemetry

    /// protects=`walk_shared` is its table name with no properties, and the
    /// view model's `walkShared()` sends exactly that one event through
    /// `Telemetry`; fails_when=the event carries a count, date or
    /// destination, or the call sends nothing or something else;
    /// no_claim=that the share sheet calls it only on `completed` (the view's
    /// completion handler; live QA), and what the SDK adds.
    @Test func walkSharedHasNoProperties() throws {
        #expect(TelemetryEvent.walkShared.name == "walk_shared")
        #expect(TelemetryEvent.walkShared.properties.isEmpty)

        let defaults = try #require(UserDefaults(suiteName: "SharedWalkTests.\(UUID().uuidString)"))
        let sink = RecordingSink()
        let telemetry = Telemetry(sinks: [sink], userDefaults: defaults)
        let container = try makeInMemoryModelContainer()
        let viewModel = StreetsWalkedViewModel(
            locationPermissionClient: LocationPermissionClient(),
            modelContainer: container,
            recorder: WalkRecorder(
                modelContainer: container,
                userDefaults: defaults,
                access: { AuthorizationBox(.authorizedAlways).access },
                backend: FakeWalkBackend(),
                now: { Date() }
            ),
            userDefaults: defaults,
            motion: FakeMotionProvider(),
            telemetry: telemetry
        )
        viewModel.walkShared()
        #expect(sink.events == [.walkShared])
    }

    // MARK: The picture (DS2, DS3)

    /// Runs for blocks 100 and 300 of the corner grid.
    private static var runs: [WalkedRun] {
        WalkedOverlay.runs(walkedIDs: [100, 300], grid: F.cornerGrid())
    }

    private static func pixels(of png: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let image = try #require(UIImage(data: png)?.cgImage)
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, rgba)
    }

    /// The colour at pixel (x, y), y from the top, as 0-255 RGB.
    private static func color(_ pixels: (width: Int, height: Int, rgba: [UInt8]), _ x: Int, _ y: Int) -> [Int] {
        let offset = (y * pixels.width + x) * 4
        return (0 ..< 3).map { Int(pixels.rgba[offset + $0]) }
    }

    private static func near(_ actual: [Int], _ expected: [Int], tolerance: Int = 3) -> Bool {
        zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }
    }

    private static let ground = [0x24, 0x24, 0x26]
    private static let band = [0x1C, 0x1C, 0x1E]
    private static let trail = [0x5A, 0xE3, 0xFF]

    /// protects=the picture is a 1080 x 1350 PNG; the map ends and the
    /// opaque #1C1C1E band starts 108 pt from the bottom (108 pt plus the
    /// two-line estimate text, 149 pt on the simulator, with the
    /// estimate flag, the map giving up the height); the trail is drawn in
    /// #5AE3FF over the map along the walked block; the picture freezes the
    /// walk it was made for; fails_when=the size, scale or band height
    /// drifts, the estimate does not grow the band, or the trail is missing
    /// or another colour; no_claim=MapKit's real tiles, the text's glyphs
    /// and the attribution (the stubbed snapshot is a flat #242426 field
    /// with a straight projection; a live capture checks the look).
    @Test(arguments: [false, true])
    func pictureSizeBandAndTrail(isEstimate: Bool) async throws {
        let walk = Self.walk(20261103, 20261103, blocks: 2, new: 1, meters: 180, estimate: isEstimate)
        let result = await SharedWalkCard.make(walk: walk, runs: Self.runs, snapshotter: UITestFixtures.FlatWalkSnapshotter())
        guard case .picture(let picture) = result else {
            Issue.record("the stubbed snapshot made no picture")
            return
        }
        #expect(picture.walk == walk)
        let pixels = try Self.pixels(of: picture.png)
        #expect(pixels.width == 1_080 && pixels.height == 1_350)

        // 108 pt; with the estimate line, 108 pt plus that line's two 17 pt
        // lines (whole points, so the edge falls on a pixel row).
        let bandPoints = SharedWalkCard.bandHeight(isEstimate: isEstimate)
        print("SharedWalkCard band height, estimate \(isEstimate): \(bandPoints) pt")
        if isEstimate {
            let estimateLine = SharedWalkCard.textHeight(SharedWalkCard.estimateText, width: 328)
            #expect(estimateLine >= 2 * SharedWalkCard.bodyFont.lineHeight - 1, "the estimate line fits one line")
            #expect(bandPoints == 108 + estimateLine)
            #expect((145 ... 160).contains(bandPoints), "estimate band is \(bandPoints) pt")
        } else {
            #expect(bandPoints == 108)
        }
        let edge = Int((450 - bandPoints) * 3)
        // The right margin, inside the 16 pt inset: no text, no trail.
        let column = 1_075
        #expect(Self.near(Self.color(pixels, column, edge - 3), Self.ground), "map above the band")
        #expect(Self.near(Self.color(pixels, column, edge + 3), Self.band), "band starts at \(bandPoints) pt")
        #expect(Self.near(Self.color(pixels, column, 1_345), Self.band), "band to the bottom")

        // Block 100's midpoint, projected as the stub projects it.
        let region = WalkRunsMap.fittedRegion(Self.runs)
        let middle = F.coordinate(x: 50, y: 0)
        let point = UITestFixtures.FlatWalkSnapshotter.project(
            CLLocationCoordinate2D(latitude: middle.latitude, longitude: middle.longitude),
            region: region,
            size: SharedWalkCard.mapSize(isEstimate: isEstimate)
        )
        #expect(Self.near(Self.color(pixels, Int(point.x * 3), Int(point.y * 3)), Self.trail, tolerance: 6))
        #expect(SharedWalkCard.trailWidth(for: region) == 5, "a 300 m fit draws the 5 pt line")
    }

    /// A snapshotter that fails, or answers only after `delay` whatever the
    /// cancellation.
    private struct StubSnapshotter: WalkMapSnapshotting {
        struct Failure: Error {}
        var delay: Duration = .zero
        var fails = false

        func snapshot(region: MKCoordinateRegion, size: CGSize) async throws -> WalkMapSnapshot {
            if fails { throw Failure() }
            let start = ContinuousClock.now
            while ContinuousClock.now - start < delay {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(20))
            }
            return try await UITestFixtures.FlatWalkSnapshotter().snapshot(region: region, size: size)
        }
    }

    /// protects=a snapshot that fails, or that takes past the timeout (5 s
    /// in the app, 0.2 s here), is the failure result, returned at the
    /// timeout without waiting for a snapshotter that ignores cancellation;
    /// fails_when=a failed snapshot yields a partial or blank picture, or a
    /// slow one blocks past the timeout; no_claim=MapKit's own failure modes
    /// offline (the stub stands in for them).
    @Test func aFailedOrSlowSnapshotIsAFailure() async {
        let walk = Self.walk(20261103, 20261103, blocks: 2)
        let failed = await SharedWalkCard.make(walk: walk, runs: Self.runs, snapshotter: StubSnapshotter(fails: true))
        guard case .failed = failed else {
            Issue.record("a failed snapshot made a picture")
            return
        }
        let start = ContinuousClock.now
        let slow = await SharedWalkCard.make(
            walk: walk,
            runs: Self.runs,
            snapshotter: StubSnapshotter(delay: .seconds(3)),
            timeout: .milliseconds(200)
        )
        guard case .failed = slow else {
            Issue.record("a snapshot past the timeout made a picture")
            return
        }
        #expect(ContinuousClock.now - start < .seconds(2), "the timeout waited for the slow snapshot")
        #expect(SharedWalkCard.snapshotTimeout == .seconds(5))
    }
}
