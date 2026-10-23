import SwiftUI
import UIKit

// MARK: - Items

/// One viewer page's input: a gallery photo (its public URL and caption) or,
/// in local mode, a prepared JPEG from the upload sheet.
struct PhotoViewerItem: Identifiable {
    enum Source {
        case remote(URL?)
        case local(Data)
    }

    let id: UUID
    let source: Source
    let caption: String?

    static func gallery(_ photos: [Photo], urlFor: (Photo) -> URL?) -> [PhotoViewerItem] {
        photos.map { PhotoViewerItem(id: $0.id, source: .remote(urlFor($0)), caption: $0.caption) }
    }
}

// MARK: - Caption band (design D2)

/// The caption under the photo: opaque, `.body` `.primary`, three lines,
/// leading, 16pt inset. "More" appears only when the text is cut off and
/// expands it into a scroll area capped at `maxExpandedHeight`. It takes
/// its own taps, so a tap on it never toggles the controls.
struct PhotoCaptionBand: View {
    let caption: String
    let maxExpandedHeight: CGFloat
    @Binding var isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0

    private var isTruncated: Bool { fullHeight > collapsedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isExpanded {
                ScrollView {
                    text.fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: min(fullHeight, max(maxExpandedHeight, 0)))
                .accessibilityIdentifier("photoViewer.captionScroll")
            } else {
                text
                    .lineLimit(PhotoMotion.captionCollapsedLines)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { collapsedHeight = $0 }
                if isTruncated {
                    Button(AppCopy.captionMoreAction.copy.text) {
                        withAnimation(PhotoMotion.captionExpandAnimation(reduceMotion: reduceMotion)) {
                            isExpanded = true
                        }
                    }
                    .font(.body)
                    .accessibilityIdentifier("photoViewer.captionMore")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            // The full text at the band's width, never drawn: how tall it
            // is decides whether "More" shows and how tall the scroll is.
            text
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { fullHeight = $0 }
                .accessibilityHidden(true)
        }
        .padding(16)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea(edges: .bottom))
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    /// Hidden from VoiceOver, which already reads the caption as the page
    /// image's value ("Photo N of M", caption; design D19), so it is spoken
    /// once. Keyed to VoiceOver rather than always hidden so the band's text
    /// stays inspectable (UI tests, accessibility dumps) without it.
    private var text: some View {
        Text(caption)
            .font(.body)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(voiceOverEnabled)
            .accessibilityIdentifier("photoViewer.captionText")
    }
}
