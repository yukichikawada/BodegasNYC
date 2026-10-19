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
        case failed(String)
    }

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
    var dayEntries: [DayEntry] = AddBodegaViewModel.defaultDayEntries

    private(set) var submissionState: SubmissionState = .idle

    private let bodegaService: BodegaService
    private let sessionStore: SessionStore
    private var submitTask: Task<Void, Never>?

    var isNameValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isEditing: Bool { existingBodega != nil }

    init(
        coordinate: Coordinate,
        existingBodega: Bodega? = nil,
        bodegaService: BodegaService,
        sessionStore: SessionStore
    ) {
        self.coordinate = coordinate
        self.existingBodega = existingBodega
        self.bodegaService = bodegaService
        self.sessionStore = sessionStore
        if let existingBodega {
            name = existingBodega.name
            address = existingBodega.address ?? ""
            hasCat = existingBodega.hasCat
            servesHotFood = existingBodega.servesHotFood
            sellsCigarettes = existingBodega.sellsCigarettes
            sellsBeer = existingBodega.sellsBeer
            sellsLotto = existingBodega.sellsLotto
            dayEntries = Self.dayEntries(from: existingBodega.hours)
        }
    }

    func submit() {
        guard isNameValid else {
            submissionState = .failed("Please enter a name.")
            return
        }
        guard let userID = sessionStore.currentUserID else {
            submissionState = .signInRequired
            return
        }
        submitTask?.cancel()
        submissionState = .submitting
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressValue = trimmedAddress.isEmpty ? nil : trimmedAddress
        let hours = Self.buildHours(from: dayEntries)
        submitTask = Task { [bodegaService, coordinate, existingBodega, hasCat,
                              servesHotFood, sellsCigarettes, sellsBeer, sellsLotto, userID] in
            do {
                let saved: Bodega
                if let existingBodega {
                    // Always the full set of editable fields, not a diff
                    // against `existingBodega`: simpler, and idempotent for
                    // fields the user didn't touch. A blank address / all
                    // blank hours is sent as an explicit `null` via
                    // `fieldsToClear` so clearing actually clears. Never
                    // sends `location`, `is_hidden`, or `created_by` —
                    // `BodegaUpdate` has no such fields.
                    var fieldsToClear: Set<BodegaUpdate.ClearableField> = []
                    if addressValue == nil { fieldsToClear.insert(.address) }
                    if hours == nil { fieldsToClear.insert(.hours) }
                    saved = try await bodegaService.update(
                        id: existingBodega.id,
                        BodegaUpdate(
                            name: trimmedName,
                            address: addressValue,
                            hasCat: hasCat,
                            servesHotFood: servesHotFood,
                            sellsCigarettes: sellsCigarettes,
                            sellsBeer: sellsBeer,
                            sellsLotto: sellsLotto,
                            hours: hours,
                            fieldsToClear: fieldsToClear
                        )
                    )
                } else {
                    saved = try await bodegaService.insert(
                        NewBodega(
                            createdBy: userID,
                            name: trimmedName,
                            coordinate: coordinate,
                            address: addressValue,
                            hasCat: hasCat,
                            servesHotFood: servesHotFood,
                            sellsCigarettes: sellsCigarettes,
                            sellsBeer: sellsBeer,
                            sellsLotto: sellsLotto,
                            hours: hours
                        )
                    )
                }
                guard !Task.isCancelled else { return }
                submissionState = .submitted(saved)
            } catch {
                guard !Task.isCancelled else { return }
                submissionState = .failed(error.localizedDescription)
            }
        }
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
    /// produces. Not a perfect inverse for hand-written DB rows: a closed
    /// day's stored `open`/`close` strings are carried into the row but
    /// dropped again by `buildHours` (which always writes `""` for a closed
    /// day), and an open day with both times empty comes back as `nil`.
    static func dayEntries(from hours: BodegaHours?) -> [DayEntry] {
        defaultDayEntries.map { entry in
            guard let hours, let dayHours = dayHours(for: entry.id, in: hours) else { return entry }
            var filled = entry
            filled.open = dayHours.open
            filled.close = dayHours.close
            filled.isClosed = dayHours.isClosed
            return filled
        }
    }

    private static func dayHours(for dayID: String, in hours: BodegaHours) -> BodegaHours.DayHours? {
        switch dayID {
        case "mon": hours.mon
        case "tue": hours.tue
        case "wed": hours.wed
        case "thu": hours.thu
        case "fri": hours.fri
        case "sat": hours.sat
        case "sun": hours.sun
        default: nil
        }
    }

    /// A day left blank (not marked closed, no times entered) maps to `nil`
    /// — matches `BodegaDetailView.HoursSection`, which already treats a nil
    /// day the same as an explicit `isClosed`.
    static func buildHours(from entries: [DayEntry]) -> BodegaHours? {
        var hours = BodegaHours()
        var anySet = false
        for entry in entries {
            let dayHours: BodegaHours.DayHours?
            if entry.isClosed {
                dayHours = BodegaHours.DayHours(open: "", close: "", isClosed: true)
            } else if !entry.open.isEmpty || !entry.close.isEmpty {
                dayHours = BodegaHours.DayHours(open: entry.open, close: entry.close)
            } else {
                dayHours = nil
            }
            if dayHours != nil { anySet = true }
            switch entry.id {
            case "mon": hours.mon = dayHours
            case "tue": hours.tue = dayHours
            case "wed": hours.wed = dayHours
            case "thu": hours.thu = dayHours
            case "fri": hours.fri = dayHours
            case "sat": hours.sat = dayHours
            case "sun": hours.sun = dayHours
            default: break
            }
        }
        return anySet ? hours : nil
    }

#if DEBUG
    func waitForPendingSubmitForTesting() async {
        await submitTask?.value
    }
#endif
}
