import SwiftUI
import UIKit

// MARK: - Page

/// One page: loading, the zoomable photo, or the failure state (design D17)
/// whose Retry reloads this page only.
struct PhotoPage: View {
    let source: PhotoViewerItem.Source
    let isCurrent: Bool
    let label: String
    let caption: String?
    /// The caption band's cover over the page's bottom (PR 2).
    let bottomObstruction: CGFloat
    let zoomCommand: PhotoZoomCommand?
    let onSingleTap: () -> Void
    let onZoomAction: (PhotoZoomCommand.Action) -> Void
    let onZoomCommandApplied: (Int) -> Void
    let onSwipeDownChanged: (CGFloat) -> Void
    let onSwipeDownEnded: (Bool) -> Void

    private enum Phase {
        case loading
        case loaded(UIImage)
        case failed
    }

    @State private var phase: Phase = .loading
    @State private var attempt = 0

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSingleTap)
            case .loaded(let image):
                ZoomableImagePage(
                    image: image,
                    isCurrent: isCurrent,
                    bottomObstruction: bottomObstruction,
                    zoomCommand: zoomCommand,
                    onZoomCommandApplied: onZoomCommandApplied,
                    onSingleTap: onSingleTap,
                    onSwipeDownChanged: onSwipeDownChanged,
                    onSwipeDownEnded: onSwipeDownEnded
                )
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityValue(caption ?? "")
                .accessibilityAddTraits(.isImage)
                .accessibilityAction(named: AppCopy.photoZoomInAction.copy.text) { onZoomAction(.zoomIn) }
                .accessibilityAction(named: AppCopy.photoResetZoomAction.copy.text) { onZoomAction(.reset) }
            case .failed:
                failure
            }
        }
        // The page is the whole screen whether or not the bars show, so
        // the photo is centred on the screen and never moves when the
        // controls toggle (QA P2).
        .ignoresSafeArea()
        .task(id: attempt) { await load() }
    }

    private var failure: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(AppCopy.photoLoadFailedBody.copy.text)
                .font(.body)
                .foregroundStyle(.primary)
            Button(AppCopy.retryAction.copy.text) {
                phase = .loading
                attempt += 1
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        // Centred above the caption band, never under it.
        .padding(.bottom, bottomObstruction)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSingleTap)
    }

    /// `URLSession.shared`, so the enlarged `URLCache.shared` (eng C3)
    /// serves a photo the gallery thumbnail already fetched. A page that
    /// scrolls back into view keeps its image.
    private func load() async {
        if case .loaded = phase { return }
        let url: URL
        switch source {
        case .local(let data):
            // A prepared ≤1600px JPEG from the upload sheet (design D13).
            let image = await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
            let prepared = await image?.byPreparingForDisplay() ?? image
            guard !Task.isCancelled else { return }
            phase = prepared.map(Phase.loaded) ?? .failed
            return
        case .remote(nil):
            phase = .failed
            return
        case .remote(let remote?):
            url = remote
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let statusOK = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
            guard statusOK, let image = UIImage(data: data) else {
                phase = .failed
                return
            }
            let prepared = await image.byPreparingForDisplay() ?? image
            guard !Task.isCancelled else { return }
            phase = .loaded(prepared)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }
}
