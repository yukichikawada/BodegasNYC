//
//  AddCompletionCoordinatorTests.swift
//  BodegasNYCTests
//
//  The after-add choreography (#25, eng review R9, design DD11/DD15),
//  driven by a manual clock and a `FirstRunState` on a scratch
//  `UserDefaults` suite. The coordinator's closures record into one event
//  log, so ordering is asserted directly.
//
//  protects: insert happens before the camera moves; the pin drops only
//  after the camera settles on it (or the 0.65 s fallback), with the haptic;
//  the card appears only on the first add, 0.6 s after the drop; a second
//  add shows no card; cancelling after the insert skips the card and haptic
//  and clears only its own id; a second add is never cleared by the first
//  add's timers; the announcement is posted on every add; auto-dismiss is
//  off under VoiceOver.
//  fails_when: any of those orderings or guards breaks.
//  no_claim: the spring, the camera animation, or that the haptic is felt
//  (the simulator can't; `.sensoryFeedback` is bound to `hapticTrigger` in
//  `BrowseView`, checked in review).
//

import Foundation
import Testing

@testable import BodegasNYC

/// A clock that only moves when the test says so. Sleepers are resumed by
/// `advance(by:)`; a cancelled sleeper throws `CancellationError` at once.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []

    var now: Instant { lock.withLock { currentInstant } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool = lock.withLock {
                    if deadline <= currentInstant { return true }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            currentInstant = currentInstant.advanced(by: duration)
            let due = sleepers.filter { $0.deadline <= currentInstant }
            sleepers.removeAll { $0.deadline <= currentInstant }
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

@MainActor
@Suite(.serialized)
final class AddCompletionCoordinatorTests {
    enum Event: Equatable {
        case insert(String)
        case highlight(String?)
        case camera(String)
        case announce(String)
        case firstAdd
    }

    private let suiteName = "AddCompletionCoordinatorTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let clock = ManualClock()
    private var events: [Event] = []
    private var voiceOver = false
    private var names: [UUID: String] = [:]

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeCoordinator(firstRunState: FirstRunState? = nil) -> AddCompletionCoordinator {
        let state = firstRunState ?? FirstRunState(userDefaults: defaults)
        return AddCompletionCoordinator(
            firstRunState: state,
            insert: { [unowned self] in events.append(.insert($0.name)) },
            moveCamera: { [unowned self] coordinate in
                events.append(.camera("\(coordinate.latitude),\(coordinate.longitude)"))
            },
            setHighlighted: { [unowned self] id in events.append(.highlight(id.flatMap { names[$0] })) },
            isVoiceOverRunning: { [unowned self] in voiceOver },
            announce: { [unowned self] in events.append(.announce($0)) },
            onFirstAdd: { [unowned self] in events.append(.firstAdd) },
            clock: clock
        )
    }

    private func bodega(_ name: String, hasCat: Bool = false, latitude: Double = 40.73) throws -> Bodega {
        let bodega = try makeTestBodega(name: name, latitude: latitude, longitude: -73.99, hasCat: hasCat)
        names[bodega.id] = name
        return bodega
    }

    /// Lets tasks resumed by the clock (or just created) run on the main
    /// actor until one is parked on the clock again.
    private func waitForSleeper() async {
        for _ in 0..<200 where clock.sleeperCount == 0 {
            await Task.yield()
        }
    }

    private func drain() async {
        for _ in 0..<50 { await Task.yield() }
    }

    private func advance(_ duration: Duration) async {
        await waitForSleeper()
        clock.advance(by: duration)
        await drain()
    }

    // MARK: Ordering

    @Test func insertHappensBeforeTheCameraMovesAndAllOfItSynchronously() throws {
        let coordinator = makeCoordinator()
        let deli = try bodega("Deli")

        coordinator.bodegaWasSubmitted(deli)

        #expect(events == [
            .insert("Deli"),
            .highlight("Deli"),
            .firstAdd,
            .announce("Deli is on the map."),
            .camera("40.73,-73.99")
        ])
        #expect(coordinator.dropState == .pending(deli.id))
        #expect(coordinator.pinPhase(for: deli.id) == .pending)
        #expect(coordinator.hapticTrigger == 0)
        #expect(coordinator.firstAddCard == nil)
    }

    @Test func theDropWaitsForTheCameraToSettleOnThePin() async throws {
        let coordinator = makeCoordinator()
        let deli = try bodega("Deli")
        coordinator.bodegaWasSubmitted(deli)

        // A settle somewhere else (an earlier camera move) doesn't count.
        coordinator.cameraDidSettle(center: Coordinate(latitude: 40.70, longitude: -74.01))
        #expect(coordinator.dropState == .pending(deli.id))
        #expect(coordinator.hapticTrigger == 0)

        coordinator.cameraDidSettle(center: deli.coordinate)
        #expect(coordinator.dropState == .dropping(deli.id))
        #expect(coordinator.pinPhase(for: deli.id) == .dropping)
        #expect(coordinator.hapticTrigger == 1)

        // The fallback no longer fires a second drop or haptic.
        await advance(.seconds(1))
        #expect(coordinator.hapticTrigger == 1)
    }

    @Test func theDropFallsBackAfterSixtyFiveHundredthsOfASecond() async throws {
        let coordinator = makeCoordinator()
        let deli = try bodega("Deli")
        coordinator.bodegaWasSubmitted(deli)

        await advance(.milliseconds(600))
        #expect(coordinator.dropState == .pending(deli.id))
        #expect(coordinator.hapticTrigger == 0)

        await advance(.milliseconds(50))
        #expect(coordinator.dropState == .dropping(deli.id))
        #expect(coordinator.hapticTrigger == 1)
    }

    // MARK: First-add card

    @Test func theCardComesOnlyOnTheFirstAddAndOnlyAfterTheDelay() async throws {
        let coordinator = makeCoordinator()
        let deli = try bodega("Deli", hasCat: true)
        coordinator.bodegaWasSubmitted(deli)
        coordinator.cameraDidSettle(center: deli.coordinate)

        await advance(.milliseconds(599))
        #expect(coordinator.firstAddCard == nil)
        await advance(.milliseconds(1))
        #expect(coordinator.firstAddCard?.id == deli.id)
        #expect(coordinator.firstAddCard?.hasCat == true)

        // 1.5 s after the drop: drop state and highlight clear, card stays.
        await advance(.milliseconds(900))
        #expect(coordinator.dropState == .none)
        #expect(events.last == .highlight(nil))
        #expect(coordinator.firstAddCard?.id == deli.id)
    }

    @Test func aSecondAddShowsNoCard() async throws {
        let firstRunState = FirstRunState(userDefaults: defaults)
        let coordinator = makeCoordinator(firstRunState: firstRunState)
        let first = try bodega("First")
        coordinator.bodegaWasSubmitted(first)
        coordinator.cameraDidSettle(center: first.coordinate)
        await advance(.milliseconds(600))
        coordinator.dismissFirstAddCard()
        await advance(.milliseconds(900))

        let second = try bodega("Second", latitude: 40.75)
        events = []
        coordinator.bodegaWasSubmitted(second)
        #expect(!events.contains(.firstAdd))
        coordinator.cameraDidSettle(center: second.coordinate)
        #expect(coordinator.hapticTrigger == 2)
        await advance(.seconds(2))

        #expect(coordinator.firstAddCard == nil)
        #expect(coordinator.dropState == .none)
    }

    @Test func aRelaunchedDeviceThatAlreadyAddedShowsNoCard() async throws {
        FirstRunState(userDefaults: defaults).markFirstBodegaAdded()
        let coordinator = makeCoordinator()
        let deli = try bodega("Deli")

        coordinator.bodegaWasSubmitted(deli)
        coordinator.cameraDidSettle(center: deli.coordinate)
        await advance(.seconds(2))

        #expect(!events.contains(.firstAdd))
        #expect(coordinator.firstAddCard == nil)
        #expect(coordinator.hapticTrigger == 1)
    }

    @Test func theCardAutoDismissesEightSecondsAfterItsTransition() async throws {
        let coordinator = makeCoordinator()
        let deli = try bodega("Deli")
        coordinator.bodegaWasSubmitted(deli)
        coordinator.cameraDidSettle(center: deli.coordinate)
        await advance(.milliseconds(600))
        #expect(coordinator.firstAddCard != nil)

        await advance(.milliseconds(900))  // the 1.5 s clear
        await advance(.milliseconds(7349))  // 8.25 s after the card, less 1 ms
        #expect(coordinator.firstAddCard != nil)
        await advance(.milliseconds(1))
        #expect(coordinator.firstAddCard == nil)
    }

    @Test func autoDismissIsOffUnderVoiceOver() async throws {
        voiceOver = true
        let coordinator = makeCoordinator()
        let deli = try bodega("Deli")
        coordinator.bodegaWasSubmitted(deli)
        coordinator.cameraDidSettle(center: deli.coordinate)
        await advance(.milliseconds(600))
        await advance(.milliseconds(900))
        await drain()
        clock.advance(by: .seconds(60))
        await drain()

        #expect(coordinator.firstAddCard?.id == deli.id)
        coordinator.dismissFirstAddCard()
        #expect(coordinator.firstAddCard == nil)
    }

    // MARK: Cancellation and ownership

    @Test func cancelAfterTheInsertSkipsTheHapticAndCardAndClearsItsOwnID() async throws {
        let coordinator = makeCoordinator()
        let deli = try bodega("Deli")
        coordinator.bodegaWasSubmitted(deli)

        coordinator.cancel()

        #expect(events.first == .insert("Deli"))
        #expect(coordinator.dropState == .none)
        #expect(events.last == .highlight(nil))
        coordinator.cameraDidSettle(center: deli.coordinate)
        clock.advance(by: .seconds(10))
        await drain()
        #expect(coordinator.hapticTrigger == 0)
        #expect(coordinator.firstAddCard == nil)
        // The first add was still recorded; it is not offered again.
        #expect(FirstRunState(userDefaults: defaults).hasAddedFirstBodega)
    }

    @Test func cancelWhileTheCardIsUpDismissesItAndClearsTheDrop() async throws {
        let coordinator = makeCoordinator()
        let deli = try bodega("Deli")
        coordinator.bodegaWasSubmitted(deli)
        coordinator.cameraDidSettle(center: deli.coordinate)
        await advance(.milliseconds(600))
        #expect(coordinator.firstAddCard != nil)
        #expect(coordinator.dropState == .dropping(deli.id))

        coordinator.cancel()

        #expect(coordinator.firstAddCard == nil)
        #expect(coordinator.dropState == .none)
        #expect(events.last == .highlight(nil))
    }

    @Test func aSecondAddIsNeverClearedByTheFirstAddsTimers() async throws {
        let coordinator = makeCoordinator()
        let first = try bodega("First")
        let second = try bodega("Second", latitude: 40.75)
        coordinator.bodegaWasSubmitted(first)
        coordinator.cameraDidSettle(center: first.coordinate)
        await advance(.milliseconds(1000))

        // Submitted 0.5 s before the first add's 1.5 s clear would fire.
        coordinator.bodegaWasSubmitted(second)
        #expect(coordinator.dropState == .pending(second.id))
        await drain()
        clock.advance(by: .milliseconds(500))
        await drain()

        #expect(coordinator.dropState != .none)
        #expect(coordinator.dropState.bodegaID == second.id)
        #expect(events.last != .highlight(nil))

        coordinator.cameraDidSettle(center: second.coordinate)
        #expect(coordinator.dropState == .dropping(second.id))
        await advance(.milliseconds(1500))
        #expect(coordinator.dropState == .none)
    }

    @Test func theAnnouncementIsPostedOnEveryAdd() throws {
        let coordinator = makeCoordinator()
        coordinator.bodegaWasSubmitted(try bodega("Deli"))
        coordinator.bodegaWasSubmitted(try bodega("Corner Store", latitude: 40.75))

        let announcements = events.compactMap { event -> String? in
            if case .announce(let text) = event { return text }
            return nil
        }
        #expect(announcements == ["Deli is on the map.", "Corner Store is on the map."])
        #expect(events.filter { $0 == .firstAdd }.count == 1)
    }

    @Test func otherPinsStayAtRest() throws {
        let coordinator = makeCoordinator()
        let deli = try bodega("Deli")
        let other = try bodega("Other", latitude: 40.75)
        coordinator.bodegaWasSubmitted(deli)

        #expect(coordinator.pinPhase(for: other.id) == .atRest)
    }
}
