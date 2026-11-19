import PhotosUI
import SwiftUI

/// The open photo viewer's input (eng O3): the gallery as it was when a
/// thumbnail was tapped, and that thumbnail's photo.
struct PhotoViewerSession: Identifiable {
    let id = UUID()
    let photos: [Photo]
    let initialID: Photo.ID
}

/// Always rendered (unlike before Add-a-Photo existed, when it hid itself
/// with no photos) so the "Add a Photo" picker is reachable on a bodega
/// with an empty gallery. Each thumbnail opens the full-screen viewer and
/// is its zoom transition's source (#107).
struct PhotoGallerySection: View {
    /// DESIGN.md Shapes: `{rounded.md}` for photo thumbnails (design D20).
    private static let thumbnailRadius: CGFloat = 12
    private static let thumbnailSize: CGFloat = 120

    /// The picker's limit (#107 spec D1).
    static let maxPickCount = 10

    let photos: [Photo]
    let urlFor: (Photo) -> URL?
    @Binding var pickedItems: [PhotosPickerItem]
    let namespace: Namespace.ID
    /// Scrolled into view on change: the viewer's page (no animation: the
    /// gallery is under the cover while it changes), or the first photo
    /// after an upload, to the leading edge (design D16).
    let scrollTarget: Photo.ID?
    /// New thumbnails' insert transition (`PhotoMotion.InsertStyle`).
    let insertTransition: AnyTransition
    var focusedPhotoID: AccessibilityFocusState<Photo.ID?>.Binding
    let onOpen: (Photo) -> Void
    let onFlag: (Photo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailButtonRow {
                Text(AppCopy.photosSectionLabel.copy.text).font(.headline)
            } buttons: {
                PhotosPicker(
                    selection: $pickedItems,
                    maxSelectionCount: Self.maxPickCount,
                    selectionBehavior: .ordered,
                    matching: .images
                ) {
                    Label(AppCopy.addPhotoAction.copy.text, systemImage: "photo.badge.plus")
                }
                .buttonStyle(.bordered)
            }
            if photos.isEmpty {
                SectionEmptyState(title: .emptyNoPhotosTitle, message: .emptyNoPhotosBody)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                                thumbnail(photo, index: index)
                                    .transition(insertTransition)
                            }
                        }
                    }
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        if target == photos.first?.id {
                            // The leading edge: after an upload (design D16)
                            // this runs on screen, so it moves with the insert;
                            // under the viewer's cover the animation is unseen.
                            withAnimation(PhotoMotion.insertAnimation) { proxy.scrollTo(target, anchor: .leading) }
                        } else {
                            withoutAnimation { proxy.scrollTo(target, anchor: .center) }
                        }
                    }
                }
            }
        }
    }

    private func thumbnail(_ photo: Photo, index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.thumbnailRadius)
        return Button { onOpen(photo) } label: {
            AsyncImage(url: urlFor(photo)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: photo.id, in: namespace) { source in
            source.clipShape(shape)
        }
        .id(photo.id)
        .accessibilityLabel(AppCopy.photoPositionLabel(index: index, count: photos.count).text)
        .accessibilityValue(photo.caption ?? "")
        .accessibilityHint(AppCopy.photoOpensFullScreenHint.copy.text)
        .accessibilityFocused(focusedPhotoID, equals: photo.id)
        .contextMenu {
            Button(AppCopy.flagPhotoAction.copy.text, systemImage: "flag") { onFlag(photo) }
        }
    }
}
