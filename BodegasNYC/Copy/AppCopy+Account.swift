import Foundation

// MARK: - Account (#127, design DS1 to DS8)

nonisolated extension AppCopy {
    /// Every string on the Account surface: the toolbar menu item, the
    /// Account sheet, its two confirmations and the deletion states. A
    /// nested enum (the `YourBlocks` shape) because `AppCopy`'s body sits at
    /// SwiftLint's type length; registered in `AppCopyVoiceTests.shippedCopy`
    /// by hand, since `AppCopy.allCases` does not reach it (eng R8).
    nonisolated enum Account: CaseIterable, Hashable, Sendable {
        /// The toolbar menu item, shown through `menuItemWithEllipsis`
        /// (DS1: it opens a sheet, and "Account…" would read doubled inside
        /// the Account menu).
        case menuItem
        case title
        case signOut
        /// Section A's footer for an Apple user (DS3). A DEBUG email user
        /// sees the raw email instead, which is not copy.
        case signedInWithApple
        case signOutConfirmTitle
        case signOutFailedTitle
        /// Section B's consequence row, `.primary` (DS3, #95 D8).
        case consequences
        case deleteAccount
        case confirmTitle
        case confirmBody
        /// Appended to `confirmBody` for an Apple user (DS3).
        case confirmBodyApple
        /// The Apple step's heading (DS4), with the header trait.
        case appleStepTitle
        case appleStepBody
        case cancel
        /// A non-cancel Apple error, under the Apple button (DS4).
        case appleFailed
        /// Shown with a trailing ellipsis (`withTrailingEllipsis`) beside the
        /// spinner while the request runs (DS5).
        case deleting
        case deletingAnnouncement
        /// The terminal line (DS5).
        case deleted
        /// The terminal line after a `202 cleanup_pending` (DS6).
        case deletedCleanupPending
        /// A failure before the account was deleted (DS6).
        case notDeleted
        case appleMismatch
        /// Transport or an unknown response (DS6); the retry converges
        /// through eng D5.
        case unreachable
        case signInAgain
        case privacyPolicy
        case done

        var copy: CopyString {
            switch self {
            case .menuItem: CopyString(kind: .label, text: "Your Account")
            case .title: CopyString(kind: .label, text: "Account")
            case .signOut: CopyString(kind: .label, text: "Sign Out")
            case .signedInWithApple: CopyString(kind: .body, text: "Signed in with Apple.")
            case .signOutConfirmTitle: CopyString(kind: .title, text: "Sign out of your account?")
            case .signOutFailedTitle: CopyString(kind: .label, text: "Couldn't Sign Out")
            case .consequences:
                CopyString(
                    kind: .body,
                    text: "Deleting removes your reviews, photos and flags for good. "
                        + "Bodegas you added stay on the map with no link to you. Walked blocks stay on this phone."
                )
            case .deleteAccount: CopyString(kind: .label, text: "Delete Account")
            case .confirmTitle: CopyString(kind: .title, text: "Delete your account?")
            case .confirmBody:
                CopyString(
                    kind: .body,
                    text: "Your reviews, photos and flags go for good. Bodegas you added stay. This can't be undone."
                )
            case .confirmBodyApple: CopyString(kind: .body, text: "You'll confirm with Apple first.")
            case .appleStepTitle: CopyString(kind: .label, text: "Delete Account")
            case .appleStepBody:
                CopyString(kind: .body, text: "Confirm with Apple to delete your account. Deletion starts right after.")
            case .cancel: CopyString(kind: .label, text: "Cancel")
            case .appleFailed: CopyString(kind: .body, text: "Apple couldn't confirm it's you. Try again.")
            case .deleting: CopyString(kind: .value, text: "Deleting your account")
            case .deletingAnnouncement: CopyString(kind: .body, text: "Deleting your account.")
            case .deleted: CopyString(kind: .body, text: "Your account is gone.")
            case .deletedCleanupPending:
                CopyString(kind: .body, text: "Your account is gone. A few photos may take a while to disappear.")
            case .notDeleted: CopyString(kind: .body, text: "Your account wasn't deleted. Try again.")
            case .appleMismatch: CopyString(kind: .body, text: "Apple didn't confirm this account. Try again.")
            case .unreachable:
                CopyString(kind: .body, text: "Couldn't reach the server. Tap Delete Account to try again.")
            case .signInAgain: CopyString(kind: .body, text: "Sign in again, then delete.")
            case .privacyPolicy: CopyString(kind: .label, text: "Privacy Policy")
            case .done: CopyString(kind: .label, text: "Done")
            }
        }

        /// A menu item that opens something more, with the HIG's trailing
        /// "…". The voice rules check the label without it.
        var menuItemWithEllipsis: String {
            copy.text + "\u{2026}"
        }

        /// A status still in progress, with a trailing "…". The voice rules
        /// check the text without it.
        var withTrailingEllipsis: String {
            copy.text + "\u{2026}"
        }

        /// The published privacy policy (`docs/PRIVACY.md` on GitHub Pages),
        /// linked from the toolbar menu and the Account sheet (spec D5).
        static let privacyPolicyURL = URL(string: "https://yukichikawada.github.io/BodegasNYC/privacy/")!
    }
}
