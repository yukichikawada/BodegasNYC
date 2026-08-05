import SwiftUI

/// Presented as `.sheet(item:)` from `BrowseView` once a placement
/// coordinate is confirmed. Composition follows `BodegaDetailView`'s
/// section-per-private-struct convention, as a `Form` inside its own
/// `NavigationStack` (normal for sheet content — doesn't conflict with
/// `BrowseView`'s outer stack/`path`).
struct AddBodegaView: View {
    @Bindable var viewModel: AddBodegaViewModel
    let sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss
    let onSubmitted: (Bodega) -> Void

    var body: some View {
        NavigationStack {
            Form {
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
            .navigationTitle("Add a Bodega")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { viewModel.submit() }
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
                SignInView(sessionStore: sessionStore)
            }
        }
    }
}

private struct DayHoursRow: View {
    @Binding var entry: AddBodegaViewModel.DayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Closed", isOn: $entry.isClosed)
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
