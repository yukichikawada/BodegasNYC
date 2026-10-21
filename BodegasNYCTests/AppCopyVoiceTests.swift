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
                return word.first?.isUppercase == true
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

    // MARK: Planted violations: each must fail exactly the rule it targets.

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
