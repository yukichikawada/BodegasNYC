//
//  StreetsWalkedViewModelTests.swift
//  BodegasNYCTests
//
//  Constructs the real StreetsWalkedViewModel with an in-memory
//  ModelContainer — never calls enableTracking() successfully or touches
//  CLLocationManager.startUpdatingLocation(); real background delivery
//  itself isn't unit-testable (same boundary LocationPermissionClientTests
//  draws for permission prompts). Delegate *methods* are still plain Swift
//  functions we can call directly, though — dismissTrackingErrorClearsLastTrackingError
//  below calls locationManager(_:didFailWithError:) synthetically to seed
//  state, without needing a real CLLocationManager to drive anything.
//
//  Since #108 the view model publishes walked blocks, not polylines: the
//  pre-#108 `polylines` assertions are migrated to `walkedBlockIDs` and
//  `walkedRuns` (regression contract AC12). The matcher runs over the
//  fixture corner grid (`StreetFixtures`), never the bundle.
//

import CoreLocation
import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

/// Fails the first `failures` times the matcher reaches `point` (its
/// `willCommit` seam) with a SwiftData-like error, counting every arrival.
final class FailingCommits: @unchecked Sendable {
    struct InjectedFailure: LocalizedError {
        var errorDescription: String? { "Injected save failure" }
    }

    private let lock = NSLock()
    private let point: BlockMatchingActor.CommitPoint
    private var remaining: Int
    private var _attempts = 0
    var attempts: Int { lock.withLock { _attempts } }

    init(failures: Int, at point: BlockMatchingActor.CommitPoint) {
        remaining = failures
        self.point = point
    }

    func attempt(_ reached: BlockMatchingActor.CommitPoint) throws {
        guard reached == point else { return }
        let fails = lock.withLock { () -> Bool in
            _attempts += 1
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if fails { throw InjectedFailure() }
    }
}

/// Parks the first pass that reaches `point` on its own thread until
/// `release()`, or for at most 5 s, so a test can act on the main actor
/// while a pass sits inside its save path.
final class PassPark: @unchecked Sendable {
    private let point: BlockMatchingActor.CommitPoint
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false
    private var _isParked = false
    private var _timedOut = false
    var isParked: Bool { lock.withLock { _isParked } }
    /// The 5 s ran out: whatever the test waited on did not happen while
    /// the pass was parked.
    var timedOut: Bool { lock.withLock { _timedOut } }

    init(at point: BlockMatchingActor.CommitPoint) { self.point = point }

    func hook(_ reached: BlockMatchingActor.CommitPoint) {
        guard reached == point else { return }
        let first = lock.withLock { () -> Bool in
            defer { used = true }
            if !used { _isParked = true }
            return !used
        }
        guard first else { return }
        let result = released.wait(timeout: .now() + 5)
        lock.withLock {
            _isParked = false
            _timedOut = result == .timedOut
        }
    }

    func release() { released.signal() }
}

/// Counts street-data loads, and can fail them.
final class GridLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _loads = 0
    private var _failures = 0
    var loads: Int { lock.withLock { _loads } }
    var failures: Int { lock.withLock { _failures } }
    func load() { lock.withLock { _loads += 1 } }
    func fail() { lock.withLock { _failures += 1 } }
}

@Suite
@MainActor
struct StreetsWalkedViewModelTests {
    private typealias F = StreetFixtures
    /// A confirm tap after every seeded fix (fixtures are dated 2027).
    private static let afterHistory = F.baseDate.addingTimeInterval(86_400)

    private struct Harness {
        let viewModel: StreetsWalkedViewModel
        let context: ModelContext
        let container: ModelContainer
        let matcher: BlockMatchingActor
        let motion: FakeMotionProvider
        let loads: GridLoadCounter
        let defaults: UserDefaults
        let commits: FailingCommits
    }

    private func makeHarness(
        container: ModelContainer? = nil,
        defaults: UserDefaults? = nil,
        motion: FakeMotionProvider = FakeMotionProvider(),
        gridLoads: Bool = true,
        failingCommits: Int = 0,
        failingAt: BlockMatchingActor.CommitPoint = .beforeCheck,
        seam: @escaping @Sendable (BlockMatchingActor.CommitPoint) -> Void = { _ in }
    ) throws -> Harness {
        let container = try container ?? makeInMemoryModelContainer()
        let defaults = try defaults ?? #require(UserDefaults(suiteName: "StreetsWalkedViewModelTests.\(UUID().uuidString)"))
        let loads = GridLoadCounter()
        let commits = FailingCommits(failures: failingCommits, at: failingAt)
        let matcher = BlockMatchingActor(
            container: container,
            activityProvider: motion,
            loadGrid: {
                loads.load()
                guard gridLoads else { throw StreetGrid.LoadError.badMagic }
                return F.cornerGrid()
            },
            onGridLoadFailure: { _ in loads.fail() },
            willCommit: { point in
                seam(point)
                try commits.attempt(point)
            }
        )
        let viewModel = StreetsWalkedViewModel(
            locationPermissionClient: LocationPermissionClient(),
            modelContainer: container,
            userDefaults: defaults,
            motion: motion,
            matcher: matcher,
            firstCountRetryDelay: .zero
        )
        return Harness(
            viewModel: viewModel,
            context: container.mainContext,
            container: container,
            matcher: matcher,
            motion: motion,
            loads: loads,
            defaults: defaults,
            commits: commits
        )
    }

    /// A sidewalk walk along fixture block 100.
    private static let blockWalk = F.walk(from: (0, 12), to: (100, 12))

    private func waitForRefresh(_ viewModel: StreetsWalkedViewModel) async {
        while viewModel.isRefreshing { await Task.yield() }
    }

    // MARK: Migrated from polylines (AC12)

    /// protects: seeded history is matched into walked blocks and runs when
    /// the map asks (`refreshWalkedBlocks`, the old `loadPolylinesIfNeeded`).
    /// fails_when: stored fixes never reach `walkedBlockIDs`/`walkedRuns`.
    /// no_claim: the matcher's rules (BlockMatcherTests).
    @Test func refreshWalkedBlocksMatchesSeededHistory() async throws {
        let harness = try makeHarness()
        try F.seed(Self.blockWalk, in: harness.context)

        await harness.viewModel.refreshWalkedBlocks()

        #expect(harness.viewModel.walkedBlockIDs == [100])
        #expect(harness.viewModel.walkedRuns.map(\.id) == [100])
        #expect(harness.viewModel.hasCounted)
        #expect(harness.viewModel.countState == .ready)
        #expect(harness.viewModel.boroughProgress.first { $0.borough == .manhattan }?.walked == 1)
    }

    /// protects: with no history and recording off nothing is matched and
    /// the street data never loads (spec Implementation 2).
    /// fails_when: an empty store loads the grid or shows blocks.
    /// no_claim: launch-time behaviour of the real app (QA).
    @Test func refreshWithNoHistoryAndRecordingOffLoadsNothing() async throws {
        let harness = try makeHarness()

        await harness.viewModel.refreshWalkedBlocks()

        #expect(harness.viewModel.walkedBlockIDs.isEmpty)
        #expect(harness.viewModel.walkedRuns.isEmpty)
        #expect(harness.viewModel.countState == .idle)
        #expect(harness.loads.loads == 0)
    }

    /// protects: Clear History deletes every fix and every walked block.
    /// fails_when: points or `WalkedBlock` rows survive, or the overlay keeps
    /// runs.
    /// no_claim: Clear during a pass (the clear-during-rebuild tests).
    @Test func clearHistoryDeletesAllPointsAndEmptiesWalkedBlocks() async throws {
        let harness = try makeHarness()
        try F.seed(Self.blockWalk, in: harness.context)
        await harness.viewModel.refreshWalkedBlocks()
        #expect(harness.viewModel.walkedBlockIDs.isEmpty == false)

        try await harness.viewModel.clearHistory(at: Self.afterHistory)

        #expect(harness.viewModel.walkedBlockIDs.isEmpty)
        #expect(harness.viewModel.walkedRuns.isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<WalkedPoint>()).isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<WalkedBlock>()).isEmpty)
        #expect(harness.viewModel.boroughProgress.allSatisfy { $0.walked == 0 })
        #expect(harness.viewModel.hasHistory == false)
    }

    @Test func enableTrackingThrowsWithoutAlwaysAuthorization() async throws {
        let harness = try makeHarness()
        let viewModel = harness.viewModel

        do {
            try await viewModel.enableTracking()
            Issue.record("expected enableTracking() to throw without Always authorization")
        } catch is StreetsWalkedViewModel.StreetsWalkedError {
            // expected
        }
        #expect(viewModel.isTrackingEnabled == false)
    }

    @Test func dismissTrackingErrorClearsLastTrackingError() async throws {
        let viewModel = try makeHarness().viewModel
        // Invokes the delegate method directly to seed an error deterministically
        // rather than driving a real CLLocationManager (see LocationPermissionClientTests).
        viewModel.locationManager(CLLocationManager(), didFailWithError: StreetsWalkedViewModel.StreetsWalkedError.authorizationNotGranted)
        await Task.yield()
        #expect(viewModel.lastTrackingError != nil)

        viewModel.dismissTrackingError()

        #expect(viewModel.lastTrackingError == nil)
    }

    private static func location(
        _ point: WalkedPointSnapshot,
        accuracy: CLLocationAccuracy = 10,
        timestamp: Date
    ) -> CLLocation {
        CLLocation(
            coordinate: point.coordinate.clLocationCoordinate,
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 10,
            timestamp: timestamp
        )
    }

    /// Block 100's sidewalk walk delivered as live fixes: the last now, each
    /// earlier one 2.8 s before (10 m at 3.6 m/s, under the 4 m/s cap, so
    /// the whole walk fits the 30 s freshness gate).
    private static func liveBlockWalk(now: Date) -> [CLLocation] {
        let walk = F.walk(from: (0, 12), to: (100, 12))
        return walk.enumerated().map { index, point in
            location(point, timestamp: now.addingTimeInterval(-2.8 * Double(walk.count - 1 - index)))
        }
    }

    // Eng R2 (was R8 of #24). protects: in the foreground, deliveries are
    // matched, so the overlay and the cards update while walking.
    // fails_when: saved fixes don't reach `walkedBlockIDs` until something
    // else refreshes, or an untrustworthy fix is stored.
    // no_claim: real CLLocationManager delivery.

    @Test func recordingValidLocationsInTheForegroundMatchesThem() async throws {
        let harness = try makeHarness()
        harness.viewModel.sceneActivityChanged(isActive: true)
        await waitForRefresh(harness.viewModel)

        harness.viewModel.recordLocations(Self.liveBlockWalk(now: Date()))
        await waitForRefresh(harness.viewModel)

        #expect(harness.viewModel.walkedBlockIDs == [100])
        #expect(try harness.context.fetch(FetchDescriptor<WalkedPoint>()).count == Self.blockWalk.count)
    }

    @Test func anInaccurateLocationIsNotRecordedAndNothingIsWalked() async throws {
        let harness = try makeHarness()
        harness.viewModel.sceneActivityChanged(isActive: true)
        let now = Date()

        harness.viewModel.recordLocations([
            Self.location(Self.blockWalk[0], accuracy: 200, timestamp: now.addingTimeInterval(-10)),
            Self.location(Self.blockWalk[1], accuracy: -1, timestamp: now)
        ])
        await waitForRefresh(harness.viewModel)

        #expect(harness.viewModel.walkedBlockIDs.isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<WalkedPoint>()).isEmpty)
    }

    @Test func emptyBannerDismissalStartsFalseAndIsNotPersisted() throws {
        let first = try makeHarness()
        #expect(first.viewModel.isEmptyBannerDismissed == false)

        first.viewModel.isEmptyBannerDismissed = true

        // A fresh instance over the same defaults stands in for a relaunch.
        let relaunched = try makeHarness(container: first.container, defaults: first.defaults)
        #expect(relaunched.viewModel.isEmptyBannerDismissed == false)
    }

    @Test func shouldRequestFullAccuracyOnlyWhenCurrentlyReduced() {
        #expect(StreetsWalkedViewModel.shouldRequestFullAccuracy(currentAccuracyAuthorization: .reducedAccuracy) == true)
        #expect(StreetsWalkedViewModel.shouldRequestFullAccuracy(currentAccuracyAuthorization: .fullAccuracy) == false)
    }

    // MARK: Map content churn (#108 R3 device check)

    /// protects: a catch-up that finds nothing new publishes nothing (same
    /// `walkedRunsVersion`, same run values), and new blocks elsewhere leave
    /// an unchanged run's `MKPolyline` object in place, so MapKit keeps its
    /// overlay instead of removing and re-adding every run.
    /// fails_when: every refresh republishes the runs, or a data change
    /// rebuilds every run's polyline.
    /// no_claim: MapKit's own diffing (on-device check).
    @Test func unchangedRunsKeepTheirPolylinesAcrossRefreshes() async throws {
        let harness = try makeHarness()
        try F.seed(Self.blockWalk, in: harness.context)
        await harness.viewModel.refreshWalkedBlocks()
        let version = harness.viewModel.walkedRunsVersion
        let polyline = try #require(harness.viewModel.walkedRuns.first?.polyline)

        await harness.viewModel.refreshWalkedBlocks()
        harness.viewModel.sceneActivityChanged(isActive: true)
        await waitForRefresh(harness.viewModel)
        #expect(harness.viewModel.walkedRunsVersion == version)
        #expect(harness.viewModel.walkedRuns.first?.polyline === polyline)

        try F.seed(F.walk(from: (0, 68), to: (100, 68), startTime: 3_600), in: harness.context)
        await harness.viewModel.refreshWalkedBlocks()
        #expect(harness.viewModel.walkedBlockIDs == [100, 300])
        #expect(harness.viewModel.walkedRunsVersion != version)
        #expect(harness.viewModel.walkedRuns.first { $0.id == 100 }?.polyline === polyline)
    }

    // MARK: When matching runs (eng R2, A2)

    /// protects: a background delivery only persists raw fixes: no match
    /// pass, no street data load (eng R2).
    /// fails_when: a delivery with the scene inactive matches or loads.
    /// no_claim: that iOS reports the scene phase (the map passes it).
    @Test func aBackgroundDeliveryOnlyPersistsRawFixes() async throws {
        let harness = try makeHarness()

        harness.viewModel.recordLocations(Self.liveBlockWalk(now: Date()))

        #expect(harness.viewModel.isRefreshing == false)
        #expect(try harness.context.fetchCount(FetchDescriptor<WalkedPoint>()) == Self.blockWalk.count)
        #expect(try harness.context.fetchCount(FetchDescriptor<WalkedBlock>()) == 0)
        #expect(harness.loads.loads == 0)
        #expect(harness.viewModel.hasHistory)
    }

    /// protects: coming back to the foreground catches up on fixes saved in
    /// the background even when no new fix arrives (eng A2).
    /// fails_when: matching waits for the next delivery.
    /// no_claim: SwiftUI delivering the scene phase change.
    @Test func resumingWithZeroNewFixesCatchesUp() async throws {
        let harness = try makeHarness()
        try F.seed(Self.blockWalk, in: harness.context)
        #expect(harness.viewModel.walkedBlockIDs.isEmpty)

        harness.viewModel.sceneActivityChanged(isActive: true)
        await waitForRefresh(harness.viewModel)

        #expect(harness.viewModel.walkedBlockIDs == [100])
        let unmatched = try harness.context.fetchCount(FetchDescriptor<WalkedPoint>(predicate: #Predicate { !$0.isMatched }))
        #expect(unmatched == 0)
    }

    // MARK: Clear History (eng R9, AC8)

    /// protects: Clear History during a rebuild leaves zero fixes, zero
    /// blocks, no match state, no runs and zero counts: the cancelled pass
    /// does not resurrect masks (AC8).
    /// fails_when: the rebuild saves after the clear, or the view model
    /// shows its summary.
    /// no_claim: a clear that lands between a pass's check and its save
    /// (they run with no suspension between them).
    @Test func clearDuringARebuildLeavesNothing() async throws {
        let harness = try makeHarness()
        try F.seed(Self.blockWalk, in: harness.context)
        harness.motion.holdNext()
        let refresh = Task { await harness.viewModel.refreshWalkedBlocks() }
        await harness.motion.waitUntilHeld()

        let generation = harness.matcher.generation
        let clear = Task { try await harness.viewModel.clearHistory(at: Self.afterHistory) }
        while harness.matcher.generation == generation { await Task.yield() }
        harness.motion.release()
        try await clear.value
        await refresh.value
        await waitForRefresh(harness.viewModel)

        #expect(try harness.context.fetchCount(FetchDescriptor<WalkedPoint>()) == 0)
        #expect(try harness.context.fetchCount(FetchDescriptor<WalkedBlock>()) == 0)
        #expect(try harness.context.fetchCount(FetchDescriptor<WalkedMatchState>()) == 0)
        #expect(harness.viewModel.walkedRuns.isEmpty)
        #expect(harness.viewModel.walkedBlockIDs.isEmpty)
        #expect(harness.viewModel.boroughProgress.allSatisfy { $0.walked == 0 })
    }

    /// protects: the cutoff is the confirm tap: a fix saved after it
    /// survives a clear that lands during a rebuild (eng R9).
    /// fails_when: Clear deletes every fix, or the post-tap fix is lost.
    /// no_claim: the tap time the view passes (MapScreenView reads `Date()`
    /// in the button's action).
    @Test func clearDuringARebuildKeepsAFixSavedAfterTheTap() async throws {
        let harness = try makeHarness()
        try F.seed(Self.blockWalk, in: harness.context)
        let tapTime = F.baseDate.addingTimeInterval(3_600)
        let afterTap = WalkedPointSnapshot(coordinate: F.coordinate(x: 50, y: 0), recordedAt: tapTime.addingTimeInterval(1))
        harness.motion.holdNext()
        let refresh = Task { await harness.viewModel.refreshWalkedBlocks() }
        await harness.motion.waitUntilHeld()
        try F.seed([afterTap], in: harness.context)

        let generation = harness.matcher.generation
        let clear = Task { try await harness.viewModel.clearHistory(at: tapTime) }
        while harness.matcher.generation == generation { await Task.yield() }
        harness.motion.release()
        try await clear.value
        await refresh.value
        await waitForRefresh(harness.viewModel)

        let remaining = try harness.context.fetch(FetchDescriptor<WalkedPoint>())
        #expect(remaining.map(\.id) == [afterTap.id])
        #expect(try harness.context.fetchCount(FetchDescriptor<WalkedBlock>()) == 0)
        #expect(harness.viewModel.walkedBlockIDs.isEmpty)
        #expect(harness.viewModel.hasHistory)
    }

    // MARK: Degraded street data (eng R5)

    /// protects: a street bundle that does not load degrades: fixes keep
    /// recording, no overlay, no "No streets yet." claim, and the failure is
    /// reported once (an `assertionFailure` in the app's DEBUG builds).
    /// fails_when: recording stops, runs appear, or the load is retried and
    /// reported on every pass.
    /// no_claim: the Release build's behaviour on device.
    @Test func aCorruptBundleDegrades() async throws {
        let harness = try makeHarness(gridLoads: false)
        try F.seed(Self.blockWalk, in: harness.context)

        await harness.viewModel.refreshWalkedBlocks()
        await harness.viewModel.refreshWalkedBlocks()
        harness.viewModel.recordLocations(Self.liveBlockWalk(now: Date()))

        #expect(harness.viewModel.countState == .unavailable)
        #expect(harness.viewModel.walkedRuns.isEmpty)
        #expect(harness.loads.failures == 1)
        #expect(try harness.context.fetchCount(FetchDescriptor<WalkedPoint>()) == Self.blockWalk.count * 2)
    }

    // MARK: Show on Map (eng R11), counting (design D8), Motion (design D6)

    /// protects: Show on Map is persisted, on by default, and independent
    /// of recording and Clear History; the overlay needs history too.
    /// fails_when: it resets on relaunch, on Stop Recording or on Clear.
    /// no_claim: the menu's toggle rendering.
    @Test func showOnMapPersistsAndStandsAlone() async throws {
        let first = try makeHarness()
        #expect(first.viewModel.isOverlayVisible)
        #expect(first.viewModel.showsWalkedOverlay == false)
        try F.seed(Self.blockWalk, in: first.context)
        await first.viewModel.refreshWalkedBlocks()
        #expect(first.viewModel.showsWalkedOverlay)

        first.viewModel.isOverlayVisible = false
        first.viewModel.disableTracking()
        try await first.viewModel.clearHistory(at: Self.afterHistory)

        let relaunched = try makeHarness(defaults: first.defaults)
        #expect(relaunched.viewModel.isOverlayVisible == false)
        #expect(relaunched.viewModel.showsWalkedOverlay == false)
    }

    /// protects: while the first count runs nothing claims zero blocks
    /// (design D8): `hasCounted` stays false until a count saves.
    /// fails_when: counting with no prior blocks reports a finished count.
    /// no_claim: the 0.5 s "Counting your blocks…" line (Your Blocks, PR 2).
    @Test func theFirstCountIsNotAZero() async throws {
        let harness = try makeHarness()
        try F.seed(Self.blockWalk, in: harness.context)
        harness.motion.holdNext()
        let refresh = Task { await harness.viewModel.refreshWalkedBlocks() }
        await harness.motion.waitUntilHeld()

        #expect(harness.viewModel.countState == .counting)
        #expect(harness.viewModel.hasCounted == false)

        harness.motion.release()
        await refresh.value
        #expect(harness.viewModel.hasCounted)
        #expect(harness.viewModel.walkedBlockIDs == [100])
    }

    /// protects: Motion & Fitness is asked once, ever, and only when it was
    /// never answered (design D6).
    /// fails_when: a second Start Recording asks again, or an answered
    /// permission is asked.
    /// no_claim: the timing after the location dialogs (MapScreenView).
    @Test func motionIsAskedOnce() async throws {
        let harness = try makeHarness(motion: FakeMotionProvider(authorization: .notDetermined))
        await harness.viewModel.requestMotionAccessIfNeeded()
        #expect(harness.motion.requests == 1)

        // Same device (same defaults), the prompt somehow unanswered: no
        // second ask.
        let again = try makeHarness(defaults: harness.defaults, motion: FakeMotionProvider(authorization: .notDetermined))
        await again.viewModel.requestMotionAccessIfNeeded()
        #expect(again.motion.requests == 0)

        let denied = try makeHarness(motion: FakeMotionProvider(authorization: .denied))
        await denied.viewModel.requestMotionAccessIfNeeded()
        #expect(denied.motion.requests == 0)
    }

    // MARK: Your Blocks (#108 PR 2, design D6, D8, eng R2)

    /// protects: opening Your Blocks loads the street data for the totals
    /// even with no history and recording off, and lands on the zero state
    /// with real totals (eng R2, design D8).
    /// fails_when: the sheet stays counting forever without history, or
    /// shows no totals.
    /// no_claim: that the map or launch load nothing (the no-history test
    /// above).
    @Test func openingYourBlocksCountsWithoutHistory() async throws {
        let harness = try makeHarness()
        #expect(harness.viewModel.yourBlocks.phase == .counting)

        harness.viewModel.yourBlocksDidOpen()
        await waitForRefresh(harness.viewModel)

        #expect(harness.loads.loads == 1)
        let content = harness.viewModel.yourBlocks
        #expect(content.phase == .zero)
        #expect(content.boroughs.first?.borough == .manhattan)
        #expect(content.boroughs.first?.total == F.cornerSegments.count)
        #expect(content.boroughs.first?.walked == 0)
    }

    /// protects: a street map that fails to load shows the failure state in
    /// Your Blocks, over counting (design D8, eng R5).
    /// fails_when: the sheet shows "\u{2014}" or zero counts after the load
    /// failed.
    /// no_claim: the copy's color (`.primary`; screenshots).
    @Test func yourBlocksShowsTheStreetMapFailure() async throws {
        let harness = try makeHarness(gridLoads: false)
        try F.seed(Self.blockWalk, in: harness.context)

        harness.viewModel.yourBlocksDidOpen()
        await waitForRefresh(harness.viewModel)

        #expect(harness.loads.failures == 1)
        #expect(harness.viewModel.yourBlocks.phase == .unavailable)
    }

    /// protects: counts walked before opening show in the sheet, and Clear
    /// History zeroes them without blanking the totals.
    /// fails_when: the sheet's Manhattan row misses the walked block, or a
    /// clear leaves the counting placeholder.
    /// no_claim: the rendered row (UI test).
    @Test func yourBlocksReflectsWalkedBlocksAndClear() async throws {
        let harness = try makeHarness()
        try F.seed(Self.blockWalk, in: harness.context)
        harness.viewModel.yourBlocksDidOpen()
        await waitForRefresh(harness.viewModel)

        let manhattan = try #require(harness.viewModel.yourBlocks.boroughs.first)
        #expect(manhattan.walked == 1)
        #expect(harness.viewModel.yourBlocks.phase == .counted)

        try await harness.viewModel.clearHistory(at: Self.afterHistory)
        #expect(harness.viewModel.yourBlocks.phase == .zero)
        #expect(harness.viewModel.yourBlocks.boroughs.first?.total == F.cornerSegments.count)
    }

    /// protects: a Clear History during the first count ends on the zero
    /// state with real totals, not on "Counting your blocks…" (#113 item 5,
    /// design D8): after a Clear there is nothing left to count.
    /// fails_when: the cancelled first count leaves the sheet counting, or
    /// the zero state has no totals.
    /// no_claim: the rendered sheet (UI test); a Clear before the street
    /// data ever loaded (nothing is counting then).
    @Test func aClearDuringTheFirstCountEndsOnZero() async throws {
        let harness = try makeHarness()
        try F.seed(Self.blockWalk, in: harness.context)
        harness.motion.holdNext()
        harness.viewModel.yourBlocksDidOpen()
        await harness.motion.waitUntilHeld()
        #expect(harness.viewModel.yourBlocks.phase == .counting)

        let generation = harness.matcher.generation
        let clear = Task { try await harness.viewModel.clearHistory(at: Self.afterHistory) }
        while harness.matcher.generation == generation { await Task.yield() }
        harness.motion.release()
        try await clear.value
        await waitForRefresh(harness.viewModel)

        let content = harness.viewModel.yourBlocks
        #expect(content.phase == .zero)
        #expect(content.citywide.walked == 0)
        #expect(content.citywide.total == F.cornerSegments.count)
        #expect(try harness.context.fetchCount(FetchDescriptor<WalkedBlock>()) == 0)
    }

    /// protects: a first count that fails is retried once, and a second
    /// failure stops claiming "Counting your blocks…": the sheet shows the
    /// count failure, the error reaches the banner, and reopening the sheet
    /// counts again (#113 item 5).
    /// fails_when: the sheet stays `.counting` after two failures, the
    /// failure is not retried, it is retried more than once, or reopening
    /// does not recover.
    /// no_claim: the copy's rendering (`.primary`, screenshots); what made
    /// SwiftData fail (injected here).
    @Test func aFirstCountThatFailsTwiceStopsCounting() async throws {
        let harness = try makeHarness(failingCommits: 2)
        try F.seed(Self.blockWalk, in: harness.context)

        harness.viewModel.yourBlocksDidOpen()
        await waitForRefresh(harness.viewModel)

        #expect(harness.commits.attempts == 2)
        #expect(harness.viewModel.yourBlocks.phase != .counting)
        #expect(harness.viewModel.yourBlocks.phase == .countFailed)
        #expect(harness.viewModel.hasCounted == false)
        #expect(harness.viewModel.lastTrackingError != nil)

        harness.viewModel.yourBlocksDidOpen()
        await waitForRefresh(harness.viewModel)
        #expect(harness.viewModel.yourBlocks.phase == .counted)
        #expect(harness.viewModel.walkedBlockIDs == [100])
    }

    /// protects: a first count that fails once and then succeeds on the
    /// automatic retry ends counted, with no error shown (#113 item 5).
    /// fails_when: one failure leaves the sheet counting, or the recovered
    /// failure still raises the tracking-error banner.
    /// no_claim: the retry delay's length (zero in tests, 0.5 s in the app).
    @Test func aFirstCountThatFailsOnceIsRetried() async throws {
        let harness = try makeHarness(failingCommits: 1)
        try F.seed(Self.blockWalk, in: harness.context)

        harness.viewModel.yourBlocksDidOpen()
        await waitForRefresh(harness.viewModel)

        #expect(harness.commits.attempts == 2)
        #expect(harness.viewModel.yourBlocks.phase == .counted)
        #expect(harness.viewModel.hasCounted)
        #expect(harness.viewModel.walkedBlockIDs == [100])
        #expect(harness.viewModel.lastTrackingError == nil)
    }

    /// protects: Clear History, run by the view model while a pass is parked
    /// inside its save path (before its generation check, or after it, so
    /// the pass saves after the Clear's delete), returns from its tap work
    /// without waiting on the pass, and once it completes no trace of
    /// deleted history is left: no fix at or before the tap, every fix after
    /// the tap kept, and the blocks are exactly the post-tap walk's (#113
    /// item 2, eng R9).
    /// fails_when: the main actor waits on the pass (the park times out, or
    /// the generation only moves after the pass resumes), a pre-tap fix or
    /// its block survives, or a post-tap fix is lost.
    /// no_claim: SwiftData's own locking on an on-disk store (in-memory
    /// here); how long a real save takes.
    @Test(arguments: [BlockMatchingActor.CommitPoint.beforeCheck, .beforeSave])
    func clearHistoryNeverWaitsOnAPassAndLeavesNoTrace(_ point: BlockMatchingActor.CommitPoint) async throws {
        let park = PassPark(at: point)
        let harness = try makeHarness(seam: { park.hook($0) })
        try F.seed(Self.blockWalk, in: harness.context)
        let tapTime = F.baseDate.addingTimeInterval(3_600)
        let afterTap = F.walk(from: (0, 68), to: (100, 68), startTime: 3_601)

        let refresh = Task { await harness.viewModel.refreshWalkedBlocks() }
        while !park.isParked { await Task.yield() }
        let generation = harness.matcher.generation
        let clear = Task { try await harness.viewModel.clearHistory(at: tapTime) }
        while harness.matcher.generation == generation { await Task.yield() }
        // The tap's delete, save and bump are done; the pass never moved.
        #expect(park.isParked)
        #expect(!park.timedOut)
        #expect(try harness.context.fetchCount(FetchDescriptor<WalkedPoint>()) == 0)
        try F.seed(afterTap, in: harness.context)
        park.release()
        try await clear.value
        await refresh.value
        await waitForRefresh(harness.viewModel)
        await harness.viewModel.refreshWalkedBlocks()

        #expect(!park.timedOut)
        #expect(try harness.context.fetchCount(FetchDescriptor<WalkedPoint>(predicate: #Predicate { $0.recordedAt <= tapTime })) == 0)
        let remaining = try harness.context.fetch(FetchDescriptor<WalkedPoint>())
        #expect(Set(remaining.map(\.id)) == Set(afterTap.map(\.id)))
        let expected = BlockMatcher.match(afterTap, grid: F.cornerGrid())
        let saved = Dictionary(
            uniqueKeysWithValues: try harness.context.fetch(FetchDescriptor<WalkedBlock>()).map { ($0.physicalID, $0.mask) }
        )
        #expect(saved == expected)
        #expect(harness.viewModel.walkedBlockIDs == WalkedSummary(masks: expected, grid: F.cornerGrid()).walkedIDs)
        #expect(!harness.viewModel.walkedBlockIDs.contains(100))
    }

    /// protects: a Clear History whose cache clear fails during the first
    /// count does not leave the sheet on "Counting your blocks…" with
    /// nothing scheduled: it shows the count failure and the error, and
    /// reopening the sheet counts again (#113 item 5, QA P3).
    /// fails_when: the sheet stays `.counting`, or reopening does not
    /// recover to the zero state.
    /// no_claim: what made SwiftData fail (injected here).
    @Test func aFailedCacheClearDuringTheFirstCountStopsCounting() async throws {
        let harness = try makeHarness(failingCommits: 1, failingAt: .clear)
        try F.seed(Self.blockWalk, in: harness.context)
        harness.motion.holdNext()
        harness.viewModel.yourBlocksDidOpen()
        await harness.motion.waitUntilHeld()

        let generation = harness.matcher.generation
        let clear = Task { try await harness.viewModel.clearHistory(at: Self.afterHistory) }
        while harness.matcher.generation == generation { await Task.yield() }
        harness.motion.release()
        try await clear.value
        await waitForRefresh(harness.viewModel)

        #expect(harness.commits.attempts == 1)
        #expect(harness.viewModel.yourBlocks.phase == .countFailed)
        #expect(harness.viewModel.lastTrackingError != nil)

        harness.viewModel.yourBlocksDidOpen()
        await waitForRefresh(harness.viewModel)
        #expect(harness.viewModel.yourBlocks.phase == .zero)
    }

    /// protects: the Allow Motion Access row asks even after the one-time
    /// ask was spent (an explicit tap), and the sheet sees the answer:
    /// allowed hides the row, denied turns it into Open Settings (design D6).
    /// fails_when: the row's tap is swallowed by the once-ever flag, or the
    /// published authorization stays stale after the answer.
    /// no_claim: the system prompt itself (CoreMotion; live device).
    @Test func motionRowAsksAndFollowsTheAnswer() async throws {
        typealias Content = YourBlocksContent
        let allows = try makeHarness(motion: FakeMotionProvider(authorization: .notDetermined))
        allows.defaults.set(true, forKey: "streetsWalked.hasAskedForMotion")
        #expect(Content.motionRow(authorization: allows.viewModel.motionAuthorization, isRecording: true) == .allowAccess)
        await allows.viewModel.requestMotionAccess()
        #expect(allows.motion.requests == 1)
        #expect(allows.viewModel.motionAuthorization == .authorized)
        #expect(Content.motionRow(authorization: allows.viewModel.motionAuthorization, isRecording: true) == .hidden)

        let denies = try makeHarness(motion: FakeMotionProvider(authorization: .notDetermined, grantsOnRequest: false))
        await denies.viewModel.requestMotionAccess()
        #expect(denies.viewModel.motionAuthorization == .denied)
        #expect(Content.motionRow(authorization: denies.viewModel.motionAuthorization, isRecording: true) == .openSettings)
        // Once denied, a tap never re-asks (the row opens Settings instead).
        await denies.viewModel.requestMotionAccess()
        #expect(denies.motion.requests == 1)
    }
}
