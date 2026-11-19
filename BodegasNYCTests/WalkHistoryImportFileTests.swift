//
//  WalkHistoryImportFileTests.swift
//  BodegasNYCTests
//
//  #180 PR 2: `WalkHistoryFile.validate`, import's reading of a file: one
//  test per row of the spec's validation table (AC 7), the exact `t` round
//  trip through import (eng E1), and the cap shared with export (eng A2).
//  Pure: no store, no disk.
//

import Foundation
import Testing

@testable import BodegasNYC

struct WalkHistoryImportFileTests {
    private typealias Fix = WalkHistoryFile.Fix
    private typealias DecodeError = WalkHistoryFile.DecodeError

    /// The importing phone's clock: 2026-11-19 18:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_795_543_200)
    private static let validID = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    /// A file around raw `fixes` JSON, so entries can be malformed.
    private static func file(
        format: String = #""my-bodegas-walk-history""#,
        version: String = "1",
        fixes: String,
        extra: String = #","exportedAt":"2026-11-19T18:42:00.000Z","appVersion":"1.1.0 (4)""#
    ) -> Data {
        Data(#"{"format":\#(format),"version":\#(version)\#(extra),"fixes":\#(fixes)}"#.utf8)
    }

    /// One entry with valid fields unless overridden (raw JSON values).
    private static func entry(
        id: String? = "\"\(validID)\"",
        lat: String? = "40.70612",
        lon: String? = "-74.01133",
        t: String? = "1795000000.5", // swiftlint:disable:this identifier_name
        ride: String? = "1",
        extra: String = ""
    ) -> String {
        let fields = [("id", id), ("lat", lat), ("lon", lon), ("t", t), ("ride", ride)]
            .compactMap { key, value in value.map { "\"\(key)\":\($0)" } }
        return "{" + (fields + (extra.isEmpty ? [] : [extra])).joined(separator: ",") + "}"
    }

    private static func validate(_ data: Data, maxFixCount: Int = WalkHistoryFile.maxFixCount) throws
        -> WalkHistoryFile.Validated {
        try WalkHistoryFile.validate(data, now: now, maxFixCount: maxFixCount)
    }

    /// protects=AC 7, rows "not JSON / wrong format / version or fixes
    /// missing or of the wrong type" and "version less than 1": each is
    /// refused as not a walk history file; fails_when=any of them reads as a
    /// file (with zero fixes, or partly); no_claim=the message shown (view
    /// model tests) or that nothing is stored (transfer tests).
    @Test func otherFilesAreRefused() {
        let refused: [Data] = [
            Data("not json".utf8),
            Data("[]".utf8),
            Data(#"{"version":1,"fixes":[]}"#.utf8),
            Self.file(format: #""gpx""#, fixes: "[]"),
            Self.file(format: "7", fixes: "[]"),
            Data(#"{"format":"my-bodegas-walk-history","fixes":[]}"#.utf8),
            Self.file(version: #""1""#, fixes: "[]"),
            Self.file(version: "1.5", fixes: "[]"),
            Data(#"{"format":"my-bodegas-walk-history","version":1}"#.utf8),
            Self.file(fixes: #""none""#),
            Self.file(fixes: "{}"),
            Self.file(version: "0", fixes: "[]"),
            Self.file(version: "-3", fixes: "[]")
        ]
        for data in refused {
            #expect(throws: DecodeError.notWalkHistory, "\(String(decoding: data, as: UTF8.self))") {
                try Self.validate(data)
            }
        }
    }

    /// protects=AC 7, row "version greater than currentVersion": refused as
    /// newer, before its fixes are read (a newer shape may differ);
    /// fails_when=a version 2 file is read as version 1, or is called not a
    /// walk file; no_claim=the update message (view model tests).
    @Test func aNewerVersionIsRefusedAsNewer() {
        #expect(throws: DecodeError.newerVersion(2)) { try Self.validate(Self.file(version: "2", fixes: "[]")) }
        #expect(throws: DecodeError.newerVersion(9)) { try Self.validate(Self.file(version: "9", fixes: #""x""#)) }
    }

    /// protects=AC 7, row "more than maxFixCount entries" and eng A2: the
    /// cap is the shared `maxFixCount`, counted over entries (valid or not),
    /// and a file at the cap reads; the byte limit is the cap × 160;
    /// fails_when=a file one over the cap reads, one at the cap is refused,
    /// or the byte limit is a second number; no_claim=the measured value of
    /// the cap (WalkHistoryPerformanceTests).
    @Test func theCapIsSharedAndExact() throws {
        let entries = (0 ..< 3).map { _ in Self.entry(id: "\"\(UUID())\"") }
        let three = Self.file(fixes: "[" + entries.joined(separator: ",") + "]")
        #expect(try Self.validate(three, maxFixCount: 3).fixes.count == 3)
        #expect(throws: DecodeError.tooLarge) { try Self.validate(three, maxFixCount: 2) }
        let junk = Self.file(fixes: "[1,2,3]")
        #expect(throws: DecodeError.tooLarge) { try Self.validate(junk, maxFixCount: 2) }
        #expect(WalkHistoryFile.maxFileBytes(maxFixCount: 1_000) == 160_000)
        #expect(WalkHistoryFile.maxFileBytes() == WalkHistoryFile.maxFixCount * 160)
    }

    /// protects=AC 7, row "an entry that is not an object, or lacks id, lat,
    /// lon or t, or has one with the wrong JSON type": that entry is skipped
    /// and counted, and the rest import; fails_when=one bad entry refuses the
    /// whole file, is imported, or is not counted; no_claim=the skipped line
    /// in the sheet (view model tests).
    @Test func malformedEntriesAreSkippedAndCounted() throws {
        let bad = [
            "1", #""fix""#, "null", "[]",
            Self.entry(id: nil), Self.entry(lat: nil), Self.entry(lon: nil), Self.entry(t: nil),
            Self.entry(id: "42"), Self.entry(lat: #""40.7""#), Self.entry(lon: "true"),
            Self.entry(t: #""2026-08-16T19:54:21.123Z""#)
        ]
        let good = Self.entry()
        let data = Self.file(fixes: "[" + (bad + [good]).joined(separator: ",") + "]")
        let read = try Self.validate(data)
        #expect(read.skippedCount == bad.count)
        #expect(read.fixes.map(\.id) == [UUID(uuidString: Self.validID)])
    }

    /// protects=AC 7, row "unparseable id or t, out-of-range coordinate, t
    /// more than 24 hours after now, or before 2020-01-01": each fix is
    /// skipped and counted; the bounds themselves are inside; fixes outside
    /// New York are kept; fails_when=a bad fix imports, a good one at a
    /// bound is dropped, or a fix in Tokyo is dropped; no_claim=non-finite
    /// coordinates, which JSON cannot carry (a non-number is the wrong type,
    /// above).
    @Test func outOfRangeFixesAreSkippedAndBoundsKept() throws {
        let dayAfter = Self.now.timeIntervalSince1970 + 86_400
        let bad = [
            Self.entry(id: #""not-a-uuid""#),
            Self.entry(t: "1e300"),
            Self.entry(lat: "90.000001"), Self.entry(lat: "-91"),
            Self.entry(lon: "180.5"), Self.entry(lon: "-181"),
            Self.entry(t: "\(Int(dayAfter) + 1)"),
            Self.entry(t: "1577836799.999")
        ]
        let edges = [
            Self.entry(id: "\"\(UUID())\"", lat: "90", lon: "-180", t: "1577836800"),
            Self.entry(id: "\"\(UUID())\"", lat: "-90", lon: "180", t: "\(Int(dayAfter))"),
            Self.entry(id: "\"\(UUID())\"", lat: "35.6762", lon: "139.6503") // Tokyo
        ]
        let read = try Self.validate(Self.file(fixes: "[" + (bad + edges).joined(separator: ",") + "]"))
        #expect(read.skippedCount == bad.count)
        #expect(read.fixes.count == edges.count)
        #expect(read.fixes.contains { $0.latitude == 35.6762 && $0.longitude == 139.6503 })
    }

    /// protects=AC 7, rows "ride not 0, 1 or 2" and "a missing ride": read
    /// as 0 (the transfer then stores `.imported`, eng E2), while 1, 2 and 3
    /// are kept as written; fails_when=an odd ride skips the fix, or a known
    /// ride is mapped; no_claim=the stored value (transfer tests).
    @Test func rideValuesOutsideTheEnumReadAsUnknown() throws {
        let rides: [(String?, Int)] = [
            (nil, 0), ("0", 0), ("1", 1), ("2", 2), ("3", 3), ("4", 0), ("-1", 0), (#""2""#, 0), ("1.5", 0)
        ]
        let entries = rides.map { Self.entry(id: "\"\(UUID())\"", ride: $0.0) }
        let read = try Self.validate(Self.file(fixes: "[" + entries.joined(separator: ",") + "]"))
        #expect(read.skippedCount == 0)
        #expect(read.fixes.map(\.ride) == rides.map(\.1))
    }

    /// protects=AC 7, row "the same id twice": the first valid occurrence
    /// wins; an invalid earlier one is skipped and counted; later valid
    /// duplicates are dropped without being counted; fails_when=a duplicate
    /// is imported twice, the later copy wins, or a dropped duplicate is
    /// reported as unreadable; no_claim=duplicates against the store (the
    /// transfer's merge by id).
    @Test func duplicateIDsKeepTheFirstValidOccurrence() throws {
        let entries = [
            Self.entry(lat: "999"),        // invalid, same id: skipped and counted
            Self.entry(lat: "40.1"),       // first valid: kept
            Self.entry(lat: "40.2"),       // later valid duplicate: dropped, not counted
            Self.entry(lat: "40.3", t: "1")  // later invalid duplicate: skipped and counted
        ]
        let read = try Self.validate(Self.file(fixes: "[" + entries.joined(separator: ",") + "]"))
        #expect(read.fixes.count == 1)
        #expect(read.fixes.first?.latitude == 40.1)
        #expect(read.skippedCount == 2)
    }

    /// protects=AC 7, rows "exportedAt or appVersion missing or malformed"
    /// and "unknown extra keys at any level": ignored; fails_when=import
    /// depends on either informational field or rejects a key it does not
    /// know; no_claim=a future version's meaning for those keys.
    @Test func informationalAndUnknownKeysAreIgnored() throws {
        let entry = Self.entry(extra: #""speed":1.4,"nested":{"a":[1,2]}"#)
        for extra in ["", #","exportedAt":17,"appVersion":null"#, #","exportedAt":"yesterday","device":{"x":1}"#] {
            let read = try Self.validate(Self.file(fixes: "[\(entry)]", extra: extra))
            #expect(read.fixes.count == 1)
            #expect(read.skippedCount == 0)
        }
    }

    /// protects=eng E1 through import: what export writes, import reads back
    /// with the same ids, bit-identical coordinates and `recordedAt` (t is
    /// read as `Decimal`), the ride values and the order, including two
    /// fixes a microsecond apart; fails_when=import reads `t` as a `Double`
    /// (the low bit is lost for about half of real times) or reorders;
    /// no_claim=times before 2020, which import refuses by design.
    @Test func importReadsExportExactly() throws {
        let base = 1_795_000_000.123_456
        var fixes = (0 ..< 1_000).map { index in
            Fix(
                id: UUID(),
                latitude: 40.7 + Double.random(in: -0.2 ... 0.2),
                longitude: -74 + Double.random(in: -0.2 ... 0.2),
                recordedAt: Date(timeIntervalSince1970: Double.random(in: 1.6e9 ..< 1.79e9)),
                ride: index % 4
            )
        }
        fixes.append(Fix(id: UUID(), latitude: 40.7, longitude: -74, recordedAt: Date(timeIntervalSince1970: base), ride: 0))
        fixes.append(Fix(
            id: UUID(), latitude: 40.7, longitude: -74, recordedAt: Date(timeIntervalSince1970: base + 0.000_001), ride: 0
        ))
        let data = try WalkHistoryFile.encode(fixes, exportedAt: Self.now, appVersion: "1.1.0 (4)")
        let read = try Self.validate(data)
        #expect(read.skippedCount == 0)
        #expect(read.fixes.count == fixes.count)
        for (written, back) in zip(fixes, read.fixes) {
            #expect(back.id == written.id)
            #expect(back.latitude.bitPattern == written.latitude.bitPattern)
            #expect(back.longitude.bitPattern == written.longitude.bitPattern)
            #expect(
                back.recordedAt.timeIntervalSinceReferenceDate.bitPattern
                    == written.recordedAt.timeIntervalSinceReferenceDate.bitPattern
            )
            #expect(back.ride == written.ride)
        }
        #expect(read.fixes[read.fixes.count - 2].recordedAt < read.fixes[read.fixes.count - 1].recordedAt)
    }
}
