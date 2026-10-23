import SwiftUI
import UIKit

// MARK: - Row

/// One pick in the list: a 64pt thumbnail that opens the local viewer, the
/// caption (a field while editable, plain text once locked), and its status.
/// At accessibility sizes it stacks; otherwise side by side when it fits
/// (the `BodegaRow` idiom, design D18).
struct AddPhotoRow: View {
    static let thumbnailSize: CGFloat = 64
    /// DESIGN.md `{rounded.md}`.
    static let thumbnailRadius: CGFloat = 12

    let item: AddPhotoViewModel.Item
    let index: Int
    let count: Int
    @Binding var caption: String
    var focusedItemID: FocusState<AddPhotoViewModel.Item.ID?>.Binding
    let onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                sideBySide
                stacked
            }
        }
    }

    private var sideBySide: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            captionArea
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            captionArea
        }
    }

    private var captionArea: some View {
        AddPhotoCaptionArea(item: item, index: index, caption: $caption, focusedItemID: focusedItemID)
    }

    @ViewBuilder
    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: Self.thumbnailRadius)
        if let image = item.thumbnail {
            Button(action: onOpen) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                    .clipShape(shape)
                    .contentShape(shape)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(AppCopy.photoPositionLabel(index: index, count: count).text)
            .accessibilityValue(AddPhotoViewModel.normalizedCaption(item.caption) ?? "")
            .accessibilityHint(AppCopy.photoOpensFullScreenHint.copy.text)
        } else {
            // Preparation placeholder (design D11).
            shape
                .fill(Color.secondary.opacity(0.2))
                .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                .overlay { ProgressView() }
                .accessibilityHidden(true)
        }
    }
}

/// The caption and status under (or beside) a photo: a field while the
/// caption is editable, plain `.body` text once it is locked (nothing when
/// empty), the counter from 120 characters, and the status symbol.
struct AddPhotoCaptionArea: View {
    let item: AddPhotoViewModel.Item
    let index: Int
    @Binding var caption: String
    var focusedItemID: FocusState<AddPhotoViewModel.Item.ID?>.Binding

    private var length: Int { AddPhotoViewModel.captionLength(item.caption) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                captionContent
                if item.isCaptionEditable, length >= AddPhotoViewModel.captionCounterThreshold {
                    Text(AppCopy.captionCount(length, limit: AddPhotoViewModel.captionLimit).text)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(length > AddPhotoViewModel.captionLimit ? Color.red : Color.textMuted)
                }
                if item.state == .failed {
                    Text(AppCopy.photoUploadFailedValue.copy.text)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            status
        }
    }

    @ViewBuilder
    private var captionContent: some View {
        if item.isCaptionEditable {
            TextField(AppCopy.captionPlaceholder.copy.text, text: $caption, axis: .vertical)
                .font(.body)
                .submitLabel(.next)
                .focused(focusedItemID, equals: item.id)
                .accessibilityLabel(AppCopy.captionFieldLabel(index: index).text)
                .accessibilityIdentifier("addPhoto.caption.\(index)")
        } else if let locked = AddPhotoViewModel.normalizedCaption(item.caption) {
            Text(locked)
                .font(.body)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("addPhoto.lockedCaption.\(index)")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .idle:
            EmptyView()
        case .preparing, .uploading:
            ProgressView()
        case .uploaded:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(AppCopy.photoUploadedValue.copy.text)
                .accessibilityIdentifier("addPhoto.uploaded.\(index)")
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
        }
    }
}
