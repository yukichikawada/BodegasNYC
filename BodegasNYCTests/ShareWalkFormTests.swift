//
//  ShareWalkFormTests.swift
//  BodegasNYCTests
//
//  The Share a Walk form's state (#177 design DS4's state table) as the
//  pure `ShareWalkForm`: presets, the date rules, and when Share may send
//  the picture on show. Pictures here are placeholders made without
//  MapKit: the form only compares what each was made for.
//

import LinkPresentation
import Testing
import UIKit

@testable import BodegasNYC

@Suite
@MainActor
struct ShareWalkFormTests {
    private static let day1 = WalkedDayKey(value: 20261102)
    private static let day2 = WalkedDayKey(value: 20261103)
    private static let day3 = WalkedDayKey(value: 20261105)
    private static let today = WalkedDayKey(value: 20261110)

    private static func history(
        _ days: [(WalkedDayKey, Set<UInt32>)],
        version: Int = 1,
        meters: Double = 400
    ) -> WalkedHistory {
        WalkedHistory(
            days: days.map { WalkedDaySummary(day: $0.0, walkedIDs: $0.1, newCount: $0.1.count, meters: meters) },
            cumulative: [],
            estimatedThroughDay: nil,
            version: version
        )
    }

    /// Walks on day 1, day 2 (blocks 2 and 3) and day 3, none after.
    private static let walked = history([(day1, [1]), (day2, [2, 3]), (day3, [4])])

    private static func picture(for form: ShareWalkForm) -> SharedWalkCard.Result {
        .picture(SharedWalkPicture(walk: form.walk, png: Data([1]), image: UIImage()))
    }

    /// protects=eng E4 and DS4: the form opens on the preset day (a walked
    /// day, or Your Walks' most recent one) as both From and To, clamped
    /// into the first walked day through today; no form without a walked
    /// day; fails_when=it opens on a week, outside the allowed days, or
    /// with nothing to share; no_claim=which day each entry passes (the
    /// views; the UI tests check both entries).
    @Test func opensOnThePresetDay() throws {
        let form = try #require(ShareWalkForm(history: Self.walked, preset: Self.day2, today: Self.today))
        #expect(form.start == Self.day2 && form.end == Self.day2)
        #expect(form.walk.blockIDs == [2, 3])
        #expect(form.firstDay == Self.day1)
        let early = try #require(ShareWalkForm(history: Self.walked, preset: WalkedDayKey(value: 20260101), today: Self.today))
        #expect(early.start == Self.day1)
        let late = try #require(ShareWalkForm(history: Self.walked, preset: WalkedDayKey(value: 20261201), today: Self.today))
        #expect(late.start == Self.today)
        #expect(ShareWalkForm(history: Self.history([(Self.day1, [])]), preset: Self.day1, today: Self.today) == nil)
    }

    /// protects=DS4's states for one request: making on open (Share
    /// disabled, nothing to send), ready once its picture is in (Share
    /// enabled, sending exactly that picture), failed with its reason and
    /// back to making on Retry (a new attempt); a picture for an older
    /// request is dropped; fails_when=Share enables before the picture or
    /// with a stale one, a failure leaves Share on, Retry does not ask
    /// again; no_claim=the 0.3 s debounce and the 40% preview (the view).
    @Test func makingReadyFailedAndRetry() throws {
        var form = try #require(ShareWalkForm(history: Self.walked, preset: Self.day2, today: Self.today))
        #expect(form.phase == .making && !form.canShare && form.shareablePicture == nil)
        #expect(form.disabledReason == nil)

        let opened = form.request
        form.setFrom(Self.day1)
        form.pictureMade(Self.picture(for: form), for: opened)
        #expect(form.phase == .making, "a picture for the old dates is dropped")

        form.pictureMade(.failed, for: form.request)
        #expect(form.phase == .failed && !form.canShare)
        #expect(form.disabledReason == .pictureFailed)
        let attempt = form.attempt
        form.retry()
        #expect(form.phase == .making && form.attempt == attempt + 1)

        let made = Self.picture(for: form)
        form.pictureMade(made, for: form.request)
        #expect(form.phase == .ready && form.canShare)
        guard case .picture(let picture) = made else { return }
        #expect(form.shareablePicture == picture)
        #expect(form.shareablePicture?.walk == form.walk)
    }

    /// protects=DS4: a range with no walked block, and one over 5,000
    /// blocks (eng E5), disable Share with their reasons whatever picture
    /// exists; fails_when=an empty range can be shared, or the cap is
    /// missing or off by one; no_claim=the reason line's placement.
    @Test func noBlocksAndTooManyBlocks() throws {
        var form = try #require(ShareWalkForm(history: Self.walked, preset: Self.day3, today: Self.today))
        form.setFrom(WalkedDayKey(value: 20261107))
        #expect(form.end == WalkedDayKey(value: 20261107))
        #expect(form.phase == .noBlocks && form.disabledReason == .noBlocks && !form.canShare)

        let atCap = Self.history([(Self.day1, Set(1 ... 5_000))])
        let fits = try #require(ShareWalkForm(history: atCap, preset: Self.day1, today: Self.today))
        #expect(fits.phase == .making)
        let overCap = Self.history([(Self.day1, Set(1 ... 3_000)), (Self.day2, Set(3_001 ... 5_001))])
        var over = try #require(ShareWalkForm(history: overCap, preset: Self.day1, today: Self.today))
        over.setTo(Self.day2)
        #expect(over.walk.blockCount == 5_001)
        #expect(over.phase == .tooManyBlocks && over.disabledReason == .tooManyBlocks && !over.canShare)
    }

    /// protects=DS4's "history changes while open": a newer history keeps
    /// the dates, recomputes the walk and disables Share until the picture
    /// is remade (the old one stays on show, dimmed); a history with no
    /// walked day closes the form (Clear History); fails_when=Share keeps
    /// sending a picture made from the older history, or a cleared history
    /// leaves the form up; no_claim=the dismissal itself (the view).
    @Test func aHistoryChangeInvalidatesThePicture() throws {
        var form = try #require(ShareWalkForm(history: Self.walked, preset: Self.day2, today: Self.today))
        form.pictureMade(Self.picture(for: form), for: form.request)
        #expect(form.canShare)

        let grown = Self.history([(Self.day1, [1]), (Self.day2, [2, 3, 9]), (Self.day3, [4])], version: 2)
        let stays = form.historyChanged(grown)
        #expect(stays)
        #expect(form.start == Self.day2 && form.end == Self.day2)
        #expect(form.walk.blockIDs == [2, 3, 9])
        #expect(form.phase == .making && !form.canShare)
        #expect(form.picture != nil, "the last picture stays on show while the next is made")
        #expect(form.picture?.walk.blockIDs == [2, 3])

        let staysWhenCleared = form.historyChanged(Self.history([], version: 3))
        #expect(!staysWhenCleared)
    }

    /// protects=DS4's date rules: moving From past To drags To along; To
    /// never goes before From; neither passes today or the first walked
    /// day; fails_when=From can sit after To, To before From, or a date
    /// outside the walked span; no_claim=the date picker's own limits (the
    /// view passes the same ranges).
    @Test func fromPastToDragsToAlong() throws {
        var form = try #require(ShareWalkForm(history: Self.walked, preset: Self.day1, today: Self.today))
        form.setFrom(Self.day3)
        #expect(form.start == Self.day3 && form.end == Self.day3)
        form.setTo(Self.day2)
        #expect(form.end == Self.day3, "To cannot go before From")
        form.setTo(WalkedDayKey(value: 20261231))
        #expect(form.end == Self.today)
        form.setFrom(WalkedDayKey(value: 20250101))
        #expect(form.start == Self.day1 && form.end == Self.today)
        #expect(form.walk.blockIDs == [1, 2, 3, 4])
    }

    /// protects=DS4's "no picture": the picture's panel is on screen while
    /// a picture is made, shown or failed, and gone with no blocks or too
    /// many; fails_when=an empty grey panel stands in for no picture, or the
    /// panel vanishes while making or after a failure (Retry lives in it);
    /// no_claim=the layout around it (the live capture).
    @Test func thePanelCollapsesWithNoPicture() throws {
        var form = try #require(ShareWalkForm(history: Self.walked, preset: Self.day2, today: Self.today))
        #expect(form.phase == .making && form.showsPicturePanel)
        form.pictureMade(.failed, for: form.request)
        #expect(form.phase == .failed && form.showsPicturePanel)
        form.retry()
        form.pictureMade(Self.picture(for: form), for: form.request)
        #expect(form.phase == .ready && form.showsPicturePanel)
        form.setFrom(WalkedDayKey(value: 20261108))
        #expect(form.phase == .noBlocks && !form.showsPicturePanel)

        let big = Self.history([(Self.day1, Set(1 ... 5_001))])
        let over = try #require(ShareWalkForm(history: big, preset: Self.day1, today: Self.today))
        #expect(over.phase == .tooManyBlocks && !over.showsPicturePanel)
    }

    /// protects=Clear History while the form is open closes it: a history
    /// with no walked day, or no history at all, is the form's signal to
    /// dismiss (the view dismisses on `false`); a history that still has
    /// walked days keeps it; fails_when=the form stays up over a cleared
    /// history and could still share a picture of deleted walks;
    /// no_claim=the view's `dismiss()` call itself and Your Walks' own pop.
    @Test func aClearedHistoryClosesTheForm() throws {
        var form = try #require(ShareWalkForm(history: Self.walked, preset: Self.day2, today: Self.today))
        let cleared = WalkedHistory.build(
            dayMasks: [:],
            dayMeters: [Self.day1: 300],
            grid: StreetFixtures.cornerGrid(),
            estimatedThroughDay: nil,
            version: 9
        )
        #expect(cleared.walkedDays.isEmpty)
        let staysOverCleared = form.historyChanged(cleared)
        #expect(!staysOverCleared)
        let staysOverNothing = form.historyChanged(nil)
        #expect(!staysOverNothing)
        let staysOverWalks = form.historyChanged(Self.history([(Self.day2, [2])], version: 10))
        #expect(staysOverWalks)
    }

    /// protects=DS5 and #177's telemetry rule: when the share sheet reports
    /// completed, `walk_shared` is recorded exactly once and the form
    /// closes; when it reports cancelled, nothing is recorded and the form
    /// stays with focus on Share; fails_when=a cancel records the event, a
    /// completion records it twice or not at all, or a cancel closes the
    /// form; no_claim=that UIKit calls the completion handler once per
    /// share (the presenter forwards each call; live QA), and the SDK.
    @Test func walkSharedOnlyOnACompletedShare() {
        var recorded = 0
        #expect(ShareWalkForm.shareFinished(completed: false) { recorded += 1 } == .stayOnShare)
        #expect(recorded == 0)
        #expect(ShareWalkForm.shareFinished(completed: true) { recorded += 1 } == .closeForm)
        #expect(recorded == 1)
    }

    /// protects=DS5's share items, in order: the picture first, as an item
    /// source whose image is the picture shown and whose link metadata is
    /// titled "Walk, Nov 3–5, 2026", then the text line "3 blocks, 3 new,
    /// 0.5 miles. Nov 3–5, 2026."; fails_when=the order flips, the image is
    /// not the one previewed, the header reads anything else, or the text
    /// drifts; no_claim=what each destination (Messages, Mail, Photos) does
    /// with the items, which only a device share shows.
    @Test func shareItemsArePictureThenText() throws {
        var form = try #require(ShareWalkForm(history: Self.walked, preset: Self.day2, today: Self.today))
        form.setTo(Self.day3)
        let image = UIImage(systemName: "square.and.arrow.up") ?? UIImage()
        let made = SharedWalkPicture(walk: form.walk, png: Data([1]), image: image)
        let items = ShareSheetPresenter.items(for: made)
        #expect(items.count == 2)
        let picture = try #require(items.first as? SharedWalkImageItem)
        let sheet = UIActivityViewController(activityItems: [], applicationActivities: nil)
        #expect(picture.activityViewController(sheet, itemForActivityType: nil) as? UIImage === image)
        #expect(picture.activityViewControllerPlaceholderItem(sheet) as? UIImage === image)
        #expect(picture.activityViewControllerLinkMetadata(sheet)?.title == "Walk, Nov 3\u{2013}5, 2026")
        #expect(items.last as? String == "3 blocks, 3 new, 0.5 miles. Nov 3\u{2013}5, 2026.")
    }
}
