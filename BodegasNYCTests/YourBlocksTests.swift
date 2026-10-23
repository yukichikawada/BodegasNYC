//
//  YourBlocksTests.swift
//  BodegasNYCTests
//
//  The Your Blocks sheet's content (#108 PR 2, design D7, D8, D6, D11):
//  percent and count text, state precedence, the Motion row, and the
//  VoiceOver labels, all from `YourBlocksContent` and the `AppCopy`
//  templates, without a view. The sheet's view-model wiring is in
//  `StreetsWalkedViewModelTests`; the rendered sheet in the UI test.
//

import Foundation
import Testing

@testable import BodegasNYC

@Suite
@MainActor
struct YourBlocksTests {
    /// The 2026-10 header counts, in display order.
    private static let totals: [(Borough, Int)] = [
        (.manhattan, 9_300), (.brooklyn, 23_462), (.queens, 37_882), (.bronx, 13_987), (.statenIsland, 14_729)
    ]

    private static func progress(_ walked: [Borough: Int] = [:]) -> [BoroughProgress] {
        totals.map { BoroughProgress(borough: $0.0, walked: walked[$0.0] ?? 0, total: $0.1) }
    }

    private static func content(
        countState: StreetsWalkedViewModel.CountState = .ready,
        hasCounted: Bool = true,
        progress: [BoroughProgress] = progress(),
        isRecording: Bool = true,
        motion: MotionAuthorization = .authorized
    ) -> YourBlocksContent {
        YourBlocksContent(
            countState: countState,
            hasCounted: hasCounted,
            progress: progress,
            isRecording: isRecording,
            motion: motion
        )
    }

    // MARK: Percent and counts

    /// protects: the trailing percent rounds down to a whole number, and any
    /// nonzero count under 1% reads "<1%" (spec Implementation 7).
    /// fails_when: 0 walked shows "<1%", 1 of 9,300 shows "0%", 4.99% rounds
    /// up to "5%", or a full borough is not "100%".
    /// no_claim: the font or alignment of the value (live QA screenshots).
    @Test func percentRoundsDownWithALessThanOneBand() {
        let cases: [(Int, Int, String)] = [
            (0, 9_300, "0%"),
            (1, 9_300, "<1%"),
            (92, 9_300, "<1%"),
            (93, 9_300, "1%"),
            (464, 9_300, "4%"),
            (499, 10_000, "4%"),
            (9_299, 9_300, "99%"),
            (9_300, 9_300, "100%"),
            (0, 0, "0%")
        ]
        for (walked, total, text) in cases {
            #expect(
                AppCopy.percentText(BoroughProgress.percent(walked: walked, total: total)) == text,
                "\(walked) of \(total)"
            )
        }
    }

    /// protects: the citywide row sums every borough's walked and total
    /// blocks (design D7: "412 blocks" with "of 99,360"), and its percent is
    /// of the city, not an average of borough percents.
    /// fails_when: the city total is not 99,360 for the 2026-10 counts, a
    /// borough is left out, or the percent averages boroughs.
    /// no_claim: that the bundle's totals are these (StreetGridTests).
    @Test func citywideRowSumsTheBoroughs() {
        let content = Self.content(progress: Self.progress([.manhattan: 412, .queens: 600]))
        #expect(content.citywide.walked == 1_012)
        #expect(content.citywide.total == 99_360)
        // 1,012 / 99,360 = 1.02%; the borough percents average 1.0%.
        #expect(content.citywide.percentText == "1%")
        let parts = AppCopy.citywideBlockCountParts(walked: 412, total: 99_360)
        #expect(parts.walked == "412 blocks")
        #expect(parts.total == "of 99,360")
        #expect(AppCopy.citywideBlockCountParts(walked: 1, total: 99_360).walked == "1 block")
        #expect(AppCopy.citywideBlockCountParts(walked: 12_345, total: 99_360).walked == "12,345 blocks")
    }

    /// protects: a borough's count reads "412 of 9,300 blocks", grouped,
    /// and zero reads "0 of 9,300 blocks" (design D7, D8).
    /// fails_when: thousands are ungrouped ("9300"), the order is flipped,
    /// or "blocks" is dropped.
    /// no_claim: the `textMuted` color (screenshots).
    @Test func boroughCountText() {
        #expect(AppCopy.boroughBlockCount(walked: 412, total: 9_300).text == "412 of 9,300 blocks")
        #expect(AppCopy.boroughBlockCount(walked: 0, total: 9_300).text == "0 of 9,300 blocks")
        #expect(AppCopy.boroughBlockCount(walked: 1_204, total: 37_882).text == "1,204 of 37,882 blocks")
    }

    /// protects: the rows are New York City, then Manhattan, Brooklyn,
    /// Queens, Bronx, Staten Island (design D7).
    /// fails_when: the order follows the borough codes or a row is missing.
    /// no_claim: section styling.
    @Test func rowsAreInDisplayOrder() {
        let content = Self.content()
        #expect(content.citywide.name == "New York City")
        #expect(content.boroughs.map(\.name) == ["Manhattan", "Brooklyn", "Queens", "Bronx", "Staten Island"])
    }

    // MARK: States (design D8)

    /// protects: precedence failure > counting > zero, and a recount keeps
    /// the last counts (design D8).
    /// fails_when: a failed street map shows counting or zero, a first count
    /// shows "0 of 9,300", or a recount after a count blanks the values.
    /// no_claim: the 0.5s delay before "Counting your blocks…" (a view timer;
    /// live QA).
    @Test func statePrecedence() {
        // Failure beats everything, counts or not.
        #expect(Self.content(countState: .unavailable, hasCounted: false, progress: []).phase == .unavailable)
        #expect(Self.content(countState: .unavailable, hasCounted: true).phase == .unavailable)
        // First count, nothing saved yet: counting, values are "—".
        let first = Self.content(countState: .counting, hasCounted: false, progress: [])
        #expect(first.phase == .counting)
        #expect(first.boroughs.allSatisfy { $0.walked == nil && $0.percentText == "\u{2014}" })
        #expect(first.citywide.walked == nil)
        // Not yet asked (the sheet's open schedules it): also counting.
        #expect(Self.content(countState: .idle, hasCounted: false, progress: []).phase == .counting)
        // Counted zero, and a recount over zero: zero, with real totals.
        let zero = Self.content(countState: .counting, hasCounted: true)
        #expect(zero.phase == .zero)
        #expect(zero.boroughs.first?.total == 9_300)
        #expect(Self.content(countState: .ready).phase == .zero)
        // A recount over counts keeps them.
        let recount = Self.content(countState: .counting, progress: Self.progress([.manhattan: 412]))
        #expect(recount.phase == .counted)
        #expect(recount.boroughs.first?.walked == 412)
    }

    /// protects: the footer notes appear exactly when they apply: recording
    /// off, Motion denied (design D8).
    /// fails_when: "Recording is off." shows while recording, or the Motion
    /// line shows while authorized or not yet asked.
    /// no_claim: the copy (AppCopyVoiceTests) or layout.
    @Test func footerNotes() {
        #expect(Self.content(isRecording: false).isRecordingOff)
        #expect(Self.content(isRecording: true).isRecordingOff == false)
        #expect(Self.content(motion: .denied).isMotionDenied)
        #expect(Self.content(motion: .notDetermined).isMotionDenied == false)
        #expect(Self.content(motion: .authorized).isMotionDenied == false)
    }

    // MARK: Motion row (design D6, eng R6)

    /// protects: the Motion row asks only someone already recording who was
    /// never asked, becomes Open Settings after a denial, and is hidden
    /// once authorized or where Motion is unsupported.
    /// fails_when: the row shows while not recording, asks after a denial,
    /// or stays after authorization.
    /// no_claim: the system prompt or the Settings deep link (live device).
    @Test func motionRowStateMachine() {
        typealias Content = YourBlocksContent
        #expect(Content.motionRow(authorization: .notDetermined, isRecording: true) == .allowAccess)
        #expect(Content.motionRow(authorization: .denied, isRecording: true) == .openSettings)
        #expect(Content.motionRow(authorization: .authorized, isRecording: true) == .hidden)
        #expect(Content.motionRow(authorization: .unavailable, isRecording: true) == .hidden)
        for authorization in [MotionAuthorization.notDetermined, .denied, .authorized, .unavailable] {
            #expect(Content.motionRow(authorization: authorization, isRecording: false) == .hidden)
        }
    }

    // MARK: VoiceOver (design D11)

    /// protects: each row is one element reading "Manhattan, 412 of 9,300
    /// blocks, 4 percent."; "<1%" reads "less than 1 percent"; "—" reads
    /// "counting" (design D11).
    /// fails_when: VoiceOver hears "<1%", "—", "4%", or the parts as
    /// separate elements' text.
    /// no_claim: that VoiceOver groups the row (the view's
    /// `.accessibilityElement(children: .ignore)`; the UI test reads it).
    @Test func voiceOverLabels() {
        let counted = Self.content(progress: Self.progress([.manhattan: 412, .brooklyn: 3]))
        #expect(counted.boroughs[0].accessibilityLabel == "Manhattan, 412 of 9,300 blocks, 4 percent.")
        #expect(counted.boroughs[1].accessibilityLabel == "Brooklyn, 3 of 23,462 blocks, less than 1 percent.")
        #expect(counted.boroughs[2].accessibilityLabel == "Queens, 0 of 37,882 blocks, 0 percent.")
        #expect(counted.citywide.accessibilityLabel == "New York City, 415 of 99,360 blocks, less than 1 percent.")
        let counting = Self.content(countState: .counting, hasCounted: false, progress: [])
        #expect(counting.boroughs[4].accessibilityLabel == "Staten Island, counting.")
        #expect(counting.citywide.accessibilityLabel == "New York City, counting.")
    }

    // MARK: UI fixture (#108 PR 2)

    /// protects: the UI test's `-UITestWalkedBlocks` fixture walk, matched
    /// against the real bundle, walks exactly one Manhattan block, so the UI
    /// test's expected row ("Manhattan, 1 of 9,300 blocks, less than 1
    /// percent.") is a property of the data, not a guess.
    /// fails_when: the fixture finds no block, walks none, or credits a
    /// second block to 6 tenths.
    /// no_claim: the app's launch-time seeding (the UI test covers it).
    @Test func uiFixtureWalksOneManhattanBlock() throws {
        let grid = try StreetGrid.loadBundled()
        let fixes = UITestFixtures.walkedBlockFixture(grid: grid, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(fixes.count >= 9)
        let masks = BlockMatcher.match(fixes, grid: grid)
        let walked = masks.filter { BlockMatcher.isWalked(mask: $0.value) }.map(\.key)
        #expect(walked.count == 1)
        let index = try #require(walked.first.flatMap { grid.index(ofPhysicalID: $0) })
        #expect(grid.borough(for: index) == .manhattan)
    }
}
