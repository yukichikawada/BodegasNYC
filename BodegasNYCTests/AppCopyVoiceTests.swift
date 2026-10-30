//
//  AppCopyVoiceTests.swift
//  BodegasNYCTests
//
//  The spec's eight voice rules, checked mechanically over every shipped
//  `AppCopy` string plus the search-title template. Each rule is a pure
//  predicate over `CopyString` (`VoiceRule.passes`), so the planted-violation
//  tests at the bottom can feed it strings that must fail.
//
//  protects: the voice rules hold for every shipped string.
//  fails_when: any CopyString carries `!`, an emoji, we/our/us, the app's
//  name, an em dash, or breaks its kind's length or ending rule (a `.value`
//  with a period, more than four words, or a leading lowercase letter).
//  no_claim: tone quality; only the mechanical rules.
//

import Foundation
import Testing

@testable import BodegasNYC

enum VoiceRule: CaseIterable, CustomTestStringConvertible {
    case noExclamation
    case noEmoji
    case noFirstPersonPlural
    case noAppName
    case noEmDash
    case titleShape
    case bodyShape
    case labelShape
    case valueShape

    var testDescription: String { "\(self)" }

    private static let minorWords: Set<String> = ["a", "an", "the", "of", "on", "in", "to", "and", "or"]
    private static let sentenceEndings = [".", "?", ".\u{201D}"]

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    private static func endsAsSentence(_ text: String) -> Bool {
        sentenceEndings.contains { text.hasSuffix($0) }
    }

    /// True when `copy` satisfies this rule. Rules 6-9 pass vacuously for
    /// strings of another kind.
    func passes(_ copy: CopyString) -> Bool {
        let text = copy.text
        switch self {
        case .noExclamation:
            return !text.contains("!")
        case .noEmoji:
            return !text.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
        case .noFirstPersonPlural:
            return text.firstMatch(of: /\b(we|we're|we've|our|us)\b/.ignoresCase()) == nil
        case .noAppName:
            return !text.localizedCaseInsensitiveContains("BodegasNYC")
                && !text.localizedCaseInsensitiveContains("My Bodegas")
        case .noEmDash:
            return !text.contains("\u{2014}")
        case .titleShape:
            guard copy.kind == .title else { return true }
            return Self.words(text).count <= 8 && Self.endsAsSentence(text)
        case .bodyShape:
            guard copy.kind == .body else { return true }
            return Self.words(text).count <= 30 && Self.endsAsSentence(text)
        case .labelShape:
            guard copy.kind == .label else { return true }
            let words = Self.words(text)
            guard !words.isEmpty, words.count <= 5 else { return false }
            guard let last = text.last, last.isLetter || last.isNumber else { return false }
            return words.enumerated().allSatisfy { index, word in
                if index > 0, Self.minorWords.contains(String(word)) { return true }
                // A numeral has no case: "Retry 2" is Title Case (#107).
                return word.first?.isUppercase == true || word.first?.isNumber == true
            }
        case .valueShape:
            // A data fragment (#68): 1 to 4 words, ends in a letter or digit
            // (so no period), never starts lowercase; no Title Case rule.
            guard copy.kind == .value else { return true }
            let words = Self.words(text)
            guard !words.isEmpty, words.count <= 4 else { return false }
            guard let last = text.last, last.isLetter || last.isNumber else { return false }
            return text.first?.isLowercase != true
        }
    }
}

struct AppCopyVoiceTests {
    static let shippedCopy: [CopyString] =
        AppCopy.allCases.map(\.copy) + [
            AppCopy.noSearchMatchesTitle("Deli"),
            AppCopy.addedAnnouncement(name: "Deli")
        ] + distanceFixtures.flatMap { [AppCopy.distanceValue($0), AppCopy.distanceFromYou($0)] }
        + photoPositionFixtures.flatMap { index, count in
            [
                AppCopy.photoCounter(index: index, count: count),
                AppCopy.photoPositionLabel(index: index, count: count),
                AppCopy.photoPageAnnouncement(index: index, count: count)
            ]
        }
        + uploadCountFixtures.flatMap { count in
            [
                AppCopy.retryCountLabel(count),
                AppCopy.captionFieldLabel(index: count - 1),
                AppCopy.uploadProgress(index: count - 1, count: 10),
                AppCopy.photosUnloadable(count),
                AppCopy.photosUnloadableTitle(count),
                AppCopy.discardPhotosTitle(count),
                AppCopy.uploadPassFailed(uploaded: count, failed: 1),
                AppCopy.uploadPassFailed(uploaded: 0, failed: count)
            ]
        }
        + [120, 140, 141].map { AppCopy.captionCount($0, limit: 140) }
        + AppCopy.YourBlocks.allCases.map(\.copy)
        + AppCopy.Recorder.allCases.map(\.copy)
        + AppCopy.StreetsWalkedIntro.allCases.map(\.copy)
        + AppCopy.Account.allCases.map(\.copy)
        + yourBlocksFixtures.flatMap { walked, total in
            [
                AppCopy.boroughBlockCount(walked: walked, total: total),
                AppCopy.citywideBlockCount(walked: walked, total: total)
            ] + yourBlocksPlaces.flatMap { borough in
                [
                    AppCopy.yourBlocksRowLabel(borough, walked: walked, total: total),
                    AppCopy.yourBlocksRowLabel(borough, walked: nil, total: nil)
                ]
            }
        }

    /// (walked, total) for Your Blocks (#108 PR 2): zero, one, the "<1%"
    /// band, a whole percent, grouped thousands, a full borough.
    static let yourBlocksFixtures: [(Int, Int)] = [
        (0, 9_300), (1, 9_300), (412, 9_300), (12_345, 99_360), (9_300, 9_300)
    ]

    /// The city (`nil`), then every borough.
    static let yourBlocksPlaces: [Borough?] = [nil, .manhattan, .brooklyn, .queens, .bronx, .statenIsland]

    /// Counts in the upload sheet (#107 PR 2): one, a few, the 10-photo cap.
    static let uploadCountFixtures = [1, 2, 9, 10]

    /// (zero-based index, count): a lone photo, both ends, and two digits (#107).
    static let photoPositionFixtures: [(Int, Int)] = [(0, 1), (0, 3), (2, 3), (11, 12), (99, 120)]

    /// One per template branch (#68: spec, design D5/D6/D7): the corner,
    /// singular and plural blocks up to the 20-block cap, and miles with and
    /// without a decimal, singular, and grouped.
    static let distanceFixtures: [BlockDistance] = [
        .aroundTheCorner, .blocks(1), .blocks(2), .blocks(10), .blocks(20),
        .miles(0.55), .miles(1.0), .miles(1.0253), .miles(1.25), .miles(1.5), .miles(2.0), .miles(2.75),
        .miles(12.4), .miles(2450)
    ]

    @Test(arguments: VoiceRule.allCases)
    func everyShippedStringPasses(_ rule: VoiceRule) {
        for copy in Self.shippedCopy {
            #expect(rule.passes(copy), "\(rule) fails for \(copy.kind) \"\(copy.text)\"")
        }
    }

    @Test func shippedCopyIsNotEmpty() {
        #expect(AppCopy.allCases.count >= 21)
        #expect(Self.shippedCopy.allSatisfy { !$0.text.isEmpty })
    }

    @Test func searchTitlePutsThePeriodInsideTheCurlyQuote() {
        #expect(AppCopy.noSearchMatchesTitle("Deli").text == "Nothing called \u{201C}Deli.\u{201D}")
    }

    @Test func addedAnnouncementNamesTheBodega() {
        #expect(AppCopy.addedAnnouncement(name: "Deli").text == "Deli is on the map.")
        #expect(AppCopy.addedAnnouncement(name: "Deli").kind == .body)
    }

    @Test func reviewsEmptyStateUsesTheCatLineOnlyWithACat() {
        let cat = AppCopy.noReviews(hasCat: true)
        let plain = AppCopy.noReviews(hasCat: false)
        #expect(cat.body.copy.text == "The cat isn't talking. You go first.")
        #expect(plain.body.copy.text == "Been here? Say so.")
        #expect(cat.title.copy.text == "No reviews yet.")
        #expect(plain.title.copy.text == "No reviews yet.")
    }

    /// protects=the recorder card's copy and symbols are design DS6's table,
    /// with the one voice-rule change (no app name in the denied body), and
    /// which problems offer Open Settings; fails_when=the wording, a symbol
    /// or an action drifts from the table; no_claim=the rendered card (QA).
    @Test func recorderCardCopyMatchesTheDesignTable() {
        let table: [(RecorderProblem, String, String, String, Bool)] = [
            (.needsAlways, "location.slash", "Recording paused.",
             "Streets Walked needs location set to Always. Your blocks stay.", true),
            (.denied, "location.slash", "Recording can't see you.",
             "Location is off for this app. Your blocks stay.", true),
            (.servicesOff, "location.slash", "Recording can't see you.",
             "Location Services is off for the whole phone.", true),
            (.restricted, "location.slash", "Recording isn't allowed here.",
             "Location is restricted on this phone. Your blocks stay.", false),
            (.preciseOff, "scope", "Recording paused.", "Blocks need Precise Location, and it's off.", true),
            (.saveFailed, "exclamationmark.triangle", "That stretch didn't save.",
             "Recording keeps going. Your other blocks are fine.", false)
        ]
        for (problem, symbol, title, body, opensSettings) in table {
            #expect(problem.symbolName == symbol)
            #expect(problem.title.copy == CopyString(kind: .title, text: title))
            #expect(problem.body.copy == CopyString(kind: .body, text: body))
            #expect(problem.opensSettings == opensSettings)
        }
        #expect(AppCopy.Recorder.pausedSection.copy == CopyString(kind: .label, text: "Recording Paused"))
        #expect(AppCopy.Recorder.resumedAnnouncement.copy == CopyString(kind: .body, text: "Recording again."))
        #expect(AppCopy.YourBlocks.recordingPaused.copy.text == "Recording is paused. Your blocks stay.")
    }

    /// protects=the Streets Walked intro's labels and headings are design
    /// D7's words and kinds (the UI test finds the sheet and the menu row by
    /// them, #126); fails_when=a label, the headline or the heading drifts
    /// or changes kind; no_claim=the body paragraphs' wording (the content
    /// table in StreetsWalkedIntroTests) and the rendered sheet.
    @Test func streetsWalkedIntroLabelsMatchTheDesignTable() {
        typealias Intro = AppCopy.StreetsWalkedIntro
        #expect(Intro.menuItem.copy == CopyString(kind: .label, text: "How Streets Walked Works"))
        #expect(Intro.notNowAction.copy == CopyString(kind: .label, text: "Not Now"))
        #expect(Intro.title.copy == CopyString(kind: .label, text: "Streets Walked"))
        #expect(Intro.headline.copy == CopyString(kind: .title, text: "The blocks you walk, drawn in."))
        #expect(
            Intro.permissionHeading.copy == CopyString(kind: .title, text: "Recording needs location set to Always.")
        )
        #expect(AppCopy.startRecordingAction.copy == CopyString(kind: .label, text: "Start Recording"))
        #expect(Intro.allCases.count == 13)
    }

    @Test func placementCardTitleIsAShortSentence() {
        let title = AppCopy.placementCardTitle.copy
        #expect(title.kind == .title)
        #expect(title.text == "Line the marker up with the door.")
        #expect(VoiceRule.allCases.allSatisfy { $0.passes(title) })
    }

    // MARK: Distance (#68)

    /// protects: the exact words a row shows (design D5/D7: "miles" spelled
    /// out, no ".0", singular at 1, grouped thousands).
    /// fails_when: "mi", "1.0 miles", "1 miles", "2450 miles", banker's
    /// rounding ("1.2 miles" for 1.25) or a period.
    /// no_claim: where the row places the value.
    @Test func distanceValueTexts() {
        let expected: [(BlockDistance, String)] = [
            (.aroundTheCorner, "Around the corner"),
            (.blocks(1), "1 block"),
            (.blocks(2), "2 blocks"),
            (.blocks(20), "20 blocks"),
            (.miles(0.55), "0.6 miles"),
            (.miles(1.0), "1 mile"),
            (.miles(1.0253), "1 mile"),
            (.miles(1.5), "1.5 miles"),
            (.miles(2.0), "2 miles"),
            (.miles(12.4), "12.4 miles"),
            (.miles(2450), "2,450 miles"),
            // Schoolbook rounding, as for blocks (exact binary halves).
            (.miles(1.25), "1.3 miles"),
            (.miles(2.75), "2.8 miles")
        ]
        for (distance, text) in expected {
            #expect(AppCopy.distanceValue(distance).text == text)
            #expect(AppCopy.distanceValue(distance).kind == .value)
        }
    }

    /// protects: the detail header's sentence and the row's VoiceOver ending.
    /// fails_when: the corner gains "from you", a count loses its period, or
    /// miles read "mi".
    /// no_claim: VoiceOver's actual speech.
    @Test func distanceFromYouTexts() {
        let expected: [(BlockDistance, String)] = [
            (.aroundTheCorner, "Around the corner."),
            (.blocks(1), "1 block from you."),
            (.blocks(2), "2 blocks from you."),
            (.miles(0.55), "0.6 miles from you."),
            (.miles(1.0), "1 mile from you.")
        ]
        for (distance, text) in expected {
            #expect(AppCopy.distanceFromYou(distance).text == text)
            #expect(AppCopy.distanceFromYou(distance).kind == .body)
        }
    }

    /// protects: the Distances tip's copy and its kinds (design D4).
    /// fails_when: the wording drifts from the design review.
    /// no_claim: when the tip shows (TutorialTipsTests, QA).
    @Test func distancesTipCopy() {
        #expect(AppCopy.distancesTipTitle.copy == CopyString(kind: .title, text: "Distances come in blocks."))
        #expect(
            AppCopy.distancesTipBody.copy
                == CopyString(kind: .body, text: "Tap Locate Me on the map and the list measures the way you do.")
        )
        #expect(AppCopy.showMapAction.copy == CopyString(kind: .label, text: "Show Map"))
    }

    // MARK: Photos (#107)

    /// protects: the viewer's counter, VoiceOver label and announcement text and kinds (design D5, D19).
    /// fails_when: zero-based numbers, a period on a value, or no period on the announcement.
    /// no_claim: where the views place them (UI test).
    @Test func photoPositionTexts() {
        #expect(AppCopy.photoCounter(index: 2, count: 12) == CopyString(kind: .value, text: "3 of 12"))
        #expect(AppCopy.photoPositionLabel(index: 0, count: 3) == CopyString(kind: .value, text: "Photo 1 of 3"))
        #expect(AppCopy.photoPageAnnouncement(index: 3, count: 12) == CopyString(kind: .body, text: "Photo 4 of 12."))
    }

    /// protects: the gallery and viewer strings keep their words and kinds; PR 2 renames the gallery button
    /// "Add Photos" (design D8).
    /// fails_when: the button still says "Add a Photo", or a button text becomes a sentence.
    /// no_claim: that no literal is left in the views (code review).
    @Test func photoGalleryAndViewerCopy() {
        #expect(AppCopy.addPhotoAction.copy == CopyString(kind: .label, text: "Add Photos"))
        #expect(AppCopy.flagPhotoAction.copy == CopyString(kind: .label, text: "Flag Photo"))
        #expect(AppCopy.photoZoomInAction.copy == CopyString(kind: .label, text: "Zoom In"))
        #expect(AppCopy.photoResetZoomAction.copy == CopyString(kind: .label, text: "Reset Zoom"))
        #expect(AppCopy.photoLoadFailedBody.copy.kind == .body)
        #expect(AppCopy.retryAction.copy == CopyString(kind: .label, text: "Retry"))
    }

    /// protects: the upload sheet's words, kinds and plural helpers (design D8-D14): singular at one, the count
    /// in Retry, the "N went up" footer, and a placeholder that never says "optional".
    /// fails_when: "1 photos", "Retry" without its count, a zero-based counter, a caption field label without the
    /// photo number, or "optional" in the placeholder.
    /// no_claim: where the sheet shows them (UI test, live QA).
    @Test func uploadSheetCopy() {
        #expect(AppCopy.retryCountLabel(1) == CopyString(kind: .label, text: "Retry 1"))
        #expect(AppCopy.uploadProgress(index: 2, count: 8) == CopyString(kind: .body, text: "Uploading 3 of 8."))
        #expect(AppCopy.uploadPassFailed(uploaded: 2, failed: 1).text == "2 went up. 1 didn't. Try again.")
        #expect(AppCopy.uploadPassFailed(uploaded: 0, failed: 3).text == "None went up. Try again.")
        #expect(AppCopy.photosUnloadable(1).text == "1 photo couldn't be loaded.")
        #expect(AppCopy.photosUnloadable(3).text == "3 photos couldn't be loaded.")
        #expect(AppCopy.discardPhotosTitle(1) == CopyString(kind: .title, text: "Discard 1 photo?"))
        #expect(AppCopy.discardPhotosTitle(4).text == "Discard 4 photos?")
        #expect(AppCopy.photosUnloadableTitle(1).text == "Couldn't load that photo.")
        #expect(AppCopy.photosUnloadableTitle(2).text == "Couldn't load those photos.")
        #expect(AppCopy.captionCount(128, limit: 140) == CopyString(kind: .value, text: "128/140"))
        #expect(AppCopy.captionFieldLabel(index: 1).text == "Caption for photo 2")
        #expect(!AppCopy.captionPlaceholder.copy.text.localizedCaseInsensitiveContains("optional"))
        #expect(AppCopy.captionsOptionalFooter.copy.text.localizedCaseInsensitiveContains("optional"))
        #expect(AppCopy.photoUploadFailedValue.copy == CopyString(kind: .value, text: "Didn't go through"))
        #expect(AppCopy.addOnePhotoTitle.copy.text == "Add a Photo")
        #expect(AppCopy.captionMoreAction.copy == CopyString(kind: .label, text: "More"))
        #expect(
            [AppCopy.uploadAction, .stopAction, .doneAction, .cancelAction, .removeAction, .discardAction]
                .allSatisfy { $0.copy.kind == .label }
        )
    }

    // MARK: Planted violations: each must fail exactly the rule it targets.

    /// protects: the label rule accepts a numeral word ("Retry 2") but still rejects a lowercase word.
    /// fails_when: numerals fail Title Case, or the numeral allowance lets "retry 2" through.
    /// no_claim: none beyond the rule.
    @Test func plantedLabelNumeralRules() {
        #expect(VoiceRule.labelShape.passes(CopyString(kind: .label, text: "Retry 2")))
        #expect(!VoiceRule.labelShape.passes(CopyString(kind: .label, text: "retry 2")))
        #expect(!VoiceRule.labelShape.passes(CopyString(kind: .label, text: "Retry again 2")))
    }

    @Test func plantedExclamationFailsRuleOne() {
        let planted = CopyString(kind: .body, text: "Put it on the map!")
        #expect(!VoiceRule.noExclamation.passes(planted))
        #expect(VoiceRule.noEmoji.passes(planted))
        #expect(VoiceRule.noFirstPersonPlural.passes(planted))
    }

    @Test func plantedEmojiFailsRuleTwo() {
        let planted = CopyString(kind: .body, text: "Has a cat \u{1F408}.")
        let variationSelector = CopyString(kind: .body, text: "Love this one \u{2764}\u{FE0F}.")
        #expect(!VoiceRule.noEmoji.passes(planted))
        #expect(!VoiceRule.noEmoji.passes(variationSelector))
        #expect(VoiceRule.noExclamation.passes(planted))
    }

    @Test func plantedWeFailsRuleThree() {
        let planted = CopyString(kind: .body, text: "We think you know a spot.")
        let contraction = CopyString(kind: .body, text: "Tell us about it.")
        #expect(!VoiceRule.noFirstPersonPlural.passes(planted))
        #expect(!VoiceRule.noFirstPersonPlural.passes(contraction))
        // Word boundary: "us" inside another word is fine.
        #expect(VoiceRule.noFirstPersonPlural.passes(CopyString(kind: .body, text: "Just a bus stop away.")))
        #expect(VoiceRule.bodyShape.passes(planted))
    }

    @Test func plantedLowercaseLabelFailsRuleEight() {
        let planted = CopyString(kind: .label, text: "add a bodega")
        #expect(!VoiceRule.labelShape.passes(planted))
        #expect(VoiceRule.labelShape.passes(CopyString(kind: .label, text: "Add a Bodega")))
        #expect(!VoiceRule.labelShape.passes(CopyString(kind: .label, text: "Add a Bodega.")))
        #expect(VoiceRule.noExclamation.passes(planted))
    }

    @Test func plantedValueViolationsFailRuleNine() {
        let period = CopyString(kind: .value, text: "2 blocks.")
        let fiveWords = CopyString(kind: .value, text: "Just about two blocks away")
        let lowercase = CopyString(kind: .value, text: "around the corner")
        #expect(!VoiceRule.valueShape.passes(period))
        #expect(!VoiceRule.valueShape.passes(fiveWords))
        #expect(!VoiceRule.valueShape.passes(lowercase))
        #expect(VoiceRule.valueShape.passes(CopyString(kind: .value, text: "Around the corner")))
        // Values are exempt from the other shape rules, and vice versa.
        #expect(VoiceRule.labelShape.passes(lowercase))
        #expect(VoiceRule.valueShape.passes(CopyString(kind: .body, text: "two blocks.")))
    }
}
