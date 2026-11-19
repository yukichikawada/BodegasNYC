//
//  HistoryImportCopyTests.swift
//  BodegasNYCTests
//
//  #180 PR 2: the import's strings are the design review's copy table,
//  character for character, with their kinds (registered for the voice
//  rules in AppCopyVoiceTests).
//

import Foundation
import Testing

@testable import BodegasNYC

struct HistoryImportCopyTests {
    /// protects=the design review's copy table for import (D1 to D6, D9,
    /// D11, DS1, DS4) with each string's kind, the menu item's "…", the
    /// days template (never points), the reused count-failed line and the
    /// store-unavailable line; none names the app (D4); fails_when=a string
    /// drifts, a kind changes, or a superseded spec draft returns ("This
    /// isn't a My Bodegas walk file.", "That didn't work. Try again.");
    /// no_claim=where each is shown (views, UI test).
    @Test func importCopyMatchesTheDesignTable() {
        typealias Import = AppCopy.HistoryImport
        let table: [(Import, CopyString.Kind, String)] = [
            (.menuItem, .label, "Import History"),
            (.menuHint, .body, "Adds walks from a file."),
            (.heading, .title, "Add walks from this file?"),
            (.partlyHere, .body, "Some of it is already on this phone. Only the rest is added."),
            (.skippedEntries, .body, "Part of the file couldn't be read. The rest comes in."),
            (.estimates, .body, "Days from a file show as estimates. This phone can't check them for rides."),
            (.consequence, .body,
             "They mix into your blocks, days and counts. Taking them out again means clearing everything."),
            (.footer, .body, "Walks recorded on two phones can count distance twice."),
            (.addAction, .label, "Add Walks"),
            (.reading, .value, "Reading the file"),
            (.readingAnnouncement, .body, "Reading the file."),
            (.saving, .value, "Adding your walks"),
            (.savingAnnouncement, .body, "Adding your walks."),
            (.countingAnnouncement, .body, "Counting your blocks."),
            (.done, .body, "Your walks are in."),
            (.showYourWalks, .label, "Show Your Walks"),
            (.recordingOff, .body, "Recording is off on this phone."),
            (.nothingNewTitle, .title, "Nothing new in this file."),
            (.nothingNewBody, .body, "Every walk in it is already on this phone."),
            (.noWalks, .body, "This file has no walks in it."),
            (.nothingReadable, .body, "Nothing in this file could be read. Nothing was added."),
            (.wrongFile, .body, "This isn't a walk history file."),
            (.newerFormat, .body, "This file is from a newer version of this app. Update, then import it."),
            (.tooLarge, .body, "This file is too large to import."),
            (.readFailure, .body, "The file couldn't be read. Open it again."),
            (.saveFailure, .body, "Those walks didn't save. Try again."),
            (.clearedMeanwhile, .body, "History was cleared, so nothing was added."),
            (.storeUnavailable, .body, "Streets Walked isn't available right now."),
            (.replaced, .body, "Another file opened.")
        ]
        #expect(table.count == Import.allCases.count)
        for (copy, kind, text) in table {
            #expect(copy.copy == CopyString(kind: kind, text: text))
        }
        #expect(Import.menuItem.menuItemWithEllipsis == "Import History\u{2026}")
        #expect(Import.reading.withTrailingEllipsis == "Reading the file\u{2026}")
        #expect(AppCopy.historyImportDays(84) == CopyString(kind: .value, text: "84 days of recording"))
        #expect(AppCopy.historyImportDays(1).text == "1 day of recording")
        #expect(AppCopy.historyImportDays(1_204).text == "1,204 days of recording")
        #expect(HistoryImportMessage.countFailed.copy == AppCopy.YourBlocks.countFailed.copy)
        #expect(HistoryImportMessage.wrongFile.copy == Import.wrongFile.copy)
    }
}
