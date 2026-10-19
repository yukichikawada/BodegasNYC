import SwiftUI

/// Presented as `.sheet(item:)` from `BodegaDetailView` for any
/// `FlagTarget` — the bodega's "Flag an Issue" button, or the context menu on
/// a review row or gallery photo. Same form for all three; only the title
/// differs, driven off `viewModel.target`.
struct FlagIssueView: View {
    @Bindable var viewModel: FlagIssueViewModel
    let sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss
    let onSubmitted: (Flag) -> Void

    private var title: String {
        switch viewModel.target {
        case .bodega: "Flag This Bodega"
        case .review: "Flag This Review"
        case .photo: "Flag This Photo"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What's wrong?") {
                    Picker("Reason", selection: $viewModel.reason) {
                        ForEach(viewModel.reasonOptions) { reason in
                            Text(reason.rawValue).tag(reason)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Details (optional)") {
                    TextEditor(text: $viewModel.details)
                        .frame(minHeight: 80)
                }
                if case .failed(let message) = viewModel.submissionState {
                    Section { Text(message).foregroundStyle(.red).font(.footnote) }
                }
            }
            // Same rationale as AddReviewView: submit() already snapshotted
            // the fields before the await, so disabling here just prevents
            // confusing double-edits mid-flight, not data loss.
            .disabled(viewModel.submissionState == .submitting)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { viewModel.submit() }
                        .disabled(viewModel.submissionState == .submitting)
                }
            }
            .overlay { if viewModel.submissionState == .submitting { ProgressView() } }
            .interactiveDismissDisabled(viewModel.submissionState == .submitting)
            .onChange(of: viewModel.submissionState) { _, newValue in
                if case .submitted(let flag) = newValue { onSubmitted(flag) }
            }
            // Manual Binding, not .onChange-driven — mirrors AddReviewView's
            // sign-in sheet exactly: a re-tap of Submit while still signed
            // out re-assigns the same .signInRequired case, which .onChange
            // wouldn't detect as a change.
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
