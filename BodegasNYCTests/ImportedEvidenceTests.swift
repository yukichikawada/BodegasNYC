//
//  ImportedEvidenceTests.swift
//  BodegasNYCTests
//
//  #180 PR 2, eng E2: `RideEvidence.imported`, the evidence of a fix
//  imported with none. Another phone recorded it, so this phone's
//  CoreMotion is never asked about its leg, no pass overwrites it, and its
//  day is an estimate at any age. The three existing values behave as
//  before (RideEvidenceTests, unchanged).
//

import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

@MainActor
struct ImportedEvidenceTests {
    private typealias F = StreetFixtures

    private static func at(_ seconds: TimeInterval) -> Date { F.baseDate.addingTimeInterval(seconds) }

    /// Block 300 at 3 m/s from t = 600 s: under the speed cap, so only
    /// CoreMotion could call it a ride.
    private static func slowLeg(_ ride: RideEvidence) -> [WalkedPointSnapshot] {
        F.walk(from: (0, 68), to: (100, 68), speed: 3, startTime: 600).map { snapshot in
            var marked = snapshot
            marked.ride = ride
            return marked
        }
    }

    /// CoreMotion, covering the whole walk and seeing a ride over it.
    private static let rideActivity = VehicleActivity(
        intervals: [DateInterval(start: at(0), end: at(2_000))],
        coverage: DateInterval(start: at(-60), end: at(3_000))
    )

    /// protects=E2: an imported leg is judged by the speed rule alone: a
    /// ride this phone's CoreMotion reports over it does not stop it, and a
    /// leg too fast to walk is still refused; an unknown leg in the same
    /// place is still filtered by the activity (unchanged); fails_when=this
    /// phone's CoreMotion decides another phone's legs, or `.imported`
    /// skips the speed rule; no_claim=CoreMotion itself (fake activity).
    @Test func anImportedLegIsJudgedBySpeedOnly() {
        let grid = F.cornerGrid()
        let imported = BlockMatcher.match(Self.slowLeg(.imported), grid: grid, activity: Self.rideActivity)
        #expect(BlockMatcher.isWalked(mask: imported[300] ?? 0))
        let unknown = BlockMatcher.match(Self.slowLeg(.unknown), grid: grid, activity: Self.rideActivity)
        #expect(unknown[300] == nil)
        let fast = F.walk(from: (0, 68), to: (100, 68), speed: 6).map { snapshot in
            var marked = snapshot
            marked.ride = .imported
            return marked
        }
        #expect(BlockMatcher.match(fast, grid: grid, activity: .unavailable)[300] == nil)
    }

    /// protects=E2: `evidence` never answers for an imported end fix, and a
    /// rebuild with CoreMotion covering it leaves the stored `.imported` as
    /// it is; fails_when=a covered imported leg is saved as `.walking` or
    /// `.ride` (the new phone certifying walks it never saw);
    /// no_claim=unknown legs (RideEvidenceTests).
    @Test func importedEvidenceIsNeverOverwritten() throws {
        #expect(BlockMatcher.evidence(Self.slowLeg(.imported), activity: Self.rideActivity).isEmpty)

        let container = try makeInMemoryModelContainer()
        for snapshot in Self.slowLeg(.imported) {
            let point = WalkedPoint(
                id: snapshot.id,
                latitude: snapshot.coordinate.latitude,
                longitude: snapshot.coordinate.longitude,
                recordedAt: snapshot.recordedAt
            )
            point.ride = .imported
            container.mainContext.insert(point)
        }
        try container.mainContext.save()
        let now = Self.at(3_600)
        let store = WalkedBlockStore(container: container, grid: F.cornerGrid(), now: { now })
        let plan = try #require(try store.plan())
        #expect(plan.kind == .rebuild)
        #expect(try store.apply(plan, activity: Self.rideActivity) { true })
        let points = try ModelContext(container).fetch(FetchDescriptor<WalkedPoint>())
        #expect(points.allSatisfy { $0.ride == .imported })
    }

    /// protects=E2: the newest imported fix makes its day an estimate at
    /// any age, even inside CoreMotion's 7 days and even after a newer
    /// fix with evidence, while a recent unknown fix still does not;
    /// fails_when=a restored day from last week reads as definite, or the
    /// rule for unknown fixes changes; no_claim=the calendar's line
    /// (YourWalksTests).
    @Test func anImportedDayIsAnEstimateAtAnyAge() {
        let now = Self.at(3_600)
        var walk = F.walk(from: (0, 12), to: (100, 12))
        walk[3].ride = .imported
        for index in 4 ..< walk.count { walk[index].ride = .walking }
        #expect(WalkedEstimate.throughDay(walk, found: [:], now: now) == WalkedDayKey(date: walk[3].recordedAt))

        let recentUnknown = F.walk(from: (0, 12), to: (100, 12))
        #expect(WalkedEstimate.throughDay(recentUnknown, found: [:], now: now) == nil)
        #expect(RideEvidence(rawValue: 3) == .imported)
    }

    /// protects=#180 design D8 (the intro yields): a waiting or running
    /// import keeps the Streets Walked intro from presenting, like a shared
    /// walk; fails_when=the intro covers an opened file; no_claim=the
    /// sheet's presentation itself (UI test).
    @Test func aWaitingHistoryFileHoldsTheIntro() {
        var inputs = StreetsWalkedIntro.Inputs(
            hasSeenIntro: false, isForeground: true, isSceneActive: true, isPlacingBodega: false,
            isFirstAddInProgress: false, isOwnSheetUp: false, isAwaitingLocationPrompt: false,
            isCameraMoving: false, recordingState: .off, hasHistory: false
        )
        #expect(StreetsWalkedIntro.shouldOffer(inputs))
        inputs.isHistoryFilePending = true
        #expect(!StreetsWalkedIntro.shouldOffer(inputs))
    }
}
