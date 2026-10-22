import SwiftUI
import TipKit

/// Presented as `.sheet(item:)` from `BrowseView` once a placement
/// coordinate is confirmed. Composition follows `BodegaDetailView`'s
/// section-per-private-struct convention, as a `Form` inside its own
/// `NavigationStack` (normal for sheet content — doesn't conflict with
/// `BrowseView`'s outer stack/`path`).
///
/// Also presented from `BodegaDetailView` as "Edit Bodega"
/// (`viewModel.existingBodega != nil`, fields pre-filled) — same view
/// either way, only the title and confirm-button label differ, exactly as
/// `AddReviewView` does for editing a review.
struct AddBodegaView: View {
    @Bindable var viewModel: AddBodegaViewModel
    let sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onSubmitted: (Bodega) -> Void
    /// A match in the duplicate prompt was tapped (#20): the parent closes
    /// this sheet, dropping the draft, and opens that bodega. Edit Bodega
    /// never shows the prompt and passes `{ _ in }`.
    let onOpenExisting: (Bodega) -> Void
    /// True from the moment the duplicate prompt is entered until its sheet
    /// has finished dismissing. Holds the sign-in sheet back while the half
    /// sheet animates away after a signed-out "No, It's New": SwiftUI drops
    /// a presentation started during another's dismissal.
    @State private var isDuplicateSheetUp = false
    /// The duplicate sheet opens at `.large` at accessibility text sizes so
    /// the first match is on screen (design DS2); set on each presentation.
    @State private var duplicateDetent: PresentationDetent = .medium
    /// The matches on screen, kept past the prompt state so the sheet does
    /// not empty out while it animates away.
    @State private var shownMatches: [Bodega] = []

    private var isEditing: Bool { viewModel.isEditing }

    private var isShowingDuplicates: Bool {
        if case .possibleDuplicates = viewModel.submissionState { true } else { false }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Tutorial (#22): the form tip sits above Basics on Add only;
                // Edit Bodega never shows it.
                if !isEditing {
                    TipView(FormTip())
                        .inlineBodegaTipStyle(onOpaqueSurface: true)
                }
                Section("Basics") {
                    TextField("Name", text: $viewModel.name)
                    TextField("Address (optional)", text: $viewModel.address)
                }
                Section("What's Available") {
                    Toggle(isOn: $viewModel.hasCat) { Label("Cat", systemImage: "cat") }
                    Toggle(isOn: $viewModel.servesHotFood) { Label("Hot food", systemImage: "flame") }
                    Toggle(isOn: $viewModel.sellsCigarettes) { Label("Cigarettes", systemImage: "smoke") }
                    Toggle(isOn: $viewModel.sellsBeer) { Label("Beer", systemImage: "mug") }
                    Toggle(isOn: $viewModel.sellsLotto) { Label("Lotto", systemImage: "ticket") }
                }
                // iOS switches ignore the AccentColor asset. Tinted per
                // section, not on the Form, so the submit ProgressView
                // overlay stays gray (DESIGN.md Colors: tint is never status).
                .tint(.accentColor)
                Section("Hours") {
                    ForEach($viewModel.dayEntries) { $entry in
                        DayHoursRow(entry: $entry)
                    }
                }
                .tint(.accentColor)
                if case .failed(let message) = viewModel.submissionState {
                    Section { Text(message).foregroundStyle(.red).font(.footnote) }
                }
            }
            // Edits made while a submit is in flight would otherwise be
            // silently discarded — `submit()` already snapshotted the
            // fields into its request before the `await`.
            .disabled(viewModel.submissionState == .submitting)
            .navigationTitle(isEditing ? "Edit Bodega" : "Add a Bodega")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Submit") { viewModel.submit() }
                        .disabled(!viewModel.isNameValid || viewModel.submissionState == .submitting)
                }
            }
            .overlay { if viewModel.submissionState == .submitting { ProgressView() } }
            .interactiveDismissDisabled(viewModel.submissionState == .submitting)
            .onChange(of: viewModel.submissionState) { _, newValue in
                switch newValue {
                case .submitted(let bodega):
                    onSubmitted(bodega)
                case .possibleDuplicates(let matches):
                    // Always a real transition: the prompt is only ever
                    // entered from `.submitting`.
                    shownMatches = matches
                    duplicateDetent = dynamicTypeSize.isAccessibilitySize ? .large : .medium
                    isDuplicateSheetUp = true
                case .signInRequired where isDuplicateSheetUp:
                    // Normally the half sheet's `onDismiss` releases the
                    // latch. If SwiftUI ever dropped that presentation,
                    // `onDismiss` never fires, so release it anyway once a
                    // dismissal animation would have ended; a second
                    // release is a no-op.
                    Task {
                        try? await Task.sleep(for: .milliseconds(750))
                        isDuplicateSheetUp = false
                    }
                default:
                    break
                }
            }
            // Driven directly off `submissionState` rather than an
            // `.onChange`-triggered `@State` flag: `.onChange` only fires
            // when the value actually changes, but re-tapping Submit while
            // still signed out re-assigns the *same* `.signInRequired` case
            // — a same-value re-assignment `.onChange` would silently miss,
            // leaving the sheet stuck closed on a second attempt.
            // `dismissSignInPrompt()` resets state to `.idle` on dismissal
            // (swipe-down or a successful sign-in's programmatic dismiss)
            // so the next Submit tap starts from a clean transition.
            // Held back while the duplicate sheet is still on screen or
            // animating away (see `isDuplicateSheetUp`); its `onDismiss`
            // clears the flag and this binding then presents.
            .sheet(
                isPresented: Binding(
                    get: { viewModel.submissionState == .signInRequired && !isDuplicateSheetUp },
                    set: { isPresented in
                        if !isPresented { viewModel.dismissSignInPrompt() }
                    }
                )
            ) {
                // Design DD10: a half sheet over the form, not a full one.
                SignInView(sessionStore: sessionStore)
                    .presentationDetents([.medium])
                    .presentationBackground(.thickMaterial)
            }
            // The duplicate prompt (#20), driven off `submissionState` like
            // the sign-in sheet above. Swipe-down resets to `.idle`.
            .sheet(
                isPresented: Binding(
                    get: { isShowingDuplicates },
                    set: { isPresented in
                        if !isPresented { viewModel.dismissDuplicatePrompt() }
                    }
                ),
                onDismiss: { isDuplicateSheetUp = false },
                content: {
                    DuplicateBodegaSheet(
                        matches: shownMatches,
                        onPick: { onOpenExisting($0) },
                        onConfirmNew: { viewModel.confirmNew() }
                    )
                    .presentationDetents([.medium, .large], selection: $duplicateDetent)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.thickMaterial)
                }
            )
        }
        // Cancel, or a match opened: a check still running must not go on
        // to insert the dropped draft (#20 eng R4).
        .onDisappear { viewModel.cancelSubmit() }
    }
}

/// One weekday's hours. The toggle is titled with the day ("Mon"..."Sun",
/// same labels and width as `HoursSection` on the detail screen) and its
/// on state means *open*; the stored `isClosed` is just its inverse.
/// Shared by Add and Edit Bodega (both are this same `AddBodegaView`).
private struct DayHoursRow: View {
    @Binding var entry: AddBodegaViewModel.DayEntry
    /// Each day is its own Form row, so a Grid cannot align them; a minimum
    /// width that scales with the label keeps "Closed" in one column at
    /// every Dynamic Type size (a fixed 40 pt was narrower than "Wed" at
    /// accessibility sizes, #77).
    @ScaledMetric(relativeTo: .body) private var dayLabelMinWidth: CGFloat = 40
    /// At accessibility sizes one row cannot hold both time fields (they
    /// truncated to "7:00…  – 11:0…") or the day plus "Closed" (it wrapped
    /// mid-word), so both go vertical (#80). Same threshold as
    /// `DataPointsSection` and `MapBottomCard.usesStackedLayout(for:)`; an
    /// explicit switch rather than `ViewThatFits`, whose ideal-width check
    /// an `HStack`'s equal split then undercuts (#70).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    private var isOpen: Binding<Bool> {
        Binding(get: { !entry.isClosed }, set: { entry.isClosed = !$0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOpen) {
                let labelLayout = isStacked
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout())
                labelLayout {
                    DayLabel(text: entry.label)
                        .frame(minWidth: dayLabelMinWidth, alignment: .leading)
                    // Open rows already show their time fields below; only
                    // the collapsed (closed) state needs spelling out.
                    if entry.isClosed {
                        Text("Closed")
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .accessibilityLabel("\(entry.label) open")
            if !entry.isClosed {
                let fieldsLayout = isStacked
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout())
                fieldsLayout {
                    TextField("Open", text: $entry.open)
                    if isStacked {
                        // Stacked, the dash leads the close line so two bare
                        // values ("12" over "8") still read as a range.
                        HStack(spacing: 4) {
                            Text("–")
                            TextField("Close", text: $entry.close)
                        }
                    } else {
                        Text("–")
                        TextField("Close", text: $entry.close)
                    }
                }
                .font(.subheadline)
                .monospacedDigit()
            }
        }
    }
}
