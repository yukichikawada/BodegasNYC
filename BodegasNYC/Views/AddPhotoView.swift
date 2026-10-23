import SwiftUI
import UIKit

/// The Add Photos sheet (#107 PR 2), presented as `.sheet(item:)` from
/// `BodegaDetailView` the moment its picker closes: one row per pick with an
/// optional caption, uploaded one at a time on Upload. The sign-in gate sits
/// on Upload (matching Submit in `AddReviewView`), not on the picker.
///
/// Layout (design D12): exactly one pick gets the large preview with the
/// caption below it; two to ten get an inset-grouped row list. Rows follow
/// the `BodegaRow` idiom at accessibility sizes (design D18).
///
/// Status is neutral and shape-coded (design D9): no symbol while waiting,
/// an untinted spinner while preparing or uploading, `checkmark.circle`
/// `.secondary` once up, `exclamationmark.circle` `.primary` with "Didn't go
/// through" on a failure. No red or green.
struct AddPhotoView: View {
    @Bindable var viewModel: AddPhotoViewModel
    /// Shown as the navigation subtitle (design D22).
    let bodegaName: String
    let sessionStore: SessionStore
    /// Called once nothing is left to send; the parent closes the sheet.
    let onSubmitted: ([Photo]) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedItemID: AddPhotoViewModel.Item.ID?
    @State private var showingDiscardConfirmation = false
    @State private var preview: LocalPreview?
    @State private var previewCurrentID: UUID?

    /// The local viewer's batch, frozen when it opens (design D13).
    private struct LocalPreview: Identifiable {
        let id = UUID()
        let items: [PhotoViewerItem]
        let initialID: UUID
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.showsSinglePhotoLayout {
                    singlePhotoSections
                } else {
                    rowsSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationSubtitle(bodegaName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .interactiveDismissDisabled(viewModel.isSubmitting || viewModel.needsDiscardConfirmation)
            .task { await viewModel.loadPickedPhotos() }
            .onChange(of: viewModel.submissionState) { _, newValue in
                if case .submitted(let photos) = newValue { onSubmitted(photos) }
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
            .confirmationDialog(
                AppCopy.discardPhotosTitle(viewModel.unsentCount).text,
                isPresented: $showingDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button(AppCopy.discardAction.copy.text, role: .destructive) { dismiss() }
                Button(AppCopy.cancelAction.copy.text, role: .cancel) {}
            }
            .alert(
                AppCopy.photosUnloadableTitle(viewModel.unloadableCount).text,
                isPresented: Binding(get: { viewModel.loadFailedEntirely }, set: { _ in })
            ) {
                Button(AppCopy.okAction.copy.text, role: .cancel) { dismiss() }
            } message: {
                Text(AddPhotoViewModel.unreadableImageMessage)
            }
            .fullScreenCover(item: $preview, onDismiss: { previewCurrentID = nil }, content: { preview in
                PhotoViewer(
                    items: preview.items,
                    currentID: Binding(
                        get: { previewCurrentID ?? preview.initialID },
                        set: { previewCurrentID = $0 }
                    ),
                    makeFlagViewModel: nil,
                    sessionStore: sessionStore
                )
            })
        }
    }

    private var title: String {
        (viewModel.showsSinglePhotoLayout ? AppCopy.addOnePhotoTitle : AppCopy.addPhotoAction).copy.text
    }

    // MARK: Toolbar (design D10)

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            switch viewModel.leadingAction {
            case .cancel:
                Button(AppCopy.cancelAction.copy.text, action: close)
            case .stop:
                Button(AppCopy.stopAction.copy.text) { viewModel.stop() }
                    .accessibilityIdentifier("addPhoto.stop")
            case .done:
                Button(AppCopy.doneAction.copy.text, action: close)
                    .accessibilityIdentifier("addPhoto.done")
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(uploadLabel) {
                focusedItemID = nil
                viewModel.submit()
            }
            .disabled(!viewModel.canSubmit)
            .accessibilityIdentifier("addPhoto.upload")
        }
    }

    private var uploadLabel: String {
        viewModel.submissionState == .partiallyFailed
            ? AppCopy.retryCountLabel(viewModel.failedCount).text
            : AppCopy.uploadAction.copy.text
    }

    /// Cancel or Done: asks first only when a caption would be lost.
    private func close() {
        if viewModel.needsDiscardConfirmation {
            showingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    // MARK: Layouts

    @ViewBuilder
    private var singlePhotoSections: some View {
        if let item = viewModel.items.first {
            Section {
                singlePreview(item)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                AddPhotoCaptionArea(
                    item: item,
                    index: 0,
                    caption: captionBinding(for: item),
                    focusedItemID: $focusedItemID
                )
                .animation(PhotoMotion.rowStatusAnimation, value: item.state)
            } footer: {
                footer
            }
        } else {
            Section {} footer: { footer }
        }
    }

    @ViewBuilder
    private func singlePreview(_ item: AddPhotoViewModel.Item) -> some View {
        let shape = RoundedRectangle(cornerRadius: AddPhotoRow.thumbnailRadius)
        if let thumbnail = item.thumbnail {
            Button { openPreview(at: item.id) } label: {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 360)
                    .clipShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppCopy.selectedPhotoLabel.copy.text)
            .accessibilityValue(item.caption)
            .accessibilityHint(AppCopy.photoOpensFullScreenHint.copy.text)
        } else {
            shape
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 240)
                .overlay { ProgressView() }
        }
    }

    private var rowsSection: some View {
        Section {
            ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                AddPhotoRow(
                    item: item,
                    index: index,
                    count: viewModel.items.count,
                    caption: captionBinding(for: item),
                    focusedItemID: $focusedItemID,
                    onOpen: { openPreview(at: item.id) }
                )
                .animation(PhotoMotion.rowStatusAnimation, value: item.state)
                .swipeActions(edge: .trailing) {
                    if canRemove(item) {
                        Button(role: .destructive) { viewModel.remove(itemID: item.id) } label: {
                            Label(AppCopy.removeAction.copy.text, systemImage: "trash")
                        }
                    }
                }
                .accessibilityActions {
                    if canRemove(item) {
                        Button(AppCopy.removeAction.copy.text) { viewModel.remove(itemID: item.id) }
                    }
                }
                .accessibilityIdentifier("addPhoto.row.\(index)")
            }
        } footer: {
            footer
        }
    }

    private func canRemove(_ item: AddPhotoViewModel.Item) -> Bool {
        item.isRemovable && !viewModel.isSubmitting
    }

    /// Unloadable picks, the optional-captions note, then progress or the
    /// failed-pass line (design D10, D11, D14).
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if viewModel.unloadableCount > 0 {
                Text(AppCopy.photosUnloadable(viewModel.unloadableCount).text)
                    .foregroundStyle(.primary)
            }
            if let progress = viewModel.passProgress, viewModel.isSubmitting {
                Text(AppCopy.uploadProgress(index: progress.index, count: progress.count).text)
                    .foregroundStyle(Color.textMuted)
                    .monospacedDigit()
                    .accessibilityIdentifier("addPhoto.progress")
            } else if viewModel.submissionState == .partiallyFailed {
                Text(
                    AppCopy.uploadPassFailed(
                        uploaded: viewModel.uploadedPhotos.count,
                        failed: viewModel.failedCount
                    ).text
                )
                .foregroundStyle(.primary)
                .accessibilityIdentifier("addPhoto.passFailed")
            } else {
                Text(AppCopy.captionsOptionalFooter.copy.text)
            }
        }
        .font(.footnote)
    }

    // MARK: Captions and focus (design D14)

    /// Return (a typed newline) moves to the next editable caption, or
    /// closes the keyboard on the last one; the newline itself is dropped.
    private func captionBinding(for item: AddPhotoViewModel.Item) -> Binding<String> {
        Binding(
            get: { viewModel.items.first { $0.id == item.id }?.caption ?? "" },
            set: { newValue in
                guard newValue.contains(where: \.isNewline) else {
                    viewModel.setCaption(newValue, for: item.id)
                    return
                }
                var stripped = newValue
                while stripped.last?.isNewline == true { stripped.removeLast() }
                viewModel.setCaption(stripped, for: item.id)
                focusedItemID = nextEditableID(after: item.id)
            }
        )
    }

    private func nextEditableID(after id: UUID) -> UUID? {
        guard let index = viewModel.items.firstIndex(where: { $0.id == id }) else { return nil }
        return viewModel.items[(index + 1)...].first(where: \.isCaptionEditable)?.id
    }

    private func openPreview(at id: UUID) {
        let items = viewModel.items.compactMap { item in
            item.jpeg.map { PhotoViewerItem(id: item.id, source: .local($0), caption: nil) }
        }
        guard items.contains(where: { $0.id == id }) else { return }
        focusedItemID = nil
        previewCurrentID = id
        preview = LocalPreview(items: items, initialID: id)
    }
}
