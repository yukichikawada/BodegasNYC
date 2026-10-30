import CoreLocation
import Foundation
import Observation

/// Drives the Add-a-Bodega submit flow. Owns the form fields for a
/// not-yet-created bodega at a already-confirmed `coordinate` (placement
/// happens upstream, in `MapScreenView`/`BrowseView` — see the placement-mode
/// overlay). `Identifiable` so `BrowseView` can drive its presentation via
/// `.sheet(item:)`.
///
/// Depends on `sessionStore: SessionStore` rather than a raw `AuthClient`:
/// `SessionStore.currentUserID` already mirrors `auth.currentSession`/
/// `authStateChanges` live (see `SessionStore`), so reading it synchronously
/// here is just as fresh as an async `auth.session` call, without needing to
/// thread a second, separate `AuthClient` dependency through
/// `AppEnvironment`/`RootView`/`BrowseView` alongside `sessionStore`.
///
/// Doubles as the Edit Bodega flow from `BodegaDetailView`, mirroring
/// `AddReviewViewModel.existingReview`: when `existingBodega` is non-nil,
/// every field is pre-filled from it and `submit()` calls
/// `bodegaService.update` instead of `.insert`. `coordinate` is still
/// required (it's what the insert path places the pin at); in edit mode it
/// is just the bodega's own coordinate and is never sent, since
/// `BodegaUpdate` has no location field.
@MainActor
@Observable
final class AddBodegaViewModel: Identifiable {
    enum SubmissionState: Equatable {
        case idle
        case submitting
        case submitted(Bodega)
        /// No signed-in user at submit time — `AddBodegaView` reacts to this
        /// by presenting `SignInView` inline rather than a dead-end error
        /// string. The user must tap Submit again after signing in; no
        /// auto-retry-on-sign-in.
        case signInRequired
        /// Add mode only: the duplicate check (#20) found visible bodegas
        /// within `duplicateRadiusMeters` of the pin, nearest first.
        /// `AddBodegaView` shows them in `DuplicateBodegaSheet`; the user
        /// opens one (the draft is dropped), says it's new (`confirmNew()`),
        /// or swipes the sheet away (`dismissDuplicatePrompt()`).
        case possibleDuplicates([Bodega])
        case failed(String)
    }

    /// How close an existing bodega has to be to the pin to be offered as a
    /// possible duplicate on Submit (owner decision on #20).
    nonisolated static let duplicateRadiusMeters: Double = 50
    /// The duplicate check is advisory: past this, Submit goes ahead as if
    /// nothing was nearby (#20 eng review R2).
    nonisolated static let duplicateCheckTimeout: Duration = .seconds(5)

    struct DayEntry: Identifiable, Equatable {
        let id: String // "mon"..."sun" — matches BodegaHours' stored keys.
        let label: String // "Mon"..."Sun"
        var open: String = ""
        var close: String = ""
        var isClosed: Bool = false
    }

    let id = UUID()
    let coordinate: Coordinate
    let existingBodega: Bodega?

    var name: String = ""
    var address: String = ""
    var hasCat = false
    var servesHotFood = false
    var sellsCigarettes = false
    var sellsBeer = false
    var sellsLotto = false
    var hasAtm = false
    var dayEntries: [DayEntry] = AddBodegaViewModel.defaultDayEntries

    private(set) var submissionState: SubmissionState = .idle

    private let bodegaService: BodegaService
    private let sessionStore: SessionStore
    private let clock: any Clock<Duration>
    private var submitTask: Task<Void, Never>?
    /// Set by `confirmNew()` and never reset: the pin can't move, so once
    /// the user has said this draft is new the check is done for this view
    /// model's life, including a retry after a failed insert.
    private var hasConfirmedNew = false

    var isNameValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isEditing: Bool { existingBodega != nil }

    init(
        coordinate: Coordinate,
        existingBodega: Bodega? = nil,
        bodegaService: BodegaService,
        sessionStore: SessionStore,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.coordinate = coordinate
        self.existingBodega = existingBodega
        self.bodegaService = bodegaService
        self.sessionStore = sessionStore
        self.clock = clock
        if let existingBodega {
            name = existingBodega.name
            address = existingBodega.address ?? ""
            hasCat = existingBodega.hasCat
            servesHotFood = existingBodega.servesHotFood
            sellsCigarettes = existingBodega.sellsCigarettes
            sellsBeer = existingBodega.sellsBeer
            sellsLotto = existingBodega.sellsLotto
            hasAtm = existingBodega.hasAtm
            dayEntries = Self.dayEntries(from: existingBodega.hours)
        }
    }

    // Submit in add mode (#20). Edit mode skips the check and keeps the old
    // order: sign-in guard, then the update (`submitEdit()`).
    //
    //   submit()
    //     name invalid ──────────────────────────► .failed("Please enter a name.")
    //     request = signed in ? snapshot : nil     (synchronous, before the Task)
    //     .submitting
    //     hasConfirmedNew? ── yes ─────────────────────────────────┐
    //        └ no ─► fetchNearby(pin, 50 m) raced against 5 s       │
    //                  ├ throws or times out ─► []                  │
    //                  ├ hidden rows dropped                        │
    //                  ├ [] ───────────────────────────────────────┤
    //                  └ [matches] ─► .possibleDuplicates(matches)  │
    //                       ├ confirmNew() ─► hasConfirmedNew = true, submit()
    //                       ├ dismissDuplicatePrompt() ─► .idle
    //                       └ a match opened ─► sheet closes, view model dropped
    //     cancelled (cancelSubmit) ─► return, state untouched ◄────┤
    //     request == nil ─► .signInRequired ◄─────────────────────┤
    //     insert ─► .submitted(bodega) or .failed(message) ◄───────┘
    func submit() {
        guard isNameValid else {
            submissionState = .failed("Please enter a name.")
            return
        }
        guard !isEditing else {
            submitEdit()
            return
        }
        submitTask?.cancel()
        // Snapshotted synchronously, before the Task: edits made while the
        // check or the insert is in flight can't leak into it. nil means
        // nobody is signed in, which is asked only after the check (#20 D1).
        let request = sessionStore.currentUserID.map { makeRequest(userID: $0) }
        let checksNearby = !hasConfirmedNew
        submissionState = .submitting
        submitTask = Task { [bodegaService, coordinate, clock] in
            if checksNearby {
                let matches = await Self.visibleNearbyMatches(
                    at: coordinate,
                    bodegaService: bodegaService,
                    clock: clock
                )
                guard !Task.isCancelled else { return }
                if !matches.isEmpty {
                    submissionState = .possibleDuplicates(matches)
                    return
                }
            }
            guard let request else {
                submissionState = .signInRequired
                return
            }
            await send(request)
        }
    }

    private func submitEdit() {
        guard let userID = sessionStore.currentUserID else {
            submissionState = .signInRequired
            return
        }
        submitTask?.cancel()
        submissionState = .submitting
        // Snapshotted synchronously, before the Task: edits made while the
        // request is in flight can't leak into it.
        let request = makeRequest(userID: userID)
        submitTask = Task { await send(request) }
    }

    private func send(_ request: SubmitRequest) async {
        // A Cancel that landed during the check must never insert (#20 R4).
        guard !Task.isCancelled else { return }
        do {
            let saved: Bodega
            switch request {
            case .insert(let draft):
                saved = try await bodegaService.insert(draft)
            case .update(let id, let values):
                saved = try await bodegaService.update(id: id, values)
            }
            guard !Task.isCancelled else { return }
            submissionState = .submitted(saved)
        } catch {
            guard !Task.isCancelled else { return }
            submissionState = .failed(error.localizedDescription)
        }
    }

    private enum SubmitRequest: Sendable {
        case insert(NewBodega)
        case update(id: UUID, BodegaUpdate)
    }

    /// In edit mode, always the full set of editable fields rather than a
    /// diff against `existingBodega`: simpler, and a no-op for fields the
    /// user didn't touch. (`BodegaUpdate`'s optional encoding is what would
    /// let a caller send only changed keys; this one just never leaves any
    /// unset.) A blank address or all-blank hours goes out as an explicit
    /// `null` via `fieldsToClear` so clearing actually clears. Never sends
    /// `location`, `is_hidden`, or `created_by` — `BodegaUpdate` has no such
    /// fields, so `coordinate` is unused here.
    private func makeRequest(userID: UUID) -> SubmitRequest {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressValue = trimmedAddress.isEmpty ? nil : trimmedAddress
        let hours = Self.buildHours(from: dayEntries)

        guard let existingBodega else {
            return .insert(NewBodega(
                createdBy: userID,
                name: trimmedName,
                coordinate: coordinate,
                address: addressValue,
                hasCat: hasCat,
                servesHotFood: servesHotFood,
                sellsCigarettes: sellsCigarettes,
                sellsBeer: sellsBeer,
                sellsLotto: sellsLotto,
                hasAtm: hasAtm,
                hours: hours
            ))
        }
        var fieldsToClear: Set<BodegaUpdate.ClearableField> = []
        if addressValue == nil { fieldsToClear.insert(.address) }
        if hours == nil { fieldsToClear.insert(.hours) }
        return .update(id: existingBodega.id, BodegaUpdate(
            name: trimmedName,
            address: addressValue,
            hasCat: hasCat,
            servesHotFood: servesHotFood,
            sellsCigarettes: sellsCigarettes,
            sellsBeer: sellsBeer,
            sellsLotto: sellsLotto,
            hasAtm: hasAtm,
            hours: hours,
            fieldsToClear: fieldsToClear
        ))
    }

    /// Called when the nested `SignInView` sheet is dismissed (swipe-down,
    /// or a successful sign-in's programmatic dismiss) — resets state back
    /// to `.idle` so a subsequent Submit tap is a fresh transition rather
    /// than a same-value re-assignment of `.signInRequired`, which
    /// `AddBodegaView`'s `.sheet(isPresented:)` binding wouldn't otherwise
    /// re-detect. A no-op if called while some other state is current (e.g.
    /// a fast successive tap already moved on to `.submitting`).
    func dismissSignInPrompt() {
        guard submissionState == .signInRequired else { return }
        submissionState = .idle
    }

    private static let defaultDayEntries: [DayEntry] = [
        DayEntry(id: "mon", label: "Mon"), DayEntry(id: "tue", label: "Tue"),
        DayEntry(id: "wed", label: "Wed"), DayEntry(id: "thu", label: "Thu"),
        DayEntry(id: "fri", label: "Fri"), DayEntry(id: "sat", label: "Sat"),
        DayEntry(id: "sun", label: "Sun")
    ]

    /// Inverse of `buildHours(from:)`, used to pre-fill the Edit Bodega
    /// form: a `nil` day becomes a blank row, a closed day a row with
    /// `isClosed` set. Round-trips exactly for anything `buildHours` itself
    /// produces. A closed day's `open`/`close` are blanked, matching what
    /// `buildHours` writes for one. The only rows that don't survive the
    /// round trip unchanged are hand-written DB rows: a closed day with
    /// stored times comes back as `""`/`""`, and an open day with both
    /// times empty comes back as `nil`.
    static func dayEntries(from hours: BodegaHours?) -> [DayEntry] {
        defaultDayEntries.map { entry in
            guard let hours, let keyPath = dayKeyPaths[entry.id], let dayHours = hours[keyPath: keyPath] else {
                return entry
            }
            var filled = entry
            filled.open = dayHours.isClosed ? "" : dayHours.open
            filled.close = dayHours.isClosed ? "" : dayHours.close
            filled.isClosed = dayHours.isClosed
            return filled
        }
    }

    /// `DayEntry.id` → the matching `BodegaHours` property, shared by
    /// `buildHours(from:)` and its inverse `dayEntries(from:)`.
    private static let dayKeyPaths: [String: WritableKeyPath<BodegaHours, BodegaHours.DayHours?>] = [
        "mon": \.mon, "tue": \.tue, "wed": \.wed, "thu": \.thu,
        "fri": \.fri, "sat": \.sat, "sun": \.sun
    ]

    /// A day left blank (not marked closed, no times entered) maps to `nil`
    /// — matches `HoursSection` (`BodegaDetailSections.swift`), which
    /// already treats a nil day the same as an explicit `isClosed`.
    static func buildHours(from entries: [DayEntry]) -> BodegaHours? {
        var hours = BodegaHours()
        var anySet = false
        for entry in entries {
            guard let keyPath = dayKeyPaths[entry.id] else { continue }
            let dayHours: BodegaHours.DayHours?
            if entry.isClosed {
                dayHours = BodegaHours.DayHours(open: "", close: "", isClosed: true)
            } else if !entry.open.isEmpty || !entry.close.isEmpty {
                dayHours = BodegaHours.DayHours(open: entry.open, close: entry.close)
            } else {
                dayHours = nil
            }
            if dayHours != nil { anySet = true }
            hours[keyPath: keyPath] = dayHours
        }
        return anySet ? hours : nil
    }

#if DEBUG
    func waitForPendingSubmitForTesting() async {
        await submitTask?.value
    }
#endif
}

// MARK: - Duplicate check (#20)

extension AddBodegaViewModel {
    /// "No, It's New" on the duplicate prompt: submits again and skips the
    /// check from now on. A no-op outside the prompt.
    func confirmNew() {
        guard case .possibleDuplicates = submissionState else { return }
        hasConfirmedNew = true
        submit()
    }

    /// Called when `DuplicateBodegaSheet` is swiped away: back to the
    /// untouched form, and the next Submit checks again. A no-op outside
    /// the prompt, for the same reason as `dismissSignInPrompt()`.
    func dismissDuplicatePrompt() {
        guard case .possibleDuplicates = submissionState else { return }
        submissionState = .idle
    }

    /// Called when `AddBodegaView` goes away (Cancel, or a match opened), so
    /// a check still in flight never reaches the insert (#20 R4). The state
    /// is left as it is; nothing observes it any more.
    func cancelSubmit() {
        submitTask?.cancel()
        submitTask = nil
    }
}
