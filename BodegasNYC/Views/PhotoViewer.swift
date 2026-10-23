import SwiftUI
import UIKit

/// The full-screen photo viewer (#107 PR 1), presented as a
/// `.fullScreenCover` from a gallery thumbnail with the zoom transition.
///
/// Takes a snapshot of the gallery's photos at open (eng O3): nothing
/// elsewhere changes them while it is up, and a flag does not refetch.
/// `currentID` starts at the tapped photo and reports the page back, so the
/// gallery can scroll that thumbnail into view before the return zoom.
///
/// Pages are `TabView(.page)`; each page is a `UIScrollView` zoom page
/// (eng C2: SwiftUI pinch inside a paged container loses to the pager). At
/// 1x the image fits the bounds exactly, so horizontal pans go to the pager;
/// zoomed, the page's own scroll view takes them, so paging only happens at
/// 1x.
///
/// Always dark, as in Photos (design D3); semantic colors only. Controls
/// show on open and never auto-hide; a single tap toggles them (opacity,
/// `PhotoMotion.chromeSeconds`), except under VoiceOver where they stay.
///
/// A photo with a caption shows it in an opaque band over the bottom of the
/// page while the controls are visible (design D2, PR 2). The page stays full
/// screen (QA P2); the zoom page fits and centres the photo in the space
/// above the band. Hiding the controls hides the band and the photo gets
/// the full screen.
///
/// The upload sheet opens it in local mode (design D13): prepared JPEGs, no
/// Flag menu (`makeFlagViewModel` is `nil`) and no captions.
struct PhotoViewer: View {
    let items: [PhotoViewerItem]
    @Binding var currentID: PhotoViewerItem.ID
    /// Builds the flag form for a photo; the sheet is presented over the
    /// viewer, which stays open (eng A2). `nil` hides the menu.
    let makeFlagViewModel: ((Photo.ID) -> FlagIssueViewModel)?
    let sessionStore: SessionStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// The app's scheme, read above the viewer's own forced-dark
    /// environment: the flag sheet is a standard form and keeps it.
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var controlsVisible = true
    @State private var groundOpacity: Double = 1
    @State private var zoomRequests = PhotoZoomRequests()
    @State private var flagIssueViewModel: FlagIssueViewModel?
    /// Same hand-off as `BodegaDetailView`: the alert is shown from the
    /// sheet's `onDismiss`, never while the sheet is still leaving.
    @State private var flagSubmittedPendingConfirmation = false
    @State private var showingFlagConfirmation = false
    @State private var captionExpanded = false
    /// The viewer's full-screen frame and the band's top edge, both global:
    /// the band covers `viewerFrame.maxY - bandTop` of the page's bottom.
    @State private var viewerFrame: CGRect = .zero
    @State private var bandTop: CGFloat = 0
    /// VoiceOver focus goes back to the menu button after the flag sheet
    /// closes (design D19).
    @AccessibilityFocusState private var menuFocused: Bool

    private var position: PhotoViewerPosition {
        PhotoViewerPosition(ids: items.map(\.id), currentID: currentID)
    }

    private var showsControls: Bool { controlsVisible || voiceOverEnabled }

    private var currentCaption: String? {
        items.first { $0.id == currentID }?.caption
    }

    /// The band is up only with the controls and a caption.
    private var bandCaption: String? { showsControls ? currentCaption : nil }

    /// How much of the page's bottom the band covers; 0 without a band.
    private var bandObstruction: CGFloat {
        guard bandCaption != nil, bandTop > 0 else { return 0 }
        return max(0, viewerFrame.maxY - bandTop)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)
                    .opacity(groundOpacity)
                    .ignoresSafeArea()
                pager
                // The band overlays the bottom of the full-screen page (the
                // page never resizes, QA P2); the page fits the photo in the
                // space above it through `bandObstruction`.
                if let bandCaption {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        PhotoCaptionBand(
                            caption: bandCaption,
                            maxExpandedHeight: viewerFrame.height * PhotoMotion.captionMaxHeightFraction,
                            isExpanded: $captionExpanded
                        )
                        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }, action: {
                            bandTop = $0
                        })
                    }
                    .opacity(groundOpacity)
                    .transition(.opacity)
                }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { viewerFrame = $0 })
            .ignoresSafeArea()
            .containerBackground(.clear, for: .navigation)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { controls }
            .toolbarVisibility(showsControls ? .visible : .hidden, for: .navigationBar)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(showsControls ? .automatic : .hidden)
        .environment(\.colorScheme, .dark)
        .presentationBackground(.clear)
        .accessibilityAction(.escape) { dismiss() }
        .onChange(of: currentID) {
            zoomRequests.pageChanged()
            captionExpanded = false
            AccessibilityNotification.Announcement(position.announcement.text).post()
        }
        .onChange(of: showsControls) { _, visible in
            if !visible { captionExpanded = false }
        }
        .sheet(item: $flagIssueViewModel, onDismiss: {
            if flagSubmittedPendingConfirmation {
                flagSubmittedPendingConfirmation = false
                showingFlagConfirmation = true
            } else {
                menuFocused = true
            }
        }, content: { flagIssueViewModel in
            FlagIssueView(viewModel: flagIssueViewModel, sessionStore: sessionStore) { _ in
                flagSubmittedPendingConfirmation = true
                self.flagIssueViewModel = nil
            }
            .environment(\.colorScheme, systemColorScheme)
        })
        .alert(AppCopy.flagSubmittedTitle.copy.text, isPresented: $showingFlagConfirmation) {
            Button(AppCopy.okAction.copy.text, role: .cancel) { menuFocused = true }
        } message: {
            Text(AppCopy.flagSubmittedBody.copy.text)
        }
    }

    private var pager: some View {
        TabView(selection: $currentID) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, photo in
                PhotoPage(
                    source: photo.source,
                    isCurrent: photo.id == currentID,
                    label: AppCopy.photoPositionLabel(index: index, count: items.count).text,
                    caption: photo.caption,
                    bottomObstruction: bandObstruction,
                    zoomCommand: zoomRequests.command(for: photo.id),
                    onSingleTap: toggleControls,
                    onZoomAction: { action in
                        zoomRequests.request(action, for: photo.id)
                    },
                    onZoomCommandApplied: { serial in
                        zoomRequests.consume(serial: serial)
                    },
                    onSwipeDownChanged: { translation in
                        groundOpacity = PhotoMotion.SwipeDown.groundOpacity(translation: translation)
                    },
                    onSwipeDownEnded: { dismissed in
                        if dismissed {
                            dismiss()
                        } else {
                            withAnimation(PhotoMotion.SwipeDown.snapBackAnimation) {
                                groundOpacity = 1
                            }
                        }
                    }
                )
                .tag(photo.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    @ToolbarContentBuilder
    private var controls: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                Label(AppCopy.photoViewerCloseLabel.copy.text, systemImage: "xmark")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("photoViewer.close")
        }
        ToolbarItem(placement: .principal) {
            Text(position.counter.text)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .accessibilityIdentifier("photoViewer.counter")
        }
        if let makeFlagViewModel {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(AppCopy.flagPhotoAction.copy.text, systemImage: "flag") {
                        flagIssueViewModel = makeFlagViewModel(currentID)
                    }
                } label: {
                    Label(AppCopy.photoViewerMoreLabel.copy.text, systemImage: "ellipsis.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("photoViewer.more")
                .accessibilityFocused($menuFocused)
            }
        }
    }

    private func toggleControls() {
        guard !voiceOverEnabled else { return }
        withAnimation(PhotoMotion.chromeAnimation) {
            controlsVisible.toggle()
        }
    }
}

/// A VoiceOver zoom request for one page. `serial` makes a repeat of the
/// same action a new request; `photoID` keeps it off every other page.
nonisolated struct PhotoZoomCommand: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case zoomIn
        case reset
    }

    let serial: Int
    let photoID: Photo.ID
    let action: Action
}

/// The viewer's one pending VoiceOver zoom request. A page consumes it once
/// applied and a page change drops it, so a page view that TabView
/// recreates (its last-applied serial forgotten) never replays it.
nonisolated struct PhotoZoomRequests: Equatable, Sendable {
    private(set) var pending: PhotoZoomCommand?
    private var nextSerial = 1

    mutating func request(_ action: PhotoZoomCommand.Action, for photoID: Photo.ID) {
        pending = PhotoZoomCommand(serial: nextSerial, photoID: photoID, action: action)
        nextSerial += 1
    }

    /// Clears the request `serial` names; a newer one stays pending.
    mutating func consume(serial: Int) {
        if pending?.serial == serial { pending = nil }
    }

    mutating func pageChanged() {
        pending = nil
    }

    func command(for photoID: Photo.ID) -> PhotoZoomCommand? {
        pending?.photoID == photoID ? pending : nil
    }
}

// MARK: - Page

/// One page: loading, the zoomable photo, or the failure state (design D17)
/// whose Retry reloads this page only.
private struct PhotoPage: View {
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

// MARK: - Zoom page (eng C2)

/// A `UIScrollView` zoom page: pinch 1x to 4x, double tap toggles 1x and
/// 2.5x at the tap, a single tap (after the double tap fails) toggles the
/// controls, and at 1x a downward drag moves the photo and can close the
/// viewer (design D6/D7).
private struct ZoomableImagePage: UIViewRepresentable {
    let image: UIImage
    let isCurrent: Bool
    let bottomObstruction: CGFloat
    let zoomCommand: PhotoZoomCommand?
    let onZoomCommandApplied: (Int) -> Void
    let onSingleTap: () -> Void
    let onSwipeDownChanged: (CGFloat) -> Void
    let onSwipeDownEnded: (Bool) -> Void

    func makeUIView(context: Context) -> ZoomablePhotoView {
        ZoomablePhotoView()
    }

    func updateUIView(_ view: ZoomablePhotoView, context: Context) {
        view.onSingleTap = onSingleTap
        view.onSwipeDownChanged = onSwipeDownChanged
        view.onSwipeDownEnded = onSwipeDownEnded
        view.setBottomObstruction(bottomObstruction)
        view.display(image)
        // Zoom resets when the page changes.
        if !isCurrent {
            view.resetZoom(animated: false)
        }
        if let zoomCommand {
            view.apply(zoomCommand)
            // Consumed after this update pass (state can't change inside
            // it), so a recreated page never replays it (QA P3).
            let serial = zoomCommand.serial
            Task { @MainActor in onZoomCommandApplied(serial) }
        }
    }
}

/// The container moves during a swipe down; the scroll view inside zooms.
final class ZoomablePhotoView: UIView, UIScrollViewDelegate {
    var onSingleTap: (() -> Void)?
    var onSwipeDownChanged: ((CGFloat) -> Void)?
    var onSwipeDownEnded: ((Bool) -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let swipeDown = UIPanGestureRecognizer()
    private let swipeDownDelegate = SwipeDownGestureDelegate()
    private var laidOutSize: CGSize = .zero
    private var lastZoomSerial: Int?
    private var bottomObstruction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        insetsLayoutMarginsFromSafeArea = false

        scrollView.delegate = self
        scrollView.minimumZoomScale = PhotoMotion.Zoom.minimumScale
        scrollView.maximumZoomScale = PhotoMotion.Zoom.maximumScale
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.backgroundColor = .clear
        addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = false
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        // Design D7: a single tap waits for the double tap to fail.
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        swipeDown.addTarget(self, action: #selector(handleSwipeDown(_:)))
        swipeDownDelegate.canBegin = { [weak self] in self?.swipeDownCanBegin() ?? false }
        swipeDownDelegate.ownView = scrollView
        swipeDown.delegate = swipeDownDelegate
        scrollView.addGestureRecognizer(swipeDown)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// `TabView(.page)`'s own UIKit scroll view still adjusts its insets for
    /// the safe area, which `.ignoresSafeArea()` does not reach: hiding the
    /// status bar with the controls changes the top inset (62 to 48pt on a
    /// Dynamic Island iPhone) and the page moved 14pt down (QA P2, caught
    /// by `testThumbnailOpensPagingPhotoViewer`). The pager pages
    /// horizontally only, so it never needs a vertical inset.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        var ancestor = superview
        while let view = ancestor {
            if let pager = view as? UIScrollView, pager.contentInsetAdjustmentBehavior != .never {
                pager.contentInsetAdjustmentBehavior = .never
                pager.contentOffset.y = 0
            }
            ancestor = view.superview
        }
    }

    func display(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        layoutImage()
    }

    func resetZoom(animated: Bool) {
        guard !PhotoMotion.Zoom.isAtRest(scrollView.zoomScale) else { return }
        scrollView.setZoomScale(PhotoMotion.Zoom.minimumScale, animated: animated)
    }

    func apply(_ command: PhotoZoomCommand) {
        guard command.serial != lastZoomSerial else { return }
        lastZoomSerial = command.serial
        switch command.action {
        case .zoomIn:
            let centre = CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY)
            zoom(to: PhotoMotion.Zoom.doubleTapScale, centeredOn: centre)
        case .reset:
            resetZoom(animated: true)
        }
    }

    /// Points at the bottom of the page the caption band covers (PR 2). The
    /// page itself stays full screen (QA P2); the photo fits and centres in
    /// the space above the band, and a zoomed photo can still scroll up
    /// from under it.
    func setBottomObstruction(_ obstruction: CGFloat) {
        let obstruction = max(0, obstruction.rounded())
        guard obstruction != bottomObstruction else { return }
        bottomObstruction = obstruction
        relayoutKeepingZoom()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        scrollView.transform = .identity
        scrollView.frame = bounds
        relayoutKeepingZoom()
    }

    /// Re-fits the photo, keeping a zoomed photo zoomed rather than
    /// snapping it back to 1x (the band toggling, a rotation).
    private func relayoutKeepingZoom() {
        let savedScale = scrollView.zoomScale
        layoutImage()
        if !PhotoMotion.Zoom.isAtRest(savedScale) {
            scrollView.setZoomScale(savedScale, animated: false)
        }
    }

    /// The height the photo fits into: the page minus the band.
    private var visibleHeight: CGFloat { max(1, bounds.height - bottomObstruction) }

    /// At 1x the image is aspect-fit and centred with insets, so content
    /// plus insets equal the bounds and nothing scrolls: pans go to the pager.
    private func layoutImage() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        scrollView.setZoomScale(PhotoMotion.Zoom.minimumScale, animated: false)
        let fit = min(bounds.width / size.width, visibleHeight / size.height)
        let fitted = CGSize(width: size.width * fit, height: size.height * fit)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        centreImage()
        scrollView.contentOffset = CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top)
    }

    private func centreImage() {
        let horizontal = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let available = max(1, scrollView.bounds.height - bottomObstruction)
        let vertical = max(0, (available - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(
            top: vertical, left: horizontal, bottom: vertical + bottomObstruction, right: horizontal
        )
    }

    private func zoom(to scale: CGFloat, centeredOn point: CGPoint) {
        let rect = PhotoMotion.Zoom.zoomRect(centeredOn: point, scale: scale, bounds: scrollView.bounds.size)
        scrollView.zoom(to: rect, animated: true)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centreImage() }

    // MARK: Gestures

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let target = PhotoMotion.Zoom.doubleTapTarget(from: scrollView.zoomScale)
        if PhotoMotion.Zoom.isAtRest(target) {
            resetZoom(animated: true)
        } else {
            zoom(to: target, centeredOn: recognizer.location(in: imageView))
        }
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    /// Only at 1x, and only for a drag that starts mostly downward.
    private func swipeDownCanBegin() -> Bool {
        guard PhotoMotion.Zoom.isAtRest(scrollView.zoomScale) else { return false }
        let velocity = swipeDown.velocity(in: self)
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }

    @objc private func handleSwipeDown(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        switch recognizer.state {
        case .changed:
            scrollView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
            onSwipeDownChanged?(translation.y)
        case .ended, .cancelled, .failed:
            let velocity = recognizer.velocity(in: self).y
            let dismisses = recognizer.state == .ended
                && PhotoMotion.SwipeDown.shouldDismiss(translation: translation.y, velocity: velocity)
            if !dismisses {
                UIView.animate(
                    withDuration: PhotoMotion.SwipeDown.snapBackSeconds,
                    delay: 0,
                    options: [.curveEaseOut, .allowUserInteraction]
                ) {
                    self.scrollView.transform = .identity
                }
            }
            onSwipeDownEnded?(dismisses)
        default:
            break
        }
    }
}

/// The swipe-down recognizer's delegate: it begins only at 1x going down,
/// runs alongside the page's own scroll view (which does nothing at 1x), and
/// anything outside the page that is not a scroll view (the system's own
/// cover-dismiss drag) waits for it to fail, so one drag never moves two
/// things.
private final class SwipeDownGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    var canBegin: () -> Bool = { false }
    weak var ownView: UIView?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        canBegin()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer.view === ownView
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard otherGestureRecognizer is UIPanGestureRecognizer else { return false }
        return !(otherGestureRecognizer.view is UIScrollView)
    }
}
