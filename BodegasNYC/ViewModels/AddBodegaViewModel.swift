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
        ///
        /// TEMPORARILY UNREACHABLE: `submit()` no longer gates on
        /// `sessionStore.currentUserID` while unauthenticated writes are
        /// allowed (see 20260812013849_allow_anonymous_bodega_inserts.sql).
        /// Left in place, along with `AddBodegaView`'s sheet wiring, so
        /// restoring the gate is a one-line revert in `submit()`.
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

    init(coordinate: Coordinate, bodegaService: BodegaService, sessionStore: SessionStore) {
        self.coordinate = coordinate
        self.bodegaService = bodegaService
        self.sessionStore = sessionStore
    }

    func submit() {
        guard isNameValid else {
            submissionState = .failed("Please enter a name.")
            return
        }
        // TEMPORARY: the sign-in requirement below is disabled while Sign in
        // with Apple is blocked on Apple Developer Program enrollment — see
        // 20260812013849_allow_anonymous_bodega_inserts.sql. `userID` is nil
        // for a signed-out submit; `.signInRequired`/`SignInView` stay wired
        // up in AddBodegaView for when this gate comes back.
        let userID = sessionStore.currentUserID
        submitTask?.cancel()
        submissionState = .submitting
        submitTask = Task { [bodegaService, coordinate, name, address, hasCat,
                              servesHotFood, sellsCigarettes, sellsBeer, sellsLotto, dayEntries, userID] in
            do {
                let draft = NewBodega(
                    createdBy: userID,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    coordinate: coordinate,
                    address: address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : address,
                    hasCat: hasCat,
                    servesHotFood: servesHotFood,
                    sellsCigarettes: sellsCigarettes,
                    sellsBeer: sellsBeer,
                    sellsLotto: sellsLotto,
                    hours: Self.buildHours(from: dayEntries)
                )
                let inserted = try await bodegaService.insert(draft)
                guard !Task.isCancelled else { return }
                submissionState = .submitted(inserted)
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

    /// A day left blank (not marked closed, no times entered) maps to `nil`
    /// — matches `BodegaDetailView.HoursSection`, which already treats a nil
    /// day the same as an explicit `isClosed`.
    private static func buildHours(from entries: [DayEntry]) -> BodegaHours? {
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
