//
//  PhotoMotionTests.swift
//  BodegasNYCTests
//
//  The photo viewer's pure decisions (#107 PR 1): its position in the
//  snapshot (counter and VoiceOver text), the swipe-down close rule, the
//  double-tap zoom target and rect, and the PhotoMotion timings DESIGN.md
//  records.
//
//  no_claim (file-wide): rendering and gesture feel. That PhotoViewer feeds
//  these values to the toolbar, UIScrollView and recognizers, that pinch
//  stops at 4x and that paging stops while zoomed is checked by the UI test
//  (open, page, counter, close, swipe down) and live QA.
//

import CoreGraphics
import Foundation
import Testing

@testable import BodegasNYC

struct PhotoMotionTests {
    private let ids = [UUID(), UUID(), UUID()]

    // MARK: Position

    /// protects: the counter reads "i of N" for the current photo, one-based, at both ends (AC 1).
    /// fails_when: the counter is zero-based, off by one at either end, or ignores the current id.
    /// no_claim: that the toolbar shows it (UI test).
    @Test func counterIsOneBasedAtBothEnds() {
        #expect(PhotoViewerPosition(ids: ids, currentID: ids[0]).counter.text == "1 of 3")
        #expect(PhotoViewerPosition(ids: ids, currentID: ids[1]).counter.text == "2 of 3")
        #expect(PhotoViewerPosition(ids: ids, currentID: ids[2]).counter.text == "3 of 3")
        #expect(PhotoViewerPosition(ids: ids, currentID: ids[2]).counter.kind == .value)
    }

    /// protects: the page-change announcement is a sentence naming the position (design D19).
    /// fails_when: it loses "Photo", its period, or disagrees with the counter.
    /// no_claim: that VoiceOver speaks it.
    @Test func announcementNamesThePosition() {
        let position = PhotoViewerPosition(ids: ids, currentID: ids[1])
        #expect(position.announcement == CopyString(kind: .body, text: "Photo 2 of 3."))
        #expect(position.index == 1)
        #expect(position.count == 3)
    }

    /// protects: an id outside the snapshot cannot crash or produce "0 of N".
    /// fails_when: index goes negative or the counter reads "0 of 3".
    /// no_claim: the snapshot never changes while open (eng O3), so this is a guard only.
    @Test func unknownIDFallsBackToTheFirstPhoto() {
        #expect(PhotoViewerPosition(ids: ids, currentID: UUID()).counter.text == "1 of 3")
    }

    // MARK: Swipe down

    /// protects: release past 100pt or a fast downward flick closes; anything else snaps back (design D7).
    /// fails_when: exactly 100pt closes, a slow 99pt drag closes, an upward flick closes,
    /// or a fast flick is ignored.
    /// no_claim: the recognizer only begins at 1x going down (live QA).
    @Test func swipeDownClosesPastTheThresholdOrOnAFlick() {
        typealias SwipeDown = PhotoMotion.SwipeDown
        #expect(SwipeDown.shouldDismiss(translation: 101, velocity: 0))
        #expect(!SwipeDown.shouldDismiss(translation: 100, velocity: 0))
        #expect(!SwipeDown.shouldDismiss(translation: 99, velocity: 200))
        #expect(SwipeDown.shouldDismiss(translation: 20, velocity: 1200))
        #expect(!SwipeDown.shouldDismiss(translation: 20, velocity: -1500))
    }

    /// protects: the ground fades in proportion to the drag and never past its floor (design D7).
    /// fails_when: it fades on an upward drag, is not opaque at rest, or drops below 0.2.
    /// no_claim: what is visible behind the fading ground.
    @Test func groundFadesInProportionToTheDrag() {
        typealias SwipeDown = PhotoMotion.SwipeDown
        #expect(SwipeDown.groundOpacity(translation: 0) == 1)
        #expect(SwipeDown.groundOpacity(translation: -50) == 1)
        #expect(abs(SwipeDown.groundOpacity(translation: 150) - 0.6) < 0.0001)
        #expect(abs(SwipeDown.groundOpacity(translation: 900) - 0.2) < 0.0001)
    }

    // MARK: Zoom

    /// protects: double tap toggles 1x and 2.5x, and the zoom range is 1x to 4x (AC 2, eng C2).
    /// fails_when: a double tap at 2.5x or 4x zooms further in, a double tap at 1x stays,
    /// or the range drifts.
    /// no_claim: UIScrollView honours the range (live QA).
    @Test func doubleTapTogglesBetweenRestAndTwoAndAHalf() {
        typealias Zoom = PhotoMotion.Zoom
        #expect(Zoom.doubleTapTarget(from: 1) == 2.5)
        #expect(Zoom.doubleTapTarget(from: 1.005) == 2.5)
        #expect(Zoom.doubleTapTarget(from: 2.5) == 1)
        #expect(Zoom.doubleTapTarget(from: 4) == 1)
        #expect(Zoom.minimumScale == 1)
        #expect(Zoom.maximumScale == 4)
        #expect(!Zoom.isAtRest(1.5))
    }

    /// protects: the double tap zooms at the tap point, not the centre (AC 2).
    /// fails_when: the rect is not centred on the point or not bounds / scale in size.
    /// no_claim: UIScrollView's clamping at the image edges.
    @Test func zoomRectIsCentredOnTheTap() {
        let rect = PhotoMotion.Zoom.zoomRect(
            centeredOn: CGPoint(x: 100, y: 200),
            scale: 2.5,
            bounds: CGSize(width: 400, height: 800)
        )
        #expect(rect == CGRect(x: 20, y: 40, width: 160, height: 320))
        #expect(rect.midX == 100)
        #expect(rect.midY == 200)
    }

    // MARK: Motion tokens

    /// protects: the PhotoMotion timings match design D21 and DESIGN.md.
    /// fails_when: a duration drifts, or Reduce Motion keeps the scale on gallery inserts.
    /// no_claim: that the views read Reduce Motion (live QA).
    @Test func motionTokensMatchTheDesign() {
        #expect(PhotoMotion.chromeSeconds == 0.2)
        #expect(PhotoMotion.rowStatusSeconds == 0.15)
        #expect(PhotoMotion.insertSeconds == 0.25)
        #expect(PhotoMotion.insertStyle(reduceMotion: true) == .fade)
        #expect(PhotoMotion.insertStyle(reduceMotion: false) == .scaleAndFade)
    }
}
