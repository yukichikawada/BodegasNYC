//
//  PrivacyWordingTests.swift
//  BodegasNYCTests
//
//  #177 eng AC 16: once a walk can be shared, no user-facing string or doc
//  may still promise that walks never leave the phone without saying that
//  sharing is the exception. Searches the repo's user-facing sources and
//  docs through `#filePath` (the simulator shares the host file system, as
//  in BrowseMotionTests).
//
//  How a line is judged:
//  - Text: Markdown and HTML under docs/, README.md and DESIGN.md are read
//    a paragraph at a time (blank-line separated, whitespace collapsed);
//    a `.plist` file is read whole; a `.swift` file under BodegasNYC/
//    contributes only its string literals, joined in order, so code
//    comments ("never leaves the two out of step") are not copy.
//  - A match is any of `phrases`, case-insensitive, in a sentence.
//  - It is about walks when its paragraph (or the file's literals) says
//    "walk" anywhere.
//  - It is allowed when that sentence or the next one names sharing
//    ("shar": share, shared, sharing), as in "Your walks stay on this phone
//    unless you share one." or "... is never uploaded to us. Nothing leaves
//    your phone unless you share a walk yourself."
//  - Or it is one of `keptAsIs`, named exactly with its reason: a sentence
//    that answers another question than whether walks leave the phone.
//

import Foundation
import Testing

@Suite
struct PrivacyWordingTests {
    static let phrases = [
        "only on your device", "never uploaded", "stays on the device", "stay on this phone", "never leaves"
    ]

    /// Sentences kept as they are, each with why the exception does not
    /// belong in it.
    static let keptAsIs: [String: String] = [
        // The Account sheet's deletion consequence (#127): it says what
        // deleting an account leaves alone (the walked blocks), which is
        // true, not whether walks can leave the phone. Kept by the owner's
        // decision, as is the privacy policy's deletion paragraph (which
        // passes on its own: its next sentence names shared pictures).
        "Walked blocks stay on this phone.": "account deletion leaves the blocks; not a sharing promise"
    ]

    nonisolated struct Finding: CustomStringConvertible {
        let file: String
        let sentence: String
        var description: String { "\(file): \(sentence)" }
    }

    /// The walk-related sentences in `chunks` that make the promise without
    /// the sharing exception.
    static func findings(in chunks: [String], file: String) -> [Finding] {
        chunks.flatMap { chunk -> [Finding] in
            let text = chunk.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard text.localizedCaseInsensitiveContains("walk") else { return [] }
            let sentences = Self.sentences(text)
            return sentences.indices.compactMap { index in
                let sentence = sentences[index]
                guard phrases.contains(where: { sentence.localizedCaseInsensitiveContains($0) }),
                      keptAsIs[sentence] == nil
                else { return nil }
                let next = index + 1 < sentences.count ? sentences[index + 1] : ""
                let names = { (text: String) in text.localizedCaseInsensitiveContains("shar") }
                return names(sentence) || names(next) ? nil : Finding(file: file, sentence: sentence)
            }
        }
    }

    /// `text` cut after each ".", "?" or "!" that a space follows.
    static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character == " ", let previous, ".?!".contains(previous) {
                sentences.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences
    }

    /// The parts of `contents` that read as user-facing text, by file type.
    static func chunks(of contents: String, pathExtension: String) -> [String] {
        switch pathExtension {
        case "swift":
            let literals = contents.matches(of: /"((?:[^"\\\n]|\\.)*)"/).map { String($0.output.1) }
            return [literals.joined(separator: " ")]
        case "plist":
            return [contents]
        default:
            return contents.components(separatedBy: "\n\n")
        }
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every user-facing source and doc the search covers.
    private static func scannedFiles() -> [URL] {
        var files = [repoRoot.appending(path: "README.md"), repoRoot.appending(path: "DESIGN.md")]
        let roots: [(String, Set<String>)] = [
            ("BodegasNYC", ["swift", "plist", "strings"]),
            ("docs", ["md", "html"])
        ]
        for (directory, extensions) in roots {
            let enumerator = FileManager.default.enumerator(
                at: repoRoot.appending(path: directory),
                includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                if extensions.contains(url.pathExtension) { files.append(url) }
            }
        }
        return files
    }

    /// protects=AC 16: no walk-related promise that walks stay on the phone
    /// ("only on your device", "never uploaded", "stays on the device",
    /// "stay on this phone", "never leaves") ships in the app's copy, the
    /// purpose strings, the privacy policy, the App Store and release docs,
    /// the PRD, README or DESIGN.md without the sharing exception in the
    /// same or the next sentence; and the search actually read the files it
    /// names; fails_when=any such sentence lacks the exception, or the
    /// search finds no files; no_claim=wording outside these five phrases
    /// (reviewed by hand in the PR), App Store Connect's live fields.
    @Test func noWalkPromiseLacksTheSharingException() throws {
        let files = Self.scannedFiles()
        #expect(files.count > 50, "the search found \(files.count) files; is #filePath the repo?")
        #expect(files.contains { $0.lastPathComponent == "PRIVACY.md" })
        var findings: [Finding] = []
        for url in files {
            let contents = try String(contentsOf: url, encoding: .utf8)
            let path = url.path.replacingOccurrences(of: Self.repoRoot.path + "/", with: "")
            findings += Self.findings(in: Self.chunks(of: contents, pathExtension: url.pathExtension), file: path)
        }
        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
    }

    /// protects=the judge itself: a planted promise without the exception
    /// fails, with the exception in the same or the next sentence passes,
    /// one not about walks is ignored, and Swift comments are not read as
    /// copy; fails_when=the rule lets a bare promise through, or flags the
    /// allowed wordings; no_claim=none beyond the rule.
    @Test func theJudgeFlagsOnlyABarePromise() {
        let bare = Self.findings(in: ["Your walks stay on this phone."], file: "planted")
        #expect(bare.map(\.sentence) == ["Your walks stay on this phone."])
        #expect(Self.findings(in: ["Your walks stay on this phone unless you share one."], file: "ok").isEmpty)
        #expect(Self.findings(
            in: ["The walk history is kept on the device and is never uploaded.\nA user can share a picture."],
            file: "ok"
        ).isEmpty)
        #expect(Self.findings(in: ["Motion data is never uploaded."], file: "not walks").isEmpty)
        let swift = "// Walks: this never leaves the two out of step.\nlet copy = \"Your walks stay on this phone.\""
        #expect(Self.findings(in: Self.chunks(of: swift, pathExtension: "swift"), file: "planted").count == 1)
        let comment = "// Walks: this never leaves the two out of step.\nlet copy = \"Walk somewhere.\""
        #expect(Self.findings(in: Self.chunks(of: comment, pathExtension: "swift"), file: "comment").isEmpty)
        #expect(Self.findings(in: ["Deleting keeps them. Walked blocks stay on this phone."], file: "kept").isEmpty)
    }
}
