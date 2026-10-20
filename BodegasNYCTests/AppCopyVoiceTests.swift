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
//  name, an em dash, or breaks its kind's length or ending rule.
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

    var testDescription: String { "\(self)" }

    private static let minorWords: Set<String> = ["a", "an", "the", "of", "on", "in", "to", "and", "or"]
    private static let sentenceEndings = [".", "?", ".\u{201D}"]

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    private static func endsAsSentence(_ text: String) -> Bool {
        sentenceEndings.contains { text.hasSuffix($0) }
    }

    /// True when `copy` satisfies this rule. Rules 6-8 pass vacuously for
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
        }
    }
}

struct AppCopyVoiceTests {
    static let shippedCopy: [CopyString] =
        AppCopy.allCases.map(\.copy) + [
            AppCopy.noSearchMatchesTitle("Deli"),
            AppCopy.addedAnnouncement(name: "Deli")
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
}
