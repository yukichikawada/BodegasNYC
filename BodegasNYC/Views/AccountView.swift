import AuthenticationServices
import SwiftUI

/// The Account sheet (#127, design DS1 to DS7), opened by "Your Account…" in
/// the toolbar's Account menu. Inset-grouped `Form`, inline title, Done;
/// `.medium` and `.large`, `.large` only at the accessibility sizes, on the
/// opaque grouped ground (the `YourBlocksSheet` precedent, DS2).
///
/// Idle (DS3): Section A is Sign Out with "Signed in with Apple." as its
/// footer (DEBUG: the test account's raw email); Section B is the
/// consequence line in `.primary` and Delete Account (destructive, red
/// text), with a failure line under it; Section C is the Privacy Policy
/// link. One enum-driven confirmation dialog serves Sign Out and Delete.
///
/// The Apple step (DS4) replaces Section B for an Apple user: heading, body,
/// the Apple button, Cancel; A and C stay, disabled, and Done acts as
/// Cancel. Deleting (DS5): one spinner row, the form disabled, Done hidden,
/// no swipe-down. Deleted: one terminal line, Done the only control.
struct AccountView: View {
    @State private var viewModel: AccountViewModel
    private let sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    /// The last confirmation asked for; kept while the dialog animates out
    /// so its title doesn't flip.
    @State private var dialog: Dialog = .deleteAccount
    @State private var showingDialog = false
    @State private var signOutErrorMessage: String?
    @AccessibilityFocusState private var focus: Focus?

    private typealias Copy = AppCopy.Account

    /// Which confirmation is up (DS3: one dialog, two uses).
    private enum Dialog {
        case signOut
        case deleteAccount
    }

    /// Where VoiceOver lands after each state change (DS7).
    private enum Focus: Hashable {
        case appleHeading
        case failure
        case appleFailure
        case terminal
    }

    /// The content swap between idle, the Apple step and deleting (DS4):
    /// opacity, so the same under Reduce Motion.
    static let swapAnimation = Animation.easeInOut(duration: 0.25)

    init(accountService: AccountService, sessionStore: SessionStore) {
        _viewModel = State(initialValue: AccountViewModel(accountService: accountService, sessionStore: sessionStore))
        self.sessionStore = sessionStore
    }

    var body: some View {
        NavigationStack {
            Form {
                if case .deleted(let outcome) = viewModel.state {
                    terminalSection(outcome)
                } else {
                    accountSection
                    deleteSection
                        .transition(.opacity)
                    privacySection
                }
            }
            .formStyle(.grouped)
            .disabled(viewModel.isDeleting)
            .animation(Self.swapAnimation, value: viewModel.state)
            .navigationTitle(Copy.title.copy.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !viewModel.isDeleting {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Copy.done.copy.text, action: doneTapped)
                    }
                }
            }
            .confirmationDialog(
                dialogTitle,
                isPresented: $showingDialog,
                titleVisibility: .visible,
                presenting: dialog,
                actions: dialogActions,
                message: dialogMessage
            )
            .alert(
                Copy.signOutFailedTitle.copy.text,
                isPresented: Binding(
                    get: { signOutErrorMessage != nil },
                    set: { if !$0 { signOutErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(signOutErrorMessage ?? "")
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .interactiveDismissDisabled(viewModel.isDeleting)
        // Escape is Cancel before submission and nothing while deleting (DS7).
        .accessibilityAction(.escape) {
            if viewModel.state == .awaitingApple {
                viewModel.cancel()
            } else if !viewModel.isDeleting {
                dismiss()
            }
        }
        .onChange(of: viewModel.state) { _, newState in
            stateChanged(to: newState)
        }
        .onChange(of: viewModel.appleError) { _, error in
            if error != nil { focus = .appleFailure }
        }
    }

    // MARK: Sections

    private var accountSection: some View {
        Section {
            Button(Copy.signOut.copy.text) { present(.signOut) }
                .foregroundStyle(.primary)
                .frame(minHeight: 44)
                .accessibilityIdentifier("account.signOut")
        } footer: {
            Text(accountFooter)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(viewModel.state == .awaitingApple)
    }

    /// "Signed in with Apple." or, in DEBUG for the email test account, the
    /// raw email (not copy, DS3).
    private var accountFooter: String {
        #if DEBUG
        if !sessionStore.signedInWithApple, let email = sessionStore.currentUserEmail {
            return email
        }
        #endif
        return Copy.signedInWithApple.copy.text
    }

    @ViewBuilder
    private var deleteSection: some View {
        switch viewModel.state {
        case .awaitingApple:
            appleStepSection
        case .deleting:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(Copy.deleting.withTrailingEllipsis)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }
        default:
            Section {
                Text(Copy.consequences.copy.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Copy.deleteAccount.copy.text, role: .destructive) {
                    viewModel.confirmRequested()
                    present(.deleteAccount)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("account.deleteAccount")
            } footer: {
                if let failure = viewModel.failure {
                    Text(failure.copy.text)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityFocused($focus, equals: .failure)
                }
            }
        }
    }

    /// DS4: heading and body as one row, the Apple button as its own row,
    /// Apple's error under it, then Cancel. Reading order matches.
    private var appleStepSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.appleStepTitle.copy.text)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focus, equals: .appleHeading)
                Text(Copy.appleStepBody.copy.text)
                    .foregroundStyle(.primary)
            }
            .fixedSize(horizontal: false, vertical: true)
            SignInWithAppleButton(.continue, onRequest: configureAppleRequest, onCompletion: handleApple)
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 44)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("account.appleContinue")
            if let appleError = viewModel.appleError {
                Text(appleError.copy.text)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
                    .accessibilityFocused($focus, equals: .appleFailure)
            }
            Button(Copy.cancel.copy.text) { viewModel.cancel() }
                .foregroundStyle(.primary)
                .frame(minHeight: 44)
                .accessibilityIdentifier("account.cancelApple")
        }
    }

    private var privacySection: some View {
        Section {
            Link(Copy.privacyPolicy.copy.text, destination: Copy.privacyPolicyURL)
                .frame(minHeight: 44)
                .accessibilityIdentifier("account.privacyPolicy")
        }
        .disabled(viewModel.state == .awaitingApple)
    }

    /// DS5: one `.primary` line in place of every section; focus lands on it.
    private func terminalSection(_ outcome: AccountService.Outcome) -> some View {
        Section {
            Text((outcome == .deleted ? Copy.deleted : Copy.deletedCleanupPending).copy.text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focus, equals: .terminal)
                .accessibilityIdentifier("account.deleted")
        }
    }

}

// MARK: - Dialog and actions

extension AccountView {
    // MARK: Dialog

    private var dialogTitle: String {
        switch dialog {
        case .signOut: Copy.signOutConfirmTitle.copy.text
        case .deleteAccount: Copy.confirmTitle.copy.text
        }
    }

    @ViewBuilder
    private func dialogActions(_ dialog: Dialog) -> some View {
        switch dialog {
        case .signOut:
            Button(Copy.signOut.copy.text, role: .destructive) { signOut() }
            Button(Copy.cancel.copy.text, role: .cancel) {}
        case .deleteAccount:
            Button(Copy.deleteAccount.copy.text, role: .destructive) { viewModel.proceed() }
                .accessibilityIdentifier("account.confirmDelete")
            Button(Copy.cancel.copy.text, role: .cancel) { viewModel.cancel() }
        }
    }

    @ViewBuilder
    private func dialogMessage(_ dialog: Dialog) -> some View {
        switch dialog {
        case .signOut:
            EmptyView()
        case .deleteAccount:
            if viewModel.needsAppleStep {
                Text(Copy.confirmBody.copy.text + " " + Copy.confirmBodyApple.copy.text)
            } else {
                Text(Copy.confirmBody.copy.text)
            }
        }
    }

    // MARK: Actions

    private func present(_ newDialog: Dialog) {
        dialog = newDialog
        showingDialog = true
    }

    /// Done is Cancel in the Apple step (DS4); otherwise it closes the sheet.
    private func doneTapped() {
        if viewModel.state == .awaitingApple {
            viewModel.cancel()
        } else {
            dismiss()
        }
    }

    /// Moved here from `BrowseView` (#127): success closes the sheet (DS5).
    private func signOut() {
        Task {
            await sessionStore.signOut()
            if sessionStore.isSignedIn {
                signOutErrorMessage = sessionStore.lastAuthError
            } else {
                dismiss()
            }
        }
    }

    private func stateChanged(to state: AccountViewModel.DeletionState) {
        switch state {
        case .awaitingApple:
            focus = .appleHeading
        case .deleting:
            AccessibilityNotification.Announcement(Copy.deletingAnnouncement.copy.text).post()
        case .failed:
            focus = .failure
        case .deleted:
            focus = .terminal
        case .idle, .confirming:
            break
        }
    }

    /// A fresh hashed nonce per request (`AppleSignInNonce`, as in
    /// `SignInView`). Only the authorization code is used: the function
    /// exchanges it server-side, so the raw nonce is not kept. No scopes.
    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.nonce = AppleSignInNonce.sha256(AppleSignInNonce.randomNonceString())
    }

    private func handleApple(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let codeData = credential.authorizationCode,
                let code = String(data: codeData, encoding: .utf8)
            else {
                viewModel.appleResponseUnreadable()
                return
            }
            viewModel.appleAuthorized(code: code)
        case .failure(let error):
            viewModel.appleFailed(error)
        }
    }
}
