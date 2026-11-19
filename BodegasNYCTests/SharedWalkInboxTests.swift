//
//  SharedWalkInboxTests.swift
//  BodegasNYCTests
//
//  Opening a walk link (#177 PR 2): the inbox (decode, replace in place,
//  ignore other URLs, `shared_walk_opened`), the presentation gate as a
//  pure decision (eng E2, the 0.5 s gap, intro precedence), the grid-only
//  drawing and the sheet's states, and that opening one needs no Streets
//  Walked store and writes nothing.
//

import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

@Suite
@MainActor
struct SharedWalkInboxTests {
    static let walk = SharedWalk(
        firstDay: WalkedDayKey(value: 20261103),
        lastDay: WalkedDayKey(value: 20261109),
        blockIDs: [100, 200, 999],
        meters: 3_380,
        newCount: 2,
        isEstimate: false
    )

    static func link(_ walk: SharedWalk = walk) throws -> URL {
        guard case .url(let url) = SharedWalkLink.encode(walk) else { throw CancellationError() }
        return url
    }

    static let damagedLink = URL(string: "https://yukichikawada.github.io/BodegasNYC/walk/#1.AAAA")!
    static let newerLink = URL(string: "https://yukichikawada.github.io/BodegasNYC/walk/#2.AAAA.w")!

    // MARK: Inbox

    /// protects=the inbox's one entry and one output: a walk link becomes
    /// the pending item with what it decoded to, and records one
    /// `shared_walk_opened` whose `result` is `ok`, `damaged` or
    /// `needs_update` for the three outcomes; fails_when=a result maps to
    /// the wrong value, an event carries anything but `result`, or nothing
    /// is pending; no_claim=the SDKs (sink tests below and PostHogSinkTests).
    @Test func receiveDecodesAndRecordsTheResult() throws {
        let (telemetry, sink) = makeRecordingTelemetry()
        let inbox = SharedWalkInbox { telemetry.capture($0) }
        inbox.receive(try Self.link())
        #expect(inbox.pending?.result == .walk(Self.walk))
        inbox.receive(Self.damagedLink)
        #expect(inbox.pending?.result == .damaged)
        inbox.receive(Self.newerLink)
        #expect(inbox.pending?.result == .needsUpdate)
        #expect(sink.events == [
            .sharedWalkOpened(result: .opened),
            .sharedWalkOpened(result: .damaged),
            .sharedWalkOpened(result: .needsUpdate)
        ])
        #expect(sink.events.map { $0.properties } == [
            ["result": .string("ok")], ["result": .string("damaged")], ["result": .string("needs_update")]
        ])
        #expect(sink.events.allSatisfy { $0.name == "shared_walk_opened" })
    }

    /// protects=eng E2's "a second link replaces the pending one" and the
    /// design's "replaced in place": a newer link keeps the item's id (so a
    /// sheet on screen is not dismissed and presented again) and bumps its
    /// revision (so the map refits); after `close(_:)` the next link is a new
    /// item; fails_when=a replacement changes the id, keeps the old walk,
    /// or a closed walk lingers; no_claim=SwiftUI's in-place update of a
    /// same-id `.sheet(item:)` (UI checks).
    @Test func aNewerLinkReplacesInPlace() throws {
        let inbox = SharedWalkInbox()
        inbox.receive(try Self.link())
        let first = try #require(inbox.pending)
        let other = SharedWalk(
            firstDay: Self.walk.firstDay, lastDay: Self.walk.firstDay, blockIDs: [5],
            meters: 10, newCount: 0, isEstimate: true
        )
        inbox.receive(try Self.link(other))
        let replaced = try #require(inbox.pending)
        #expect(replaced.id == first.id)
        #expect(replaced.revision == first.revision + 1)
        #expect(replaced.result == .walk(other))
        inbox.close(replaced)
        #expect(inbox.pending == nil)
        inbox.receive(try Self.link())
        #expect(inbox.pending?.id != first.id)
    }

    /// protects=QA's dismiss race: closing the sheet discards only the walk
    /// that was on screen; a link that replaced it after the dismissal began
    /// (same id, newer revision) stays pending to present again, a stale
    /// item from an earlier slot closes nothing, and closing the current
    /// item discards it; fails_when=a dismissal drops a newer link, or a
    /// stale close clears a different walk; no_claim=SwiftUI's timing of
    /// the binding and `onDismiss` (the presenter records the shown item
    /// when the binding goes nil).
    @Test func closingDiscardsOnlyTheShownWalk() throws {
        let inbox = SharedWalkInbox()
        inbox.receive(try Self.link())
        let shown = try #require(inbox.pending)
        inbox.receive(Self.damagedLink)
        inbox.close(shown)
        let newer = try #require(inbox.pending)
        #expect(newer.id == shown.id && newer.revision == shown.revision + 1 && newer.result == .damaged)

        inbox.close(newer)
        #expect(inbox.pending == nil)
        inbox.receive(try Self.link())
        let next = try #require(inbox.pending)
        inbox.close(shown)
        #expect(inbox.pending == next)
    }

    /// protects=the inbox ignores every URL that is not a walk link: no
    /// pending item, no event, and a walk already pending is untouched;
    /// fails_when=a foreign URL replaces a pending walk or is recorded;
    /// no_claim=which URLs iOS routes to the app.
    @Test func otherURLsAreIgnored() throws {
        let (telemetry, sink) = makeRecordingTelemetry()
        let inbox = SharedWalkInbox { telemetry.capture($0) }
        inbox.receive(URL(string: "https://yukichikawada.github.io/BodegasNYC/PRIVACY")!)
        inbox.receive(URL(string: "https://example.com/BodegasNYC/walk/#1.abc.w")!)
        #expect(inbox.pending == nil)
        #expect(sink.events.isEmpty)
        inbox.receive(try Self.link())
        let pending = inbox.pending
        inbox.receive(URL(string: "https://example.com/")!)
        #expect(inbox.pending == pending)
        #expect(sink.events.count == 1)
    }

    // MARK: Presentation gate

    static let clear = SharedWalkPresentation.Inputs(
        isEnvironmentReady: true, isOnboardingShowing: false, isSomethingPresented: false
    )

    /// protects=eng E2: a walk presents at once when nothing blocks it, and
    /// never while the environment loads, onboarding shows, or anything is
    /// presented; fails_when=any blocker lets it through, or a clear first
    /// check holds it; no_claim=that the key window check sees every
    /// presentation (UI test with Your Blocks open).
    @Test func blockersHoldTheWalk() {
        let start = Date()
        #expect(Self.run([(Self.clear, 0)], from: start) == [true])
        let blockers: [SharedWalkPresentation.Inputs] = [
            .init(isEnvironmentReady: false, isOnboardingShowing: false, isSomethingPresented: false),
            .init(isEnvironmentReady: true, isOnboardingShowing: true, isSomethingPresented: false),
            .init(isEnvironmentReady: true, isOnboardingShowing: false, isSomethingPresented: true)
        ]
        for blocked in blockers {
            #expect(Self.run([(blocked, 0), (blocked, 5)], from: start) == [false, false], "\(blocked)")
        }
        // Onboarding ending lets it through at the next check.
        let onboarding = SharedWalkPresentation.Inputs(
            isEnvironmentReady: true, isOnboardingShowing: true, isSomethingPresented: false
        )
        #expect(Self.run([(onboarding, 0), (Self.clear, 0.5)], from: start) == [false, true])
    }

    /// One gate fed `checks` (inputs, seconds after `start`) in order; what
    /// each check answered.
    static func run(_ checks: [(SharedWalkPresentation.Inputs, TimeInterval)], from start: Date) -> [Bool] {
        var gate = SharedWalkPresentation()
        return checks.map { gate.check($0.0, now: start.addingTimeInterval($0.1)) }
    }

    /// protects=the design's "no sooner than 0.5 s after the blocking sheet
    /// finishes dismissing": after a presentation is seen, the first clear
    /// check starts the gap and only a check at least 0.5 s after it
    /// presents; a presentation coming back mid-gap restarts it;
    /// fails_when=the walk presents on the first clear check, under 0.5 s,
    /// or across a returning sheet; no_claim=the 0.5 s polling itself (the
    /// presenter's task).
    @Test func aHeldWalkWaitsHalfASecondAfterTheSheetGoes() {
        let presented = SharedWalkPresentation.Inputs(
            isEnvironmentReady: true, isOnboardingShowing: false, isSomethingPresented: true
        )
        let answers = Self.run([
            (presented, 0), (Self.clear, 1), (Self.clear, 1.4), (presented, 1.45),
            (Self.clear, 2), (Self.clear, 2.49), (Self.clear, 2.5)
        ], from: Date())
        #expect(answers == [false, false, false, false, false, false, true])
    }

    /// protects=the first-run order (#126 with #177): while a shared walk
    /// is pending or shown, the Streets Walked intro is not offered, and
    /// once it is gone the same inputs offer it again (the changed input
    /// restarts the intro's 1.5 s task); fails_when=the intro can present
    /// over or before a pending walk; no_claim=the 1.5 s timing (the
    /// intro's own tests) and the map's wiring of the flag.
    @Test func aPendingWalkComesBeforeTheIntro() {
        var inputs = StreetsWalkedIntroTests.quiet
        #expect(StreetsWalkedIntro.shouldOffer(inputs))
        inputs.isSharedWalkPending = true
        #expect(!StreetsWalkedIntro.shouldOffer(inputs))
        inputs.isSharedWalkPending = false
        #expect(StreetsWalkedIntro.shouldOffer(inputs))
    }

    // MARK: Drawing and states

    /// protects=eng E8 on the grid alone: known ids become runs, ids this
    /// street file lacks are skipped and the known count says how many
    /// were drawn, and the sheet keeps the sender's 3 blocks with "2 of 3
    /// blocks shown." in its footnotes; fails_when=an unknown id is drawn,
    /// the count is wrong, or the coverage line is missing or shown when
    /// all are known; no_claim=the bundled file's coverage (SharedWalkLinkTests).
    @Test func unknownIdsAreSkippedAndCounted() {
        let drawing = SharedWalkDrawing.make(ids: Self.walk.blockIDs, grid: StreetFixtures.cornerGrid())
        guard case .ready(let runs, let known) = drawing else {
            Issue.record("not ready: \(drawing)")
            return
        }
        #expect(known == 2)
        #expect(!runs.isEmpty && runs.allSatisfy { $0.id == 100 || $0.id == 200 })
        #expect(SharedWalkScreen.someNotShown(Self.walk, drawing))
        #expect(SharedWalkScreen.footnotes(Self.walk, drawing).map(\.text) == [
            "2 of 3 blocks shown. Update the app to see the rest.",
            "This walk isn't saved. Open the link to see it again."
        ])
        let all = SharedWalkDrawing.make(ids: [100, 200], grid: StreetFixtures.cornerGrid())
        let estimate = SharedWalk(
            firstDay: Self.walk.firstDay, lastDay: Self.walk.lastDay, blockIDs: [100, 200],
            meters: 10, newCount: 0, isEstimate: true
        )
        #expect(SharedWalkScreen.footnotes(estimate, all).map(\.text) == [
            "Some of this is an estimate. Rides may be counted.",
            "This walk isn't saved. Open the link to see it again."
        ])
    }

    /// protects=the street data failing: the drawing is `.failed` (the
    /// sheet keeps the counts and offers Retry), the loader keeps no
    /// failure so Retry loads again, and a success is parsed once and
    /// shared; fails_when=a failure is cached, a success parses twice, or a
    /// failure reads as no blocks; no_claim=the bundled file's own load
    /// (StreetGridTests).
    @Test func gridFailureAndTheOneParse() async {
        let failing = StreetGridLoader { throw StreetGrid.LoadError.missingResource }
        #expect(await SharedWalkDrawing.load(Self.walk, loader: failing) == .failed)
        #expect(await SharedWalkDrawing.load(Self.walk, loader: failing) == .failed)
        #expect(failing.loads == 2)

        let loader = StreetGridLoader { StreetFixtures.cornerGrid() }
        let first = await SharedWalkDrawing.load(Self.walk, loader: loader)
        let second = await SharedWalkDrawing.load(Self.walk, loader: loader)
        #expect(first == second)
        #expect(loader.loads == 1)
        if case .ready(_, let known) = first { #expect(known == 2) } else { Issue.record("not ready") }
    }

    /// protects=the sheet's state table: a decoded walk shows its map and
    /// counts while loading, failed or ready; none of its blocks known is
    /// the "None of these blocks…" line with Update; a newer format is its
    /// line with Update; damaged is its line without; fails_when=a state
    /// shows the wrong line, offers or hides Update wrongly, or a walk with
    /// some blocks known loses its map; no_claim=layout (UI tests,
    /// captures).
    @Test func screenStates() {
        let walk = Self.walk
        #expect(SharedWalkScreen.make(.walk(walk), drawing: .loading) == .walk(walk, .loading))
        #expect(SharedWalkScreen.make(.walk(walk), drawing: .failed) == .walk(walk, .failed))
        let some = SharedWalkDrawing.ready(runs: [], known: 1)
        #expect(SharedWalkScreen.make(.walk(walk), drawing: some) == .walk(walk, some))
        #expect(SharedWalkScreen.make(.walk(walk), drawing: .ready(runs: [], known: 0))
            == .message(.noneDrawable, offersUpdate: true))
        #expect(SharedWalkScreen.make(.needsUpdate, drawing: .loading) == .message(.needsUpdate, offersUpdate: true))
        #expect(SharedWalkScreen.make(.damaged, drawing: .loading) == .message(.damaged, offersUpdate: false))
        #expect(SharedWalkScreen.appStoreURL.absoluteString == "https://apps.apple.com/app/id6830464647")
    }

    // MARK: No store, no writes

    /// protects=eng Architecture 3 / AC 8: with the Streets Walked
    /// container forced to fail (`AppDelegate` has no view model), a valid
    /// link still becomes a pending walk and draws from the bundled grid;
    /// fails_when=the inbox or the drawing depends on the store or the
    /// view model; no_claim=the sheet's presentation in that state (UI).
    @Test func aWalkOpensWithoutTheStore() async throws {
        let appDelegate = AppDelegate()
        appDelegate.setUpStreetsWalked(container: nil, isBackgroundLaunch: false)
        #expect(appDelegate.streetsWalkedContainer == nil)
        #expect(appDelegate.streetsWalkedViewModel(locationPermissionClient: LocationPermissionClient()) == nil)
        let walk = SharedWalk(
            firstDay: Self.walk.firstDay, lastDay: Self.walk.lastDay, blockIDs: UITestFixtures.sharedWalkFixtureIDs,
            meters: 3_380, newCount: 6, isEstimate: false
        )
        appDelegate.sharedWalkInbox.receive(try Self.link(walk))
        #expect(appDelegate.sharedWalkInbox.pending?.result == .walk(walk))
        let drawing = await SharedWalkDrawing.load(walk)
        guard case .ready(let runs, let known) = drawing else {
            Issue.record("did not draw: \(drawing)")
            return
        }
        #expect(known == 53 && !runs.isEmpty)
    }

    /// protects=AC 8 "opening writes nothing": receiving a link and drawing
    /// it leave every Streets Walked model's row count in a seeded store
    /// unchanged, and the app's `firstRun.` and `streetsWalked.` defaults as
    /// they were; fails_when=the open path saves a row or sets one of those
    /// keys; no_claim=the view's own side effects (it reads no store and no
    /// location; checked by reading the code and the UI tests), and keys
    /// other suites running in parallel may write.
    @Test func openingWritesNothing() async throws {
        let container = try makeInMemoryModelContainer()
        try StreetFixtures.seed(StreetFixtures.walk(from: (0, 0), to: (100, 0)), in: container.mainContext)
        let context = container.mainContext
        func counts() throws -> [Int] {
            [
                try context.fetchCount(FetchDescriptor<WalkedPoint>()),
                try context.fetchCount(FetchDescriptor<WalkedBlock>()),
                try context.fetchCount(FetchDescriptor<WalkedMatchState>()),
                try context.fetchCount(FetchDescriptor<WalkedDayBlock>()),
                try context.fetchCount(FetchDescriptor<WalkedDay>())
            ]
        }
        func appDefaults() -> [String: String] {
            UserDefaults.standard.dictionaryRepresentation()
                .filter { $0.key.hasPrefix("firstRun.") || $0.key.hasPrefix("streetsWalked.") }
                .mapValues { "\($0)" }
        }
        let rowsBefore = try counts()
        let defaultsBefore = appDefaults()
        #expect(rowsBefore[0] > 0)

        let inbox = SharedWalkInbox()
        inbox.receive(try Self.link())
        if case .walk(let walk) = inbox.pending?.result {
            _ = await SharedWalkDrawing.load(walk)
        } else {
            Issue.record("no walk pending")
        }
        if let shown = inbox.pending { inbox.close(shown) }

        #expect(try counts() == rowsBefore)
        #expect(!context.hasChanges)
        #expect(appDefaults() == defaultsBefore)
    }
}
