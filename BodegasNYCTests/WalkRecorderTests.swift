//
//  WalkRecorderTests.swift
//  BodegasNYCTests
//
//  `WalkRecorder` (#123) driven by a scripted `WalkLocationBackend`
//  (`FakeWalkBackend`) and an injected authorization status, over an
//  in-memory store. The live backend's producer is exercised with an
//  injected producer and session taker, never real Core Location: whether
//  iOS keeps a real phone's updates going is the owner's device walk
//  (spec AC 9).
//

import CoreLocation
import Foundation
import SwiftData
import Testing

@testable import BodegasNYC

/// A scripted backend. `stop()` deliberately leaves the stream open, so a
/// test can prove the recorder itself drops what arrives after a stop.
@MainActor
final class FakeWalkBackend: WalkLocationBackend {
    private(set) var starts = 0
    private(set) var stops = 0
    private var continuation: AsyncStream<WalkUpdate>.Continuation?

    func start() -> AsyncStream<WalkUpdate> {
        starts += 1
        let (stream, continuation) = AsyncStream.makeStream(of: WalkUpdate.self)
        self.continuation = continuation
        return stream
    }

    func stop() {
        stops += 1
    }

    func send(_ update: WalkUpdate) {
        continuation?.yield(update)
    }

    func send(_ locations: [CLLocation]) {
        for location in locations { send(WalkUpdate(location: location)) }
    }

    /// The stream ends on its own, as a real one might.
    func endStream() {
        continuation?.finish()
    }
}

@MainActor
final class AuthorizationBox {
    var status: CLAuthorizationStatus
    init(_ status: CLAuthorizationStatus) { self.status = status }
}

/// Counts producers that are running (started, not yet cancelled).
final class ProducerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _active = 0
    private var _started = 0
    var active: Int { lock.withLock { _active } }
    var started: Int { lock.withLock { _started } }
    func begin() { lock.withLock { _active += 1; _started += 1 } }
    func end() { lock.withLock { _active -= 1 } }
}

/// Polls `condition` on the main actor for up to 2 s.
@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0 ..< 2_000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Fixes due north of a Midtown corner, `meters` along the meridian.
enum WalkFixes {
    static let origin = CLLocationCoordinate2D(latitude: 40.7505, longitude: -73.9934)
    /// Measured once over 0.001° so offsets match `CLLocation.distance`.
    static let metersPerDegree: Double = {
        let start = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let end = CLLocation(latitude: origin.latitude + 0.001, longitude: origin.longitude)
        return start.distance(from: end) / 0.001
    }()

    static func fix(north meters: Double, accuracy: CLLocationAccuracy = 10, at timestamp: Date) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: origin.latitude + meters / metersPerDegree,
                longitude: origin.longitude
            ),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 10,
            timestamp: timestamp
        )
    }
}

@Suite
@MainActor
struct WalkRecorderTests {
    private static let now = Date(timeIntervalSince1970: 1_900_000_000)

    @MainActor
    private struct Harness {
        let recorder: WalkRecorder
        let backend: FakeWalkBackend
        let auth: AuthorizationBox
        let defaults: UserDefaults
        let context: ModelContext

        func savedCount() throws -> Int {
            try context.fetchCount(FetchDescriptor<WalkedPoint>())
        }

        /// Sends and waits until the recorder has handled every update.
        func deliver(_ updates: [WalkUpdate]) async {
            let target = recorder.handledUpdateCount + updates.count
            for update in updates { backend.send(update) }
            await waitUntil { recorder.handledUpdateCount >= target }
        }

        func deliver(_ locations: [CLLocation]) async {
            await deliver(locations.map { WalkUpdate(location: $0) })
        }
    }

    private func makeHarness(
        status: CLAuthorizationStatus = .authorizedAlways,
        intent: Bool = false
    ) throws -> Harness {
        let container = try makeInMemoryModelContainer()
        let defaults = try #require(UserDefaults(suiteName: "WalkRecorderTests.\(UUID().uuidString)"))
        defaults.set(intent, forKey: WalkRecorder.trackingEnabledDefaultsKey)
        let backend = FakeWalkBackend()
        let auth = AuthorizationBox(status)
        let recorder = WalkRecorder(
            modelContainer: container,
            userDefaults: defaults,
            authorizationStatus: { auth.status },
            backend: backend,
            now: { Self.now }
        )
        return Harness(recorder: recorder, backend: backend, auth: auth, defaults: defaults, context: container.mainContext)
    }

    private static func fix(north meters: Double, accuracy: CLLocationAccuracy = 10, age: TimeInterval = 0) -> CLLocation {
        WalkFixes.fix(north: meters, accuracy: accuracy, at: now.addingTimeInterval(-age))
    }

    // MARK: Launch (AC 1, 2, 3)

    /// protects=a launch with the intent saved and Always granted starts
    /// recording once, the call `didFinishLaunching` makes before it returns
    /// (AC 1); fails_when=the guard is inverted or the start is skipped, or
    /// a second resume starts a second backend; no_claim=the AppDelegate
    /// wiring and iOS relaunching the app (QA code read, Simulator log line,
    /// device walk); the backend is a fake.
    @Test func resumeStartsOnceWithIntentAndAlways() throws {
        let harness = try makeHarness(intent: true)

        harness.recorder.resumeIfPreviouslyEnabled(isBackgroundLaunch: true)
        harness.recorder.resumeIfPreviouslyEnabled(isBackgroundLaunch: true)

        #expect(harness.backend.starts == 1)
        #expect(harness.recorder.isRecording)
    }

    /// protects=no intent, or no Always, means no sessions and no update
    /// loop at launch (AC 2); fails_when=either condition alone starts the
    /// backend; no_claim=what the system does with a session taken without
    /// Always (never taken here).
    @Test(arguments: [(false, CLAuthorizationStatus.authorizedAlways), (true, .authorizedWhenInUse), (true, .denied)])
    func resumeDoesNothingWithoutIntentOrAlways(intent: Bool, status: CLAuthorizationStatus) throws {
        let harness = try makeHarness(status: status, intent: intent)

        harness.recorder.resumeIfPreviouslyEnabled()

        #expect(harness.backend.starts == 0)
        #expect(harness.recorder.isRecording == false)
    }

    /// protects=Start without Always throws and changes nothing (AC 3);
    /// fails_when=it records, or saves the intent, under While Using;
    /// no_claim=the permission prompts (MapScreenView, QA).
    @Test func startWithoutAlwaysThrowsAndChangesNothing() throws {
        let harness = try makeHarness(status: .authorizedWhenInUse)

        #expect(throws: WalkRecorder.RecorderError.authorizationNotGranted) {
            try harness.recorder.start()
        }

        #expect(harness.recorder.isRecording == false)
        #expect(harness.recorder.isEnabled == false)
        #expect(harness.backend.starts == 0)
    }

    // MARK: Filtering (AC 4)

    /// protects=storage grows as before: only fixes accurate to 50 m, at most
    /// 30 s old and 15 m from the last saved fix are kept, and the first fix
    /// after a fresh recorder always is (AC 4, decision D2); fails_when=the
    /// spacing is measured from the last received fix instead of the last
    /// saved, or the first fix is dropped; no_claim=the exact 15 m boundary
    /// (the pure-function tests below); the fixes are 5.0001 m apart so
    /// floating-point rounding cannot put the 15 m fix a hair short.
    @Test func tenFixesFiveMetresApartSaveFour() async throws {
        let harness = try makeHarness()
        try harness.recorder.start()

        await harness.deliver((0 ..< 10).map { Self.fix(north: Double($0) * 5.0001) })

        let saved = try harness.context.fetch(FetchDescriptor<WalkedPoint>(sortBy: [SortDescriptor(\.latitude)]))
        let north = saved.map { ($0.latitude - WalkFixes.origin.latitude) * WalkFixes.metersPerDegree }
        #expect(north.map { ($0 / 15).rounded() } == [0, 1, 2, 3])
    }

    /// protects=the fix filter moved from the view model unchanged: over
    /// 50 m, no accuracy (-1) or older than 30 s is never stored;
    /// fails_when=the filter was lost in the move; no_claim=none beyond
    /// protects.
    @Test func inaccurateOrStaleFixesAreDropped() async throws {
        let harness = try makeHarness()
        try harness.recorder.start()

        await harness.deliver([
            Self.fix(north: 0, accuracy: 200),
            Self.fix(north: 20, accuracy: -1),
            Self.fix(north: 40, age: 31),
            Self.fix(north: 60, accuracy: 50, age: 30)
        ])

        #expect(try harness.savedCount() == 1)
    }

    // MARK: Stationary (AC 5)

    /// protects=recording resumes after a stationary pause with no restart
    /// (AC 5); fails_when=the loop stops, or stops saving, once an update
    /// says stationary; no_claim=iOS resuming deliveries on a real phone
    /// (device walk); the stream is scripted.
    @Test func fixesAfterAStationaryPauseSaveWithoutARestart() async throws {
        let harness = try makeHarness()
        try harness.recorder.start()
        await harness.deliver([Self.fix(north: 0), Self.fix(north: 20)])

        await harness.deliver([
            WalkUpdate(location: nil, isStationary: true),
            WalkUpdate(location: nil, isStationary: true),
            WalkUpdate(location: Self.fix(north: 40), isStationary: false),
            WalkUpdate(location: Self.fix(north: 60), isStationary: false)
        ])

        #expect(try harness.savedCount() == 4)
        #expect(harness.backend.starts == 1)
    }

    // MARK: Stop and start (AC 6, 7)

    /// protects=Stop gives the sessions up, ends the loop (nothing saved for
    /// fixes still arriving) and clears the intent; a second Stop does
    /// nothing (AC 6); fails_when=fixes after Stop are stored, the backend
    /// is stopped twice, or the intent survives; no_claim=Core Location
    /// honouring `invalidate()` (live backend test below for the producer).
    @Test func stopEndsTheLoopAndClearsTheIntent() async throws {
        let harness = try makeHarness()
        try harness.recorder.start()
        await harness.deliver([Self.fix(north: 0)])

        harness.recorder.stop()
        harness.backend.send([Self.fix(north: 50)])
        harness.backend.send([Self.fix(north: 100)])
        try await Task.sleep(for: .milliseconds(50))
        harness.recorder.stop()

        #expect(try harness.savedCount() == 1)
        #expect(harness.backend.stops == 1)
        #expect(harness.recorder.isRecording == false)
        #expect(harness.recorder.isEnabled == false)
    }

    /// protects=Start twice takes one set of sessions and one loop (AC 7);
    /// fails_when=a second Start starts the backend again (two loops saving
    /// every fix twice); no_claim=none beyond protects.
    @Test func startTwiceStartsOneBackend() async throws {
        let harness = try makeHarness()

        try harness.recorder.start()
        try harness.recorder.start()
        await harness.deliver([Self.fix(north: 0)])

        #expect(harness.backend.starts == 1)
        #expect(try harness.savedCount() == 1)
    }

    // MARK: Problems (AC 8)

    /// protects=a denial while recording is reported once, with the intent
    /// and recording kept, so it resumes by itself if Always comes back
    /// (AC 8); fails_when=the error is re-set by each delivery (the banner
    /// flickers back after a dismiss), or the denial clears the intent;
    /// no_claim=the final copy (design review).
    @Test func aDenialIsReportedOnceAndKeepsTheIntent() async throws {
        let harness = try makeHarness()
        try harness.recorder.start()

        await harness.deliver([WalkUpdate(location: nil, problem: .denied)])
        #expect(harness.recorder.lastError != nil)
        harness.recorder.dismissError()
        await harness.deliver([WalkUpdate(location: nil, problem: .denied)])

        #expect(harness.recorder.lastError == nil)
        #expect(harness.recorder.isRecording)
        #expect(harness.recorder.isEnabled)
    }

    // MARK: Activation (eng O1, R1, R2)

    /// protects=a loop that ended by itself is restarted on the next scene
    /// activation, and the next fix saves (eng O1); fails_when=activation
    /// treats the saved intent as a running loop and does nothing;
    /// no_claim=why a real stream would end.
    @Test func aDeadLoopRestartsOnActivation() async throws {
        let harness = try makeHarness()
        try harness.recorder.start()
        harness.backend.endStream()
        await waitUntil { !harness.recorder.isLoopAlive }
        #expect(harness.recorder.isRecording)

        harness.recorder.resync()
        await harness.deliver([Self.fix(north: 0)])

        #expect(harness.backend.starts == 2)
        #expect(try harness.savedCount() == 1)
    }

    /// protects=sessions stalled on `insufficientlyInUse` after a relaunch
    /// are rebuilt once, in the foreground (eng R2); fails_when=the
    /// diagnostic is ignored, or every activation rebuilds; no_claim=iOS 26
    /// actually emitting it.
    @Test func insufficientlyInUseRebuildsOnceOnActivation() async throws {
        let harness = try makeHarness()
        try harness.recorder.start()
        await harness.deliver([WalkUpdate(location: nil, diagnostics: [.insufficientlyInUse])])

        harness.recorder.resync()
        #expect(harness.backend.stops == 1)
        #expect(harness.backend.starts == 2)

        harness.recorder.resync()
        #expect(harness.backend.starts == 2)
    }

    /// protects=losing Always while recording pauses on the next activation
    /// with the intent kept and one error, the same state a relaunch would
    /// reach; Always coming back resumes (eng R1); fails_when=it keeps
    /// recording under While Using, clears the intent, re-sets the error on
    /// each activation, or does not resume; no_claim=the Settings flow.
    @Test func losingAlwaysPausesAndRegainingItResumes() async throws {
        let harness = try makeHarness()
        try harness.recorder.start()

        harness.auth.status = .authorizedWhenInUse
        harness.recorder.resync()
        #expect(harness.backend.stops == 1)
        #expect(harness.recorder.isRecording == false)
        #expect(harness.recorder.isEnabled)
        #expect(harness.recorder.lastError != nil)
        harness.recorder.dismissError()
        harness.recorder.resync()
        #expect(harness.recorder.lastError == nil)

        harness.auth.status = .authorizedAlways
        harness.recorder.resync()
        await harness.deliver([Self.fix(north: 0)])
        #expect(harness.backend.starts == 2)
        #expect(harness.recorder.isRecording)
        #expect(try harness.savedCount() == 1)
    }

    // MARK: Live backend (eng O3)

    /// protects=Stop then Start leaves exactly one live producer, and Stop
    /// gives up the sessions (eng O3); fails_when=`onTermination` does not
    /// cancel the producer, so toggling leaks producers; no_claim=live
    /// `CLLocationUpdate` cancellation (the producer here is injected).
    @Test func liveBackendStopThenStartLeavesOneProducer() async throws {
        let counter = ProducerCounter()
        var invalidations = 0
        let backend = LiveWalkLocationBackend(
            takeSessions: { { invalidations += 1 } },
            produce: { _ in
                counter.begin()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                counter.end()
            }
        )

        let first = backend.start()
        await waitUntil { counter.started == 1 }
        backend.stop()
        let second = backend.start()
        await waitUntil { counter.started == 2 && counter.active == 1 }

        #expect(counter.active == 1)
        #expect(invalidations == 1)
        backend.stop()
        await waitUntil { counter.active == 0 }
        #expect(counter.active == 0)
        #expect(invalidations == 2)
        // The recorder holds its stream; dropping one ends it (and its
        // producer) by itself, which would hide a missing cancellation.
        withExtendedLifetime((first, second)) {}
    }

    // MARK: Spacing (pure, decision D2)

    // protects=the 15 m spacing rule, the boundary included, and the first
    // fix after launch; fails_when=the threshold is off by one (> instead
    // of >=) or a nil last fix drops the first; no_claim=none beyond protects.

    @Test func spacingKeepsTheFirstFix() {
        #expect(WalkRecorder.keepsFix(distanceFromLastSaved: nil))
    }

    @Test func spacingDropsAFixUnder15Metres() {
        #expect(WalkRecorder.keepsFix(distanceFromLastSaved: 14.99) == false)
    }

    @Test func spacingKeepsAFixAt15Metres() {
        #expect(WalkRecorder.keepsFix(distanceFromLastSaved: 15))
    }

    @Test func spacingKeepsAFixOver15Metres() {
        #expect(WalkRecorder.keepsFix(distanceFromLastSaved: 15.01))
    }
}
