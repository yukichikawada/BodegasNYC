import AuthenticationServices
import Foundation
import Observation

/// Drives Delete Account in the Account sheet (#127, spec item 5, eng D7
/// and D8, design DS4 to DS6). Mirrors `FlagIssueViewModel`: one state enum,
/// one in-flight task, a failure mapped to copy.
///
/// Flow: `confirmRequested()` (the Delete Account row) → `.confirming` (the
/// dialog) → `proceed()` → for an Apple user `.awaitingApple` (the "Confirm
/// with Apple" step) and `appleAuthorized(code:)`, otherwise straight on →
/// `.deleting` → `.deleted(outcome)` once the function answered 204/202 and
/// the local session is cleared. A failure returns to the idle layout with
/// its line (`.failed`); Delete Account is the retry.
///
/// Each transition is guarded by the state it starts from (eng D8), so a
/// double tap or a late callback never sends a second request. Nothing
/// cancels the in-flight request: the sheet cannot be dismissed while
/// deleting (eng D7), and if it goes away anyway the request still runs to
/// `.deleted` and signs out.
@MainActor
@Observable
final class AccountViewModel {
    enum DeletionState: Equatable {
        case idle
        /// The "Delete your account?" dialog is up.
        case confirming
        /// The Apple step replaces Section B (DS4). Apple's own cancel keeps
        /// this state; the step's Cancel and Done go back to `.idle`.
        case awaitingApple
        case deleting
        /// Terminal (DS5): the account is gone and the session cleared.
        case deleted(AccountService.Outcome)
        /// The idle layout with this line under Delete Account (DS6).
        case failed(AppCopy.Account)
    }

    private(set) var state: DeletionState = .idle
    /// A non-cancel Apple error, shown under the Apple button (DS4). Cleared
    /// when the step is left or retried.
    private(set) var appleError: AppCopy.Account?

    private let accountService: AccountService
    private let sessionStore: SessionStore
    private var deleteTask: Task<Void, Never>?

    init(accountService: AccountService, sessionStore: SessionStore) {
        self.accountService = accountService
        self.sessionStore = sessionStore
    }

    /// Whether deletion goes through Apple first.
    var needsAppleStep: Bool { sessionStore.signedInWithApple }

    var isDeleting: Bool { state == .deleting }

    var isDeleted: Bool {
        if case .deleted = state { return true }
        return false
    }

    /// The failure line under Delete Account, if any.
    var failure: AppCopy.Account? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// The Delete Account row: opens the confirmation. From idle, from a
    /// failure (the retry), or from a `.confirming` left behind by a dialog
    /// dismissed without a button, so the row is never dead.
    func confirmRequested() {
        switch state {
        case .idle, .failed, .confirming: state = .confirming
        default: break
        }
    }

    /// The dialog's Cancel, the Apple step's Cancel and Done: back to idle.
    /// A no-op once the request is in flight.
    func cancel() {
        switch state {
        case .confirming, .awaitingApple:
            state = .idle
            appleError = nil
        default:
            break
        }
    }

    /// The dialog's Delete Account. Only from `.confirming` (eng D8).
    func proceed() {
        guard state == .confirming else { return }
        if needsAppleStep {
            appleError = nil
            state = .awaitingApple
        } else {
            delete(appleAuthorizationCode: nil)
        }
    }

    /// Apple returned an authorization code. Only from `.awaitingApple`.
    func appleAuthorized(code: String) {
        guard state == .awaitingApple else { return }
        appleError = nil
        delete(appleAuthorizationCode: code)
    }

    /// Apple's sheet failed or was cancelled. Cancel keeps the step (DS4,
    /// amending eng D8); anything else shows "Apple couldn't confirm it's
    /// you." under the button, which is the retry.
    func appleFailed(_ error: any Error) {
        guard state == .awaitingApple else { return }
        if (error as? ASAuthorizationError)?.code == .canceled { return }
        appleError = .appleFailed
    }

    /// The Apple step could not read Apple's response (no code in it).
    func appleResponseUnreadable() {
        guard state == .awaitingApple else { return }
        appleError = .appleFailed
    }

    private func delete(appleAuthorizationCode: String?) {
        state = .deleting
        deleteTask = Task { [accountService, sessionStore] in
            do throws(AccountService.Error) {
                let outcome = try await accountService.deleteAccount(appleAuthorizationCode: appleAuthorizationCode)
                // The server user is gone; the SDK clears the local session
                // first and ignores the 401/403/404 from /logout.
                await sessionStore.signOut()
                state = .deleted(outcome)
            } catch {
                state = .failed(Self.failureMessage(for: error))
            }
        }
    }

    /// Design DS6's mapping: by the body's `code` first, then by status.
    /// A failure before `deleteUser` says the account wasn't deleted; a
    /// 5xx without a known code, or no answer at all, may have deleted it,
    /// so it only says the server wasn't reached and Delete Account
    /// converges on retry (eng D5).
    static func failureMessage(for error: AccountService.Error) -> AppCopy.Account {
        switch error {
        case .notSignedIn:
            return .signInAgain
        case .transport:
            return .unreachable
        case .server(let status, let code, _):
            switch code {
            case "apple_code_required", "apple_identity_mismatch":
                return .appleMismatch
            case "apple_exchange_failed", "apple_revoke_failed", "delete_failed", "storage_remove_failed":
                return .notDeleted
            default:
                if status == 401 { return .signInAgain }
                if (400..<500).contains(status) { return .notDeleted }
                return .unreachable
            }
        }
    }

#if DEBUG
    func waitForPendingDeleteForTesting() async {
        await deleteTask?.value
    }
#endif
}
