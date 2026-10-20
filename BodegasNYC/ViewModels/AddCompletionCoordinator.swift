import Observation
import SwiftUI
import UIKit

/// Owns everything that happens after a bodega is added (#25, eng review R9,
/// design DD11/DD15): the insert, the camera move, the pin drop and its
/// haptic, the one-time first-add card, and the VoiceOver announcement.
///
/// Timeline for one add (`bodegaWasSubmitted`):
/// 1. Synchronously: insert into both view models (R6), highlight the pin
///    (R7), record the first add (the app's single `markFirstBodegaAdded()`
///    call site), post the announcement, mark the pin `.pending` (rendered
///    invisible) and move the camera.
/// 2. When the camera settles on the pin (`cameraDidSettle`), or after a
///    0.65 s fallback: `.dropping` (the pin's spring) and the haptic.
/// 3. First add only, 0.6 s after the drop (the 0.5 s spring has landed):
///    the first-add card. It auto-dismisses 8 s after its 0.25 s entrance
///    transition, unless VoiceOver is running.
/// 4. 1.5 s after the drop: the drop state and highlight are cleared.
///
/// Each add owns its bodega id: a later step, or `cancel()`, only clears the
/// drop state and highlight while they still belong to that id, so an older
/// add can never clear a newer one.
@MainActor
@Observable
final class AddCompletionCoordinator {
    enum DropState: Equatable {
        case none
        case pending(Bodega.ID)
        case dropping(Bodega.ID)

        var bodegaID: Bodega.ID? {
            switch self {
            case .none: nil
            case .pending(let id), .dropping(let id): id
            }
        }
    }

    /// What one pin should render, from `dropState` (see `BodegaPinView`).
    enum PinPhase: Equatable {
        case atRest
        case pending
        case dropping
    }

    static let settleFallback: Duration = .milliseconds(650)
    static let cardDelay: Duration = .milliseconds(600)
    static let clearDelay: Duration = .milliseconds(1500)
    /// The card slot's transition (`MapScreenView`, DD13). The auto-dismiss
    /// clock starts when the card has finished appearing (DD11); it is
    /// counted from here rather than from a view callback, so the whole
    /// timeline stays on one injected clock.
    static let cardTransition: Duration = .milliseconds(250)
    static let cardAutoDismiss: Duration = .seconds(8)
    /// How far the settled camera center may be from the new pin and still
    /// count as "settled on it" (about 50 m). A settle from an earlier,
    /// unrelated camera change is ignored; the fallback covers it.
    static let settleTolerance = 0.0005

    private(set) var dropState: DropState = .none
    private(set) var firstAddCard: Bodega?
    private(set) var hapticTrigger = 0

    /// Assigned once the owning view's state exists (`BrowseView` binds it
    /// to its camera position on appear), hence a `var`.
    @ObservationIgnored var moveCamera: (Coordinate) -> Void

    @ObservationIgnored private let firstRunState: FirstRunState
    @ObservationIgnored private let insert: (Bodega) -> Void
    @ObservationIgnored private let setHighlighted: (Bodega.ID?) -> Void
    @ObservationIgnored private let isVoiceOverRunning: () -> Bool
    @ObservationIgnored private let announce: (String) -> Void
    @ObservationIgnored private let onFirstAdd: () -> Void
    @ObservationIgnored private let clock: any Clock<Duration>

    /// The add in progress: its bodega, whether it is the first, and the
    /// task waiting out its current step.
    @ObservationIgnored private var current: Bodega?
    @ObservationIgnored private var currentIsFirstAdd = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cardDismissTask: Task<Void, Never>?

    init(
        firstRunState: FirstRunState,
        insert: @escaping (Bodega) -> Void,
        moveCamera: @escaping (Coordinate) -> Void,
        setHighlighted: @escaping (Bodega.ID?) -> Void,
        isVoiceOverRunning: @escaping () -> Bool = { UIAccessibility.isVoiceOverRunning },
        announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() },
        onFirstAdd: @escaping () -> Void = {},
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.firstRunState = firstRunState
        self.insert = insert
        self.moveCamera = moveCamera
        self.setHighlighted = setHighlighted
        self.isVoiceOverRunning = isVoiceOverRunning
        self.announce = announce
        self.onFirstAdd = onFirstAdd
        self.clock = clock
    }

    /// The pin phase for one bodega.
    func pinPhase(for id: Bodega.ID) -> PinPhase {
        switch dropState {
        case .pending(id): .pending
        case .dropping(id): .dropping
        default: .atRest
        }
    }

    /// A successful add. Everything up to the camera move happens before
    /// this returns; the rest runs on the clock.
    func bodegaWasSubmitted(_ bodega: Bodega) {
        let previous = task
        cancel()

        insert(bodega)
        setHighlighted(bodega.id)
        let isFirstAdd = firstRunState.markFirstBodegaAdded()
        if isFirstAdd {
            // The first add ends the tutorial (#22).
            onFirstAdd()
        }
        announce(AppCopy.addedAnnouncement(name: bodega.name).text)

        current = bodega
        currentIsFirstAdd = isFirstAdd
        dropState = .pending(bodega.id)
        moveCamera(bodega.coordinate)

        let clock = clock
        task = Task { [weak self] in
            // The previous add was cancelled above; let it unwind first.
            await previous?.value
            do {
                try await clock.sleep(for: Self.settleFallback)
            } catch {
                return
            }
            self?.beginDrop(of: bodega.id)
        }
    }

    /// The map's camera finished moving (`onMapCameraChange(frequency:
    /// .onEnd)`). Starts the drop if a pin is waiting and the camera came to
    /// rest on it; pass `nil` to skip the position check.
    func cameraDidSettle(center: Coordinate? = nil) {
        guard case .pending(let id) = dropState, let bodega = current, bodega.id == id else { return }
        if let center {
            let latOff = abs(center.latitude - bodega.coordinate.latitude)
            let lonOff = abs(center.longitude - bodega.coordinate.longitude)
            guard latOff <= Self.settleTolerance, lonOff <= Self.settleTolerance else { return }
        }
        beginDrop(of: id)
    }

    /// A navigation push or a switch to the List tab: every step not yet
    /// taken is skipped (no card, no haptic if it hasn't fired), the drop
    /// state and highlight are cleared if they belong to this add, and the
    /// card goes away. The insert has already happened and stays.
    func cancel() {
        task?.cancel()
        task = nil
        if let current {
            clearDrop(ifOwnedBy: current.id)
        }
        current = nil
        currentIsFirstAdd = false
        dismissFirstAddCard()
    }

    /// Done on the card, or its auto-dismiss.
    func dismissFirstAddCard() {
        cardDismissTask?.cancel()
        cardDismissTask = nil
        firstAddCard = nil
    }

    // MARK: Steps

    private func beginDrop(of id: Bodega.ID) {
        guard dropState == .pending(id), let bodega = current, bodega.id == id else { return }
        task?.cancel()
        dropState = .dropping(id)
        hapticTrigger += 1

        let clock = clock
        let showsCard = currentIsFirstAdd
        task = Task { [weak self] in
            do {
                var elapsed: Duration = .zero
                if showsCard {
                    try await clock.sleep(for: Self.cardDelay)
                    elapsed = Self.cardDelay
                    self?.showFirstAddCard(bodega)
                }
                try await clock.sleep(for: Self.clearDelay - elapsed)
            } catch {
                return
            }
            self?.finish(id)
        }
    }

    private func showFirstAddCard(_ bodega: Bodega) {
        guard current?.id == bodega.id else { return }
        firstAddCard = bodega
        cardDismissTask?.cancel()
        // VoiceOver users get as long as they need (DD15).
        guard !isVoiceOverRunning() else { return }
        let clock = clock
        cardDismissTask = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.cardTransition + Self.cardAutoDismiss)
            } catch {
                return
            }
            guard self?.firstAddCard?.id == bodega.id else { return }
            self?.dismissFirstAddCard()
        }
    }

    private func finish(_ id: Bodega.ID) {
        guard current?.id == id else { return }
        clearDrop(ifOwnedBy: id)
        current = nil
        currentIsFirstAdd = false
        task = nil
    }

    private func clearDrop(ifOwnedBy id: Bodega.ID) {
        if dropState.bodegaID == id {
            dropState = .none
            setHighlighted(nil)
        }
    }
}
