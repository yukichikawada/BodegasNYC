import Foundation

/// What the Your Blocks sheet shows (#108 PR 2, design D7, D8, D6), as a
/// pure function of the view model's state, so the precedence and the
/// Motion row are unit-tested without a view.
struct YourBlocksContent: Equatable {
    /// Design D8, in precedence order: failure > counting > zero.
    enum Phase: Equatable {
        /// The street data did not load (eng R5).
        case unavailable
        /// The first count since launch is running and no counts exist yet:
        /// values show "—", and "Counting your blocks…" after 0.5s.
        case counting
        /// Counted, and no block is walked anywhere.
        case zero
        case counted
    }

    /// The Motion & Fitness row (design D6, eng R6).
    enum MotionRow: Equatable {
        case hidden
        /// Recording, never asked: the row asks.
        case allowAccess
        /// Recording, denied: the row opens Settings.
        case openSettings
    }

    /// One row: the city (`borough == nil`) or a borough. `walked` and
    /// `total` are nil while counting.
    struct Row: Equatable, Identifiable {
        var borough: Borough?
        var walked: Int?
        var total: Int?

        var id: Int { borough?.rawValue ?? 0 }

        var name: String { AppCopy.YourBlocks.place(borough).copy.text }

        /// "4%", "<1%", or "—" while counting.
        var percentText: String {
            guard let walked, let total else { return AppCopy.countingPlaceholder }
            return AppCopy.percentText(BoroughProgress.percent(walked: walked, total: total))
        }

        var accessibilityLabel: String {
            AppCopy.yourBlocksRowLabel(borough, walked: walked, total: total).text
        }
    }

    var phase: Phase
    var citywide: Row
    /// In `Borough.displayOrder`.
    var boroughs: [Row]
    var motionRow: MotionRow
    var isRecordingOff: Bool
    var isMotionDenied: Bool

    init(
        countState: StreetsWalkedViewModel.CountState,
        hasCounted: Bool,
        progress: [BoroughProgress],
        isRecording: Bool,
        motion: MotionAuthorization
    ) {
        let phase = Self.phase(countState: countState, hasCounted: hasCounted, progress: progress)
        self.phase = phase
        let byBorough = Dictionary(progress.map { ($0.borough, $0) }, uniquingKeysWith: { first, _ in first })
        let showsValues = phase == .zero || phase == .counted
        boroughs = Borough.displayOrder.map { borough in
            let entry = showsValues ? byBorough[borough] : nil
            return Row(borough: borough, walked: entry?.walked, total: entry?.total)
        }
        citywide = showsValues
            ? Row(
                borough: nil,
                walked: progress.reduce(0) { $0 + $1.walked },
                total: progress.reduce(0) { $0 + $1.total }
            )
            : Row(borough: nil)
        motionRow = Self.motionRow(authorization: motion, isRecording: isRecording)
        isRecordingOff = !isRecording
        isMotionDenied = motion == .denied
    }

    /// Failure first, then a first count with nothing to show yet, then
    /// zero. A recount after a count keeps the last counts (design D8), so
    /// it is `.zero` or `.counted`, never `.counting`.
    static func phase(
        countState: StreetsWalkedViewModel.CountState,
        hasCounted: Bool,
        progress: [BoroughProgress]
    ) -> Phase {
        if countState == .unavailable { return .unavailable }
        guard hasCounted, !progress.isEmpty else { return .counting }
        return progress.allSatisfy { $0.walked == 0 } ? .zero : .counted
    }

    /// Asks only someone already recording who was never asked; after a
    /// denial it becomes Open Settings; authorized or unsupported hides it.
    static func motionRow(authorization: MotionAuthorization, isRecording: Bool) -> MotionRow {
        guard isRecording else { return .hidden }
        switch authorization {
        case .notDetermined: return .allowAccess
        case .denied: return .openSettings
        case .authorized, .unavailable: return .hidden
        }
    }
}
