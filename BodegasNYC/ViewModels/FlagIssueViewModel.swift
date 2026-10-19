import Foundation
import Observation
import PostgREST

/// Drives the Flag-an-Issue submit flow from `BodegaDetailView`, for any of
/// the three `FlagTarget`s (the bodega itself, one of its reviews, or one of
/// its photos) — one view model/sheet for all three, only the copy differs.
/// Mirrors `AddReviewViewModel`'s sign-in-gated `SubmissionState` pattern
/// exactly.
///
/// Auto-hiding at the flag-count threshold is entirely server-side
/// (`trg_flags_auto_hide`), so a successful submit here is just the insert —
/// nothing to update locally.
@MainActor
@Observable
final class FlagIssueViewModel: Identifiable {
    enum SubmissionState: Equatable {
        case idle
        case submitting
        case submitted(Flag)
        /// No signed-in user at submit time — `FlagIssueView` reacts to this
        /// by presenting `SignInView` inline, same as `AddReviewViewModel`.
        case signInRequired
        case failed(String)
    }

    /// Stored verbatim (its `rawValue`) in `flags.reason`, which is free
    /// `text` in the DB — there's no enum/CHECK on that column, so adding a
    /// case here needs no migration.
    enum Reason: String, CaseIterable, Identifiable {
        case closedPermanently = "Closed permanently"
        case wrongDetails = "Wrong details"
        case inappropriate = "Inappropriate"
        case other = "Other"

        var id: Self { self }
    }

    /// Shown instead of PostgREST's raw "duplicate key value violates unique
    /// constraint …" message — see `failureMessage(for:)`.
    static let alreadyFlaggedMessage = "You've already flagged this."

    let id = UUID()
    let target: FlagTarget

    var reason: Reason = .wrongDetails
    var details: String = ""

    private(set) var submissionState: SubmissionState = .idle

    private let flagService: FlagService
    private let sessionStore: SessionStore
    private var submitTask: Task<Void, Never>?

    init(target: FlagTarget, flagService: FlagService, sessionStore: SessionStore) {
        self.target = target
        self.flagService = flagService
        self.sessionStore = sessionStore
    }

    /// `flags.reason` is a single text column, so the picked reason and the
    /// optional free text are folded into one string: just the reason when
    /// details are blank, otherwise "Reason: details".
    var composedReason: String {
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDetails.isEmpty ? reason.rawValue : "\(reason.rawValue): \(trimmedDetails)"
    }

    func submit() {
        guard let userID = sessionStore.currentUserID else {
            submissionState = .signInRequired
            return
        }
        submitTask?.cancel()
        submissionState = .submitting
        let draft = NewFlag(reporterId: userID, target: target, reason: composedReason)
        submitTask = Task { [flagService, draft] in
            do {
                let flag = try await flagService.insert(draft)
                guard !Task.isCancelled else { return }
                submissionState = .submitted(flag)
            } catch {
                guard !Task.isCancelled else { return }
                submissionState = .failed(Self.failureMessage(for: error))
            }
        }
    }

    /// Called when the nested `SignInView` sheet is dismissed — resets state
    /// back to `.idle` so a subsequent Submit tap is a fresh transition. See
    /// `AddBodegaViewModel.dismissSignInPrompt()` for the full rationale.
    func dismissSignInPrompt() {
        guard submissionState == .signInRequired else { return }
        submissionState = .idle
    }

    /// The DB's partial unique indexes on (reporter_id, <target column>)
    /// allow one flag per user per target; a repeat insert comes back from
    /// PostgREST as HTTP 409 with Postgres' `unique_violation` SQLSTATE,
    /// `23505`, which the SDK decodes into `PostgrestError.code`. Everything
    /// else falls through to `localizedDescription`, same as every other
    /// view model in the app.
    static func failureMessage(for error: any Error) -> String {
        if let postgrestError = error as? PostgrestError, postgrestError.code == "23505" {
            return alreadyFlaggedMessage
        }
        return error.localizedDescription
    }

#if DEBUG
    func waitForPendingSubmitForTesting() async {
        await submitTask?.value
    }
#endif
}
