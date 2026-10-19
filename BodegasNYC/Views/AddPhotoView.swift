import SwiftUI
import UIKit

/// Presented as `.sheet(item:)` from `BodegaDetailView` right after the user
/// picks an image in its `PhotosPicker`: a preview plus an Upload button.
/// The confirmation step exists so the sign-in gate can sit on Upload
/// (matching Submit in `AddReviewView`) instead of on the picker itself.
struct AddPhotoView: View {
    @Bindable var viewModel: AddPhotoViewModel
    let sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss
    let onSubmitted: (Photo) -> Void

    /// Decoded off the main actor in `.task` (a thumbnail, not the full
    /// image) — decoding a full-size library photo synchronously in `body`
    /// would stall the sheet's presentation.
    @State private var preview: UIImage?
    @State private var previewFailed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                previewArea
                if case .failed(let message) = viewModel.submissionState {
                    Text(message).foregroundStyle(.red).font(.footnote)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Add a Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(viewModel.submissionState == .submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") { viewModel.submit() }
                        .disabled(viewModel.submissionState == .submitting)
                }
            }
            .overlay { if viewModel.submissionState == .submitting { ProgressView() } }
            .interactiveDismissDisabled(viewModel.submissionState == .submitting)
            .task { await loadPreview() }
            .onChange(of: viewModel.submissionState) { _, newValue in
                if case .submitted(let photo) = newValue { onSubmitted(photo) }
            }
            // Manual Binding, not .onChange-driven — mirrors AddReviewView's
            // sign-in sheet exactly: a re-tap of Upload while still signed
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

    @ViewBuilder
    private var previewArea: some View {
        if let preview {
            Image(uiImage: preview)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Selected photo")
        } else if previewFailed {
            ContentUnavailableView("No Preview", systemImage: "photo")
                .frame(maxHeight: 360)
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 240)
                .overlay { ProgressView() }
        }
    }

    private func loadPreview() async {
        let data = viewModel.imageData
        let thumbnail = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let image = UIImage(data: data) else { return nil }
            // preparingThumbnail(of:) renders at exactly the size passed,
            // so compute an aspect-preserving one first.
            let longEdge = max(image.size.width, image.size.height)
            let ratio = min(1, 900 / max(longEdge, 1))
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            return image.preparingThumbnail(of: size) ?? image
        }.value
        preview = thumbnail
        previewFailed = thumbnail == nil
    }
}
