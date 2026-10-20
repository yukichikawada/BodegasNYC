//
//  FirstRunStateTests.swift
//  BodegasNYCTests
//
//  `FirstRunState`'s two persisted flags and the onboarding gate (spec AC 2
//  and the pure-logic half of AC 8). A fresh `FirstRunState` over the same
//  `UserDefaults` suite stands in for a relaunch.
//
//  protects: both flags persist; `markFirstBodegaAdded` flips exactly once
//  per suite; replaying onboarding never resets the first-add flag;
//  `shouldShowOnboarding` is the negation of completion, which `RootView`
//  seeds its overlay from at init.
//  fails_when: a flag fails to persist, flips twice, or replay resets it.
//  no_claim: UI; `UserDefaults(suiteName:)` stands in for `.standard`.
//

import Foundation
import Testing

@testable import BodegasNYC

@MainActor
struct FirstRunStateTests {
    /// A fresh, empty suite per test, removed when the test ends.
    private static func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "FirstRunStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test func freshSuiteDefaultsEverythingToFalse() throws {
        try Self.withSuite { defaults in
            let state = FirstRunState(userDefaults: defaults)
            #expect(state.hasCompletedOnboarding == false)
            #expect(state.hasAddedFirstBodega == false)
            #expect(state.pendingTutorialAdd == false)
            #expect(state.shouldShowOnboarding == true)
        }
    }

    @Test(arguments: [true, false])
    func completeOnboardingPersistsAndSetsPendingAdd(wantsToAdd: Bool) throws {
        try Self.withSuite { defaults in
            let state = FirstRunState(userDefaults: defaults)
            state.completeOnboarding(wantsToAdd: wantsToAdd)

            #expect(state.hasCompletedOnboarding == true)
            #expect(state.shouldShowOnboarding == false)
            #expect(state.pendingTutorialAdd == wantsToAdd)

            let relaunched = FirstRunState(userDefaults: defaults)
            #expect(relaunched.hasCompletedOnboarding == true)
            #expect(relaunched.shouldShowOnboarding == false)
            // Not persisted: a relaunch never resumes a pending add.
            #expect(relaunched.pendingTutorialAdd == false)
            // Completing onboarding says nothing about adding.
            #expect(relaunched.hasAddedFirstBodega == false)
        }
    }

    @Test func markFirstBodegaAddedReturnsTrueExactlyOncePerSuite() throws {
        try Self.withSuite { defaults in
            let state = FirstRunState(userDefaults: defaults)
            #expect(state.markFirstBodegaAdded() == true)
            #expect(state.hasAddedFirstBodega == true)
            #expect(state.markFirstBodegaAdded() == false)
            #expect(state.hasAddedFirstBodega == true)

            let relaunched = FirstRunState(userDefaults: defaults)
            #expect(relaunched.hasAddedFirstBodega == true)
            #expect(relaunched.markFirstBodegaAdded() == false)
        }
    }

    @Test func replayingOnboardingDoesNotResetFirstAdd() throws {
        try Self.withSuite { defaults in
            let state = FirstRunState(userDefaults: defaults)
            state.completeOnboarding(wantsToAdd: false)
            state.markFirstBodegaAdded()

            // Replay: Show Intro Again, then finish on either path.
            state.completeOnboarding(wantsToAdd: true)
            #expect(state.hasAddedFirstBodega == true)
            #expect(state.hasCompletedOnboarding == true)
            #expect(state.markFirstBodegaAdded() == false)

            let relaunched = FirstRunState(userDefaults: defaults)
            #expect(relaunched.hasAddedFirstBodega == true)
        }
    }

    @Test func shouldShowOnboardingFollowsThePersistedFlag() throws {
        try Self.withSuite { defaults in
            #expect(FirstRunState(userDefaults: defaults).shouldShowOnboarding == true)
            defaults.set(true, forKey: FirstRunState.hasCompletedOnboardingKey)
            #expect(FirstRunState(userDefaults: defaults).shouldShowOnboarding == false)
            defaults.set(false, forKey: FirstRunState.hasCompletedOnboardingKey)
            #expect(FirstRunState(userDefaults: defaults).shouldShowOnboarding == true)
        }
    }

    @Test func storageKeysMatchTheSpec() {
        #expect(FirstRunState.hasCompletedOnboardingKey == "firstRun.hasCompletedOnboarding")
        #expect(FirstRunState.hasAddedFirstBodegaKey == "firstRun.hasAddedFirstBodega")
    }
}
