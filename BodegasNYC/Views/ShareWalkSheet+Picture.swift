import LinkPresentation
import SwiftUI
import UIKit

/// The form's preview (#177 DS4): the picture itself, 4:5, 12 pt radius, on
/// `secondarySystemBackground`. While a picture is made the last one shows
/// at 40% under a spinner and "Making the picture…"; a failure shows its
/// line and Retry instead; with no blocks or too many there is no picture.
/// VoiceOver reads the picture as one image, "Map of the walk you're
/// sharing.", valued with the dates, counts, distance and estimate status.
struct ShareWalkPicturePanel: View {
    let form: ShareWalkForm
    let retry: () -> Void

    var body: some View {
        let phase = form.phase
        ZStack {
            Color(.secondarySystemBackground)
            if let picture = form.picture, phase == .making || phase == .ready {
                Image(uiImage: picture.image)
                    .resizable()
                    .scaledToFit()
                    .opacity(phase == .making ? 0.4 : 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(AppCopy.ShareWalk.pictureLabel.copy.text)
                    .accessibilityValue(AppCopy.sharedWalkPictureValue(picture.walk).text)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityHidden(phase == .making)
                    .accessibilityIdentifier("shareWalk.picture")
            }
            switch phase {
            case .making:
                VStack(spacing: 8) {
                    ProgressView()
                    Text(AppCopy.ShareWalk.makingPicture.withTrailingEllipsis)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                .accessibilityElement(children: .combine)
            case .failed:
                VStack(spacing: 12) {
                    Text(AppCopy.ShareWalk.pictureFailed.copy.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(AppCopy.retryAction.copy.text, action: retry)
                        .buttonStyle(.bordered)
                }
                .padding(16)
            case .ready, .noBlocks, .tooManyBlocks:
                EmptyView()
            }
        }
        .aspectRatio(SharedWalkCard.size.width / SharedWalkCard.size.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity)
    }
}

/// Presents the system share sheet (#177 DS5) from a zero-size controller
/// behind the form while `picture` is set, with two items in order: the
/// picture, titled "Walk, Nov 3–9, 2026" for the sheet's header, and the
/// text line. `onFinish` gets whether a destination completed.
struct ShareSheetPresenter: UIViewControllerRepresentable {
    @Binding var picture: SharedWalkPicture?
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.finish = { completed in
            picture = nil
            onFinish(completed)
        }
        guard let picture, !coordinator.isPresenting else { return }
        coordinator.isPresenting = true
        let controller = UIActivityViewController(activityItems: Self.items(for: picture), applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in coordinator.didFinish(completed: completed) }
        }
        host.present(controller, animated: true)
    }

    /// The share's items, in order (DS5): the picture, then the text.
    static func items(for picture: SharedWalkPicture) -> [Any] {
        [
            SharedWalkImageItem(image: picture.image, title: AppCopy.sharedWalkLinkTitle(picture.walk).text),
            AppCopy.sharedWalkText(picture.walk).text
        ]
    }

    final class Coordinator {
        var isPresenting = false
        var finish: (Bool) -> Void = { _ in }

        func didFinish(completed: Bool) {
            isPresenting = false
            finish(completed)
        }
    }
}

/// The picture as a share item with link metadata, so the sheet's header
/// reads "Walk, Nov 3–9, 2026" over the picture rather than "PNG Image".
nonisolated final class SharedWalkImageItem: NSObject, UIActivityItemSource {
    let image: UIImage
    let title: String

    init(image: UIImage, title: String) {
        self.image = image
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        image
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        image
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(object: image)
        metadata.iconProvider = NSItemProvider(object: image)
        return metadata
    }
}
