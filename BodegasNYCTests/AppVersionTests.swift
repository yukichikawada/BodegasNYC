//
//  AppVersionTests.swift
//  BodegasNYCTests
//
//  `AppVersion`, the one place the version and build are formatted (#191).
//
//  protects: the export file's `appVersion` stays "1.1.0 (4)", Sentry's
//  release name stays "1.1.0+4", the version row reads "Version 1.1.0 (4)"
//  and VoiceOver hears "Version 1.1.0, build 4"; a missing key reads "0";
//  the export and Sentry paths read the same bundle values as the row.
//  fails_when: any of those strings changes by a byte, or a caller formats
//  the bundle values itself and drifts.
//  no_claim: the values the build settings write into Info.plist (the UI
//  test compares the row to the running bundle), the row's look (live QA).
//

import Foundation
import Testing

@testable import BodegasNYC

struct AppVersionTests {
    private static let shipped = AppVersion(infoDictionary: [
        "CFBundleShortVersionString": "1.1.0",
        "CFBundleVersion": "4"
    ])

    @Test func exportFileFormatIsVersionThenBuildInParentheses() {
        #expect(Self.shipped.display == "1.1.0 (4)")
    }

    @Test func sentryReleaseIsVersionPlusBuild() {
        #expect(Self.shipped.sentryRelease == "1.1.0+4")
    }

    @Test func versionRowCopyAndSpokenLabel() {
        #expect(AppCopy.Account.version(Self.shipped).text == "Version 1.1.0 (4)")
        #expect(AppCopy.Account.versionSpoken(Self.shipped).text == "Version 1.1.0, build 4")
    }

    @Test func missingKeysReadAsZero() {
        let empty = AppVersion(infoDictionary: nil)
        #expect(empty.display == "0 (0)")
        #expect(empty.sentryRelease == "0+0")
    }

    /// The two existing callers go through `Bundle.appVersion`.
    @Test func exportAndSentryReadTheBundle() {
        let bundle = Bundle.main.appVersion
        #expect(WalkHistoryTransfer.bundleAppVersion == bundle.display)
        #expect(Telemetry.release(bundle: .main) == bundle.sentryRelease)
    }
}
