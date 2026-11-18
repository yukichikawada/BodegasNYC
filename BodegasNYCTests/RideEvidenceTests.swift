//
//  RideEvidenceTests.swift
//  BodegasNYCTests
//
//  Ride evidence saved on fixes (#170 PR 0): CoreMotion answers for 7 days
//  only, so each pass saves its answer on the fixes, and every later
//  rebuild reproduces the original decision.
//

import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

@MainActor
struct RideEvidenceTests {
    private typealias F = StreetFixtures

    /// Block 100 walked at 1.4 m/s from t = 0 s (about 71 s).
    private static let walk = F.walk(from: (0, 12), to: (100, 12))
    /// Block 300 at 3 m/s from t = 600 s: under the speed cap, so only
    /// CoreMotion can tell it was a ride.
    private static let slowRide = F.walk(from: (0, 68), to: (100, 68), speed: 3, startTime: 600)
    /// Block 201 walked from t = 2,000 s, a separate walk.
    private static let laterWalk = F.walk(from: (88, 68), to: (88, 12), startTime: 2_000)
    private static let history = walk + slowRide + laterWalk

    private static func at(_ seconds: TimeInterval) -> Date { F.baseDate.addingTimeInterval(seconds) }
    private static let coverage = DateInterval(start: at(-60), end: at(3_000))
    /// CoreMotion inside its window: the slow ride was automotive.
    private static let rideActivity = VehicleActivity(intervals: [DateInterval(start: at(590), end: at(700))], coverage: coverage)
    /// CoreMotion inside its window, seeing no ride at all.
    private static let walkingActivity = VehicleActivity(intervals: [], coverage: coverage)

    private func savedMasks(_ container: ModelContainer) throws -> [UInt32: UInt16] {
        Dictionary(uniqueKeysWithValues: try ModelContext(container).fetch(FetchDescriptor<WalkedBlock>()).map { ($0.physicalID, $0.mask) })
    }

    private func savedEvidence(_ container: ModelContainer) throws -> [UUID: RideEvidence] {
        Dictionary(uniqueKeysWithValues: try ModelContext(container).fetch(FetchDescriptor<WalkedPoint>()).map { ($0.id, $0.ride) })
    }

    /// Saves the three walks one pass each, CoreMotion seeing the ride.
    private func matchInPasses(_ container: ModelContainer) throws -> [WalkedPassKind] {
        let store = WalkedBlockStore(container: container, grid: F.cornerGrid(stamp: 1))
        var kinds: [WalkedPassKind] = []
        for part in [Self.walk, Self.slowRide, Self.laterWalk] {
            try F.seed(part, in: container.mainContext)
            let plan = try #require(try store.plan())
            kinds.append(plan.kind)
            #expect(try store.apply(plan, activity: Self.rideActivity) { true })
        }
        return kinds
    }

    /// A data refresh: a new stamp, so the next pass rebuilds everything.
    private func rebuild(_ container: ModelContainer, activity: VehicleActivity) throws {
        let store = WalkedBlockStore(container: container, grid: F.cornerGrid(stamp: 2))
        let plan = try #require(try store.plan())
        #expect(plan.kind == .rebuild)
        #expect(try store.apply(plan, activity: activity) { true })
    }

    /// protects: P0-1. History matched in passes while CoreMotion saw a slow
    /// ride, then rebuilt once CoreMotion has forgotten (`.unavailable`),
    /// saves the same masks; the control, the same history rebuilt with no
    /// saved evidence, credits the ride, so the saved evidence is what holds
    /// it.
    /// fails_when: a pass does not save evidence, the snapshot drops it, or
    /// `isCreditableLeg` ignores it and falls back to the speed rule.
    /// no_claim: CoreMotion's own classification; the 7-day clip itself
    /// (`CoreMotionActivityProvider.vehicleActivity`).
    @Test func savedEvidenceHoldsARideThroughARebuildWithoutMotion() throws {
        let container = try makeInMemoryModelContainer()
        #expect(try matchInPasses(container) == [.rebuild, .incremental, .incremental])
        let matched = try savedMasks(container)
        #expect(BlockMatcher.isWalked(mask: matched[100] ?? 0) && BlockMatcher.isWalked(mask: matched[201] ?? 0))
        #expect(!BlockMatcher.isWalked(mask: matched[300] ?? 0), "the slow ride is not walking")
        let evidence = try savedEvidence(container)
        #expect(Self.slowRide.allSatisfy { evidence[$0.id] == .ride })
        #expect(Self.walk.dropFirst().allSatisfy { evidence[$0.id] == .walking })

        try rebuild(container, activity: .unavailable)
        #expect(try savedMasks(container) == matched)

        let control = try makeInMemoryModelContainer()
        try F.seed(Self.history, in: control.mainContext)
        try rebuild(control, activity: .unavailable)
        #expect(BlockMatcher.isWalked(mask: try savedMasks(control)[300] ?? 0), "without evidence the speed rule credits the ride")
    }

    /// protects: evidence once saved is never overwritten: a rebuild whose
    /// CoreMotion answer differs (no ride seen) keeps every saved value and
    /// the masks they gave.
    /// fails_when: a pass writes evidence onto a fix that already has it.
    /// no_claim: which of two conflicting CoreMotion answers is right.
    @Test func knownEvidenceIsNotOverwrittenByADifferentAnswer() throws {
        let container = try makeInMemoryModelContainer()
        _ = try matchInPasses(container)
        let masks = try savedMasks(container)
        let evidence = try savedEvidence(container)

        try rebuild(container, activity: Self.walkingActivity)
        #expect(try savedEvidence(container) == evidence)
        #expect(try savedMasks(container) == masks)
        #expect(evidence[Self.walk[0].id] == .unknown, "no leg ends at the first fix")
    }

    /// protects: a late fix inside the ride forces a rebuild (eng E1 item 4)
    /// that leaves every saved value in place; the late fix gets its own
    /// evidence from the pass, and the ride still credits nothing.
    /// fails_when: the rebuild re-reads evidence for fixes that have it, or
    /// skips the late fix.
    /// no_claim: how often iOS delivers late.
    @Test func aLateFixRebuildLeavesSavedEvidenceInPlace() throws {
        let container = try makeInMemoryModelContainer()
        _ = try matchInPasses(container)
        let evidence = try savedEvidence(container)

        let late = WalkedPointSnapshot(coordinate: F.coordinate(x: 45, y: 68), recordedAt: Self.at(615))
        try F.seed([late], in: container.mainContext)
        let store = WalkedBlockStore(container: container, grid: F.cornerGrid(stamp: 1))
        let plan = try #require(try store.plan())
        #expect(plan.kind == .rebuild)
        #expect(try store.apply(plan, activity: Self.walkingActivity) { true })

        var after = try savedEvidence(container)
        #expect(after.removeValue(forKey: late.id) == .walking)
        #expect(after == evidence)
        #expect(!BlockMatcher.isWalked(mask: try savedMasks(container)[300] ?? 0))
    }

    /// protects: P0-3. With Motion & Fitness denied (no coverage), passes
    /// save no evidence and query the provider exactly once each, as before
    /// #170, and never prompt.
    /// fails_when: a pass saves `.walking` without coverage, or the evidence
    /// step queries CoreMotion on its own.
    /// no_claim: the live `CoreMotionActivityProvider` (a fake stands in).
    @Test func noCoverageSavesNoEvidenceAndQueriesNothingNew() async throws {
        let container = try makeInMemoryModelContainer()
        let motion = FakeMotionProvider(authorization: .denied)
        let actor = BlockMatchingActor(
            container: container,
            activityProvider: motion,
            loadGrid: { F.cornerGrid() },
            onGridLoadFailure: { _ in }
        )
        try F.seed(Self.walk, in: container.mainContext)
        _ = await actor.catchUp()
        try F.seed(Self.slowRide, in: container.mainContext)
        _ = await actor.catchUp()
        _ = await actor.catchUp()

        #expect(try savedEvidence(container).values.allSatisfy { $0 == .unknown })
        #expect(motion.queries == 2, "one query per pass with work, as before")
        #expect(motion.requests == 0)
        let ridesWithoutCoverage = VehicleActivity(intervals: [Self.coverage], coverage: nil)
        #expect(BlockMatcher.evidence(Self.history, activity: ridesWithoutCoverage).isEmpty)
    }

    /// protects: P0-4. The real store written by the 1.0.0 schema
    /// (`Fixtures/streets-walked-1.0.0`) opens under today's schema, every
    /// fix reads `.unknown`, and its masks, flags and stamp are as written.
    /// fails_when: `storedRide` loses its default (no lightweight
    /// migration), or the migration touches the cache.
    /// no_claim: stores from before 1.0.0; a device upgrade from the App
    /// Store build.
    @Test func theOneZeroZeroStoreOpensWithEveryFixUnknown() throws {
        let bundled = try #require(Bundle(for: FakeMotionProvider.self).url(forResource: "streets-walked-1.0.0", withExtension: "store"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("streets-walked.store")
        try FileManager.default.copyItem(at: bundled, to: copy)

        let container = try ModelContainer(for: Schema(StreetsWalkedSchema.models), configurations: ModelConfiguration(url: copy))
        let points = try ModelContext(container).fetch(FetchDescriptor<WalkedPoint>())
        #expect(points.count == 50)
        #expect(points.allSatisfy { $0.isMatched && $0.ride == .unknown && $0.storedRide == 0 })
        #expect(try savedMasks(container) == [3: 1023, 5: 1023, 6: 1023, 14: 511, 23: 511, 24: 255])
        #expect(try ModelContext(container).fetch(FetchDescriptor<WalkedMatchState>()).map(\.datasetStamp) == [1_792_226_103])
    }

    // MARK: BlockMatcher.evidence

    private static let pair = [
        WalkedPointSnapshot(coordinate: F.coordinate(x: 0, y: 0), recordedAt: at(0)),
        WalkedPointSnapshot(coordinate: F.coordinate(x: 10, y: 0), recordedAt: at(7))
    ]

    /// protects: a covered leg is saved on its end fix as `.ride` or
    /// `.walking` per CoreMotion; the first fix, which ends no leg, gets
    /// nothing.
    /// fails_when: evidence is keyed by the start fix, or a covered leg with
    /// no ride is left unknown.
    /// no_claim: the store write (the tests above).
    @Test func aCoveredLegIsARideOrWalking() {
        let ride = VehicleActivity(intervals: [DateInterval(start: Self.at(3), end: Self.at(5))], coverage: Self.coverage)
        #expect(BlockMatcher.evidence(Self.pair, activity: ride) == [Self.pair[1].id: .ride])
        #expect(BlockMatcher.evidence(Self.pair, activity: Self.walkingActivity) == [Self.pair[1].id: .walking])
    }

    /// protects: a leg whose start is outside the coverage, or no coverage
    /// at all, is left out, so it stays unknown for the speed rule.
    /// fails_when: an uncovered leg is saved as `.walking`.
    /// no_claim: legs that start inside and end outside (judged, as today's
    /// `isRide` does).
    @Test func anUncoveredLegIsLeftOut() {
        let lateCoverage = VehicleActivity(intervals: [], coverage: DateInterval(start: Self.at(1), end: Self.at(100)))
        #expect(BlockMatcher.evidence(Self.pair, activity: lateCoverage).isEmpty)
        #expect(BlockMatcher.evidence(Self.pair, activity: .unavailable).isEmpty)
        #expect(BlockMatcher.evidence(Array(Self.pair.prefix(1)), activity: Self.walkingActivity).isEmpty)
    }

    /// protects: a leg whose end fix already carries evidence is left out.
    /// fails_when: known evidence is re-read.
    /// no_claim: the store's own guard (`knownEvidenceIsNotOverwrittenByADifferentAnswer`).
    @Test func aKnownLegIsLeftOut() {
        var known = Self.pair
        known[1].ride = .walking
        let ride = VehicleActivity(intervals: [Self.coverage], coverage: Self.coverage)
        #expect(BlockMatcher.evidence(known, activity: ride).isEmpty)
    }

    /// protects: `isCreditableLeg` reads the end fix's evidence before the
    /// pass's activity: `.ride` credits nothing with no activity, `.walking`
    /// credits even when the activity says ride, and the speed rule still
    /// applies either way.
    /// fails_when: saved evidence is ignored, or `.walking` lifts the speed
    /// or length rules.
    /// no_claim: CoreMotion's classification.
    @Test func endEvidenceDecidesBeforeActivity() {
        let slow = F.walk(from: (0, 0), to: (100, 0), speed: 3)
        let grid = F.loneBlockGrid()
        func marked(_ ride: RideEvidence, _ walk: [WalkedPointSnapshot]) -> [WalkedPointSnapshot] {
            walk.map { var point = $0; point.ride = ride; return point }
        }
        #expect(BlockMatcher.match(marked(.ride, slow), grid: grid, activity: .unavailable).isEmpty)
        let sawRide = VehicleActivity(intervals: [Self.coverage], coverage: Self.coverage)
        #expect(BlockMatcher.isWalked(mask: BlockMatcher.match(marked(.walking, slow), grid: grid, activity: sawRide)[100] ?? 0))
        let taxi = F.walk(from: (0, 0), to: (100, 0), speed: 12)
        #expect(BlockMatcher.match(marked(.walking, taxi), grid: grid).isEmpty)
    }
}
