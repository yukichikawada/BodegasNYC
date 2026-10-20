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
    let onSubmitted: (Bodega) -> Void

    private var isEditing: Bool { viewModel.isEditing }

    var body: some View {
        NavigationStack {
            Form {
                // Tutorial (#22): the form tip sits above Basics on Add only;
                // Edit Bodega never shows it.
                if !isEditing {
                    TipView(FormTip())
                        .inlineBodegaTipStyle()
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
                Section("Hours") {
                    ForEach($viewModel.dayEntries) { $entry in
                        DayHoursRow(entry: $entry)
                    }
                }
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
                if case .submitted(let bodega) = newValue { onSubmitted(bodega) }
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
            .sheet(
                isPresented: Binding(
                    get: { viewModel.submissionState == .signInRequired },
                    set: { isPresented in
                        if !isPresented { viewModel.dismissSignInPrompt() }
                    }
                )
            ) {
                // Design DD10: a half sheet over the form, not a full one.
                SignInView(sessionStore: sessionStore)
                    .presentationDetents([.medium])
                    .presentationBackground(.regularMaterial)
            }
        }
    }
}

/// One weekday's hours. The toggle is titled with the day ("Mon"..."Sun",
/// same labels and width as `HoursSection` on the detail screen) and its
/// on state means *open*; the stored `isClosed` is just its inverse.
/// Shared by Add and Edit Bodega (both are this same `AddBodegaView`).
private struct DayHoursRow: View {
    @Binding var entry: AddBodegaViewModel.DayEntry

    private var isOpen: Binding<Bool> {
        Binding(get: { !entry.isClosed }, set: { entry.isClosed = !$0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOpen) {
                HStack {
                    // Never truncate/wrap the day at large Dynamic Type sizes.
                    Text(entry.label)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 40, alignment: .leading)
                    // Open rows already show their time fields below; only
                    // the collapsed (closed) state needs spelling out.
                    if entry.isClosed {
                        Text("Closed").foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityLabel("\(entry.label) open")
            if !entry.isClosed {
                HStack {
                    TextField("Open", text: $entry.open)
                    Text("–")
                    TextField("Close", text: $entry.close)
                }
                .font(.subheadline)
            }
        }
    }
}
