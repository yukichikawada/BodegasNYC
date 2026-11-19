import SwiftUI
import UIKit

// MARK: - Zoom page (eng C2)

/// A `UIScrollView` zoom page: pinch 1x to 4x, double tap toggles 1x and
/// 2.5x at the tap, a single tap (after the double tap fails) toggles the
/// controls, and at 1x a downward drag moves the photo and can close the
/// viewer (design D6/D7).
struct ZoomableImagePage: UIViewRepresentable {
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
