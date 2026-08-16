import SwiftUI

/// Presented as `.sheet(item:)` from `BodegaDetailView`. Doubles as both
/// "Add a review" (`viewModel.existingReview == nil`) and "Edit your review"
/// (pre-filled from it) — same view either way, only title/button label and
/// starting field values differ, driven off `existingReview`.
struct AddReviewView: View {
    @Bindable var viewModel: AddReviewViewModel
    let sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss
    let onSubmitted: (Review) -> Void

    private var isEditing: Bool { viewModel.existingReview != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your Rating") {
                    StarRatingPicker(rating: $viewModel.rating)
                }
                Section("Review (optional)") {
                    TextEditor(text: $viewModel.body)
                        .frame(minHeight: 100)
                }
                if case .failed(let message) = viewModel.submissionState {
                    Section { Text(message).foregroundStyle(.red).font(.footnote) }
                }
            }
            // Same rationale as AddBodegaView: submit() already snapshotted
            // the fields before the await, so disabling here just prevents
            // confusing double-edits mid-flight, not data loss.
            .disabled(viewModel.submissionState == .submitting)
            .navigationTitle(isEditing ? "Edit Your Review" : "Add a Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Submit") { viewModel.submit() }
                        .disabled(!viewModel.isRatingValid || viewModel.submissionState == .submitting)
                }
            }
            .overlay { if viewModel.submissionState == .submitting { ProgressView() } }
            .interactiveDismissDisabled(viewModel.submissionState == .submitting)
            .onChange(of: viewModel.submissionState) { _, newValue in
                if case .submitted(let review) = newValue { onSubmitted(review) }
            }
            // Manual Binding, not .onChange-driven — mirrors AddBodegaView's
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

private struct StarRatingPicker: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .foregroundStyle(.yellow)
                    .font(.title2)
                    .onTapGesture { rating = star }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue("\(rating) out of 5 stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: rating = min(5, rating + 1)
            case .decrement: rating = max(1, rating - 1)
            default: break
            }
        }
    }
}
