import CoreGraphics
import Foundation
import SwiftUI

/// Every photo motion constant and pure motion decision (#107 design D21),
/// beside `BrowseMotion` and unit-tested in `PhotoMotionTests`, so the
/// timings DESIGN.md records have one source.
///
/// Under Reduce Motion everything here is opacity only. The cover's zoom
/// from the thumbnail needs no branch: the system zoom transition becomes a
/// crossfade under Reduce Motion (the pin-to-detail precedent, #23).
nonisolated enum PhotoMotion {
    /// The viewer's controls fade in and out, opacity only, `easeOut`.
    static let chromeSeconds: TimeInterval = 0.2
    /// An upload row's status change (PR 2), `easeOut`.
    static let rowStatusSeconds: TimeInterval = 0.15
    /// New gallery thumbnails after an upload (PR 2), `easeInOut`.
    static let insertSeconds: TimeInterval = 0.25

    enum InsertStyle: Equatable, Sendable {
        /// Scale up from the leading edge with opacity.
        case scaleAndFade
        /// Opacity only, in place (Reduce Motion).
        case fade
    }

    static func insertStyle(reduceMotion: Bool) -> InsertStyle {
        reduceMotion ? .fade : .scaleAndFade
    }

    static var chromeAnimation: Animation { .easeOut(duration: chromeSeconds) }
    static var rowStatusAnimation: Animation { .easeOut(duration: rowStatusSeconds) }
    static var insertAnimation: Animation { .easeInOut(duration: insertSeconds) }

    // MARK: Swipe down to close (design D7)

    /// At 1x the photo follows a downward drag and the black ground fades in
    /// proportion; releasing past `dismissDistance` or with a fast downward
    /// flick closes the viewer, anything else snaps back.
    enum SwipeDown {
        static let dismissDistance: CGFloat = 100
        /// Points per second, downward, that close the viewer on release
        /// whatever the distance.
        static let flickVelocity: CGFloat = 1000
        /// The drag distance over which the ground fades from opaque to
        /// `minimumGroundOpacity`.
        static let fadeDistance: CGFloat = 300
        static let minimumGroundOpacity: Double = 0.2
        /// The snap back when a release does not close.
        static let snapBackSeconds: TimeInterval = 0.25
        static var snapBackAnimation: Animation { .easeOut(duration: snapBackSeconds) }

        static func shouldDismiss(translation: CGFloat, velocity: CGFloat) -> Bool {
            translation > dismissDistance || velocity > flickVelocity
        }

        /// The ground's opacity for a drag `translation` points down. An
        /// upward drag never fades it.
        static func groundOpacity(translation: CGFloat) -> Double {
            let progress = min(max(translation, 0) / fadeDistance, 1)
            return 1 - Double(progress) * (1 - minimumGroundOpacity)
        }
    }

    // MARK: Zoom (eng C2)

    enum Zoom {
        static let minimumScale: CGFloat = 1
        static let maximumScale: CGFloat = 4
        /// Where a double tap at 1x zooms to, centred on the tap.
        static let doubleTapScale: CGFloat = 2.5
        /// Below this the page counts as at 1x: paging and swipe-down are
        /// allowed, and a double tap zooms in rather than out.
        static let restTolerance: CGFloat = 0.01

        static func isAtRest(_ scale: CGFloat) -> Bool {
            scale <= minimumScale + restTolerance
        }

        /// The double tap's target: in to 2.5x from rest, else back to 1x.
        static func doubleTapTarget(from scale: CGFloat) -> CGFloat {
            isAtRest(scale) ? doubleTapScale : minimumScale
        }

        /// The rect to `zoom(to:)` so `point` (in the unzoomed image view's
        /// coordinates) sits at the centre at `scale` in a `bounds`-sized
        /// scroll view.
        static func zoomRect(centeredOn point: CGPoint, scale: CGFloat, bounds: CGSize) -> CGRect {
            let width = bounds.width / scale
            let height = bounds.height / scale
            return CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
        }
    }
}

extension PhotoMotion.InsertStyle {
    var transition: AnyTransition {
        switch self {
        case .scaleAndFade: .scale(scale: 0.8, anchor: .leading).combined(with: .opacity)
        case .fade: .opacity
        }
    }
}

/// The viewer's position in its snapshot (eng O3): the photos it opened
/// with, in gallery order, and the current one by id. Pure, so the counter
/// and VoiceOver text are unit-tested.
nonisolated struct PhotoViewerPosition: Equatable, Sendable {
    let ids: [Photo.ID]
    let currentID: Photo.ID

    /// Zero-based; 0 for an id not in the snapshot (it never is: the
    /// snapshot does not change while the viewer is open).
    var index: Int { ids.firstIndex(of: currentID) ?? 0 }
    var count: Int { ids.count }

    var counter: CopyString { AppCopy.photoCounter(index: index, count: count) }
    var announcement: CopyString { AppCopy.photoPageAnnouncement(index: index, count: count) }
}
