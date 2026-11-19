//
//  WalkHistoryFileTests.swift
//  BodegasNYCTests
//
//  #180 PR 1: the walk history file's encoding (AC 1, eng E1), its part
//  split (eng A2) and its names (design D12, D4). Pure: no store, no disk.
//

import Foundation
import Testing

@testable import BodegasNYC

struct WalkHistoryFileTests {
    private typealias Fix = WalkHistoryFile.Fix

    /// A fix at `seconds` since 2001, the `Date` reference.
    private static func fix(_ seconds: Double, id: UUID = UUID(), ride: Int = 0) -> Fix {
        Fix(
            id: id,
            latitude: 40.7 + Double.random(in: -0.2 ... 0.2),
            longitude: -74 + Double.random(in: -0.2 ... 0.2),
            recordedAt: Date(timeIntervalSinceReferenceDate: seconds),
            ride: ride
        )
    }

    private static let exportedAt = Date(timeIntervalSince1970: 1_795_000_000)

    private static func roundTrip(_ fixes: [Fix]) throws -> [Fix] {
        let data = try WalkHistoryFile.encode(fixes, exportedAt: exportedAt, appVersion: "1.0.0 (3)")
        return try WalkHistoryFile.decode(data).fixes
    }

    /// protects=AC 1 and eng E1: every field of every fix comes back
    /// exactly: the same ids, bit-identical latitude, longitude and
    /// `recordedAt` `Double`s, the stored ride value (0 to 3, written as
    /// stored), in the order written; over 2,000 random real-range fixes;
    /// fails_when=any time loses a bit (the plain `timeIntervalSince1970`
    /// `Double` drops one for about a third of them), a coordinate is
    /// rounded, a ride value is mapped, or the order changes;
    /// no_claim=what the store holds (WalkHistoryTransferTests) or PR 2's
    /// lenient import decoding.
    @Test func roundTripIsExact() throws {
        let fixes = (0 ..< 2_000).map { index in
            Self.fix(Double.random(in: 6.0e8 ..< 1.0e9), ride: index % 4)
        }
        let back = try Self.roundTrip(fixes)
        #expect(back.count == fixes.count)
        for (written, read) in zip(fixes, back) {
            #expect(read.id == written.id)
            #expect(read.latitude.bitPattern == written.latitude.bitPattern)
            #expect(read.longitude.bitPattern == written.longitude.bitPattern)
            #expect(
                read.recordedAt.timeIntervalSinceReferenceDate.bitPattern
                    == written.recordedAt.timeIntervalSinceReferenceDate.bitPattern,
                "t lost a bit at \(written.recordedAt.timeIntervalSinceReferenceDate)"
            )
            #expect(read.ride == written.ride)
        }
    }

    /// protects=eng E1's reason: two fixes 1 µs apart keep their times and
    /// so their order, and a time whose lowest bit the plain Unix `Double`
    /// would drop comes back exact; the edge values (whole seconds, a tiny
    /// fraction written in exponent form, the 2001 reference) too;
    /// fails_when=`t` is written as a plain `Double` or as millisecond
    /// text; no_claim=pre-1970 or non-finite times (no real fix has one).
    @Test func neighbouringTimesKeepTheirOrder() throws {
        // 2^29 + 2^-23: the lowest bit at this size, lost by r + 978307200.
        let oddBit = 536_870_912.0 + 1.0 / 8_388_608
        let naive = Date(timeIntervalSince1970: Date(timeIntervalSinceReferenceDate: oddBit).timeIntervalSince1970)
        #expect(naive.timeIntervalSinceReferenceDate != oddBit, "the plain Double no longer loses this bit")

        let base = 784_000_000.123_456
        let times = [base, base + 0.000_001, oddBit, 800_000_000, 0, 1e-7, 0.5, 1_000_000_000.999_999]
        let fixes = times.map { Self.fix($0) }
        let back = try Self.roundTrip(fixes)
        #expect(back.map(\.recordedAt) == fixes.map(\.recordedAt))
        #expect(back[0].recordedAt < back[1].recordedAt)
    }

    /// protects=the stated limit of the exact `t`: times before 2001 (the
    /// `Date` reference, -0.0 included), which no real fix has, take the
    /// plain-`Double` fallback and come back within a microsecond, still in
    /// order; fails_when=a pre-2001 time is lost, garbled or reordered, or
    /// the fallback is taken for a time from 2001 on (+0.0 stays exact);
    /// no_claim=bit-exactness before 2001, which the format does not promise.
    @Test func timesBefore2001ComeBackWithinAMicrosecond() throws {
        let times = [-0.0, -1e-9, -1e-7, -0.5, -86_400.25, -500_000_000.123_456]
        let fixes = times.map { Self.fix($0) }
        let back = try Self.roundTrip(fixes)
        for (written, read) in zip(fixes, back) {
            let error = abs(read.recordedAt.timeIntervalSince(written.recordedAt))
            #expect(error < 1e-6, "\(written.recordedAt.timeIntervalSinceReferenceDate) came back off by \(error) s")
        }
        let ascending = try Self.roundTrip(fixes.sorted(by: Fix.sortsBefore)).map(\.recordedAt)
        // Times closer than the fallback's grid (-1e-9 and -0.0) may tie, never swap.
        #expect(zip(ascending, ascending.dropFirst()).allSatisfy { $0 <= $1 }, "pre-2001 times lost their order")
        let zero = try Self.roundTrip([Self.fix(0)])[0].recordedAt.timeIntervalSinceReferenceDate
        #expect(zero.bitPattern == (0.0).bitPattern)
    }

    /// protects=the version 1 shape: `format`, `version`, `exportedAt`
    /// (ISO 8601 UTC with milliseconds), `appVersion`, and per fix exactly
    /// `id`, `lat`, `lon`, `t` (a JSON number, Unix seconds) and `ride`,
    /// nothing derived (no `isMatched`, masks or days);
    /// fails_when=a key is renamed or added, `t` is text or not Unix time,
    /// or `exportedAt` is local time; no_claim=the bytes' key order.
    @Test func fileShapeIsVersionOne() throws {
        let fix = Self.fix(784_000_000.5, ride: 2)
        let data = try WalkHistoryFile.encode([fix], exportedAt: Self.exportedAt, appVersion: "1.0.0 (3)")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["format", "version", "exportedAt", "appVersion", "fixes"])
        #expect(object["format"] as? String == "my-bodegas-walk-history")
        #expect(object["version"] as? Int == 1)
        #expect(object["exportedAt"] as? String == "2026-11-18T11:06:40.000Z")
        #expect(object["appVersion"] as? String == "1.0.0 (3)")
        let entries = try #require(object["fixes"] as? [[String: Any]])
        let entry = try #require(entries.first)
        #expect(Set(entry.keys) == ["id", "lat", "lon", "t", "ride"])
        #expect(entry["id"] as? String == fix.id.uuidString)
        #expect(entry["ride"] as? Int == 2)
        let unix = try #require((entry["t"] as? NSNumber)?.doubleValue)
        #expect(abs(unix - fix.recordedAt.timeIntervalSince1970) < 1e-6)
        #expect(String(bytes: data, encoding: .utf8)?.contains("\"t\":1762307200.5") == true)
    }

    /// protects=eng A2: a history over the cap splits into consecutive
    /// parts of at most the cap, in order, which together are the history;
    /// the count matches `partCount`; an exact multiple has no empty tail;
    /// an empty history is one empty part (an export always writes a file);
    /// fails_when=a part exceeds the cap, a fix is lost, repeated or moved,
    /// or the dialog's count disagrees with the files; no_claim=the cap's
    /// final value (PR 2 measures it).
    @Test func overCapHistorySplitsIntoParts() {
        let fixes = (0 ..< 7).map { Self.fix(784_000_000 + Double($0)) }
        let parts = WalkHistoryFile.parts(of: fixes, maxFixCount: 3)
        #expect(parts.map(\.count) == [3, 3, 1])
        #expect(parts.flatMap { $0 } == fixes)
        #expect(WalkHistoryFile.partCount(fixCount: 7, maxFixCount: 3) == 3)

        #expect(WalkHistoryFile.parts(of: Array(fixes.prefix(6)), maxFixCount: 3).map(\.count) == [3, 3])
        #expect(WalkHistoryFile.partCount(fixCount: 6, maxFixCount: 3) == 2)
        #expect(WalkHistoryFile.parts(of: fixes, maxFixCount: 7).count == 1)
        #expect(WalkHistoryFile.partCount(fixCount: 7, maxFixCount: 7) == 1)

        #expect(WalkHistoryFile.parts(of: [], maxFixCount: 3).map(\.count) == [0])
        #expect(WalkHistoryFile.partCount(fixCount: 0, maxFixCount: 3) == 1)
        #expect(WalkHistoryFile.maxFixCount == 100_000) // set by measurement in #180 PR 2 (eng A2)
    }

    /// protects=the file's name: "My Bodegas Walks <yyyy-MM-dd>.mybodegas"
    /// on the export day in New York time, with " part 1 of 2" only when
    /// the history comes as more than one file; fails_when=the date is UTC
    /// (03:00 UTC is the evening before in New York) or a single file says
    /// "part"; no_claim=how the share sheet shows it.
    @Test func fileNamesUseTheNewYorkDay() throws {
        let lateEvening = try #require(ISO8601DateFormatter().date(from: "2026-11-20T03:00:00Z"))
        #expect(
            WalkHistoryFile.fileName(exportedAt: lateEvening, part: 1, of: 1) == "My Bodegas Walks 2026-11-19.mybodegas"
        )
        #expect(
            WalkHistoryFile.fileName(exportedAt: lateEvening, part: 2, of: 2)
                == "My Bodegas Walks 2026-11-19 part 2 of 2.mybodegas"
        )
    }

    /// protects=the strict decoder refuses what is not this format and a
    /// newer version, so a round trip can only pass on a real file;
    /// fails_when=another JSON file, a wrong `format` or version 0 decodes,
    /// or version 2 is read as 1; no_claim=PR 2's validation table (skipped
    /// entries, size limits, messages).
    @Test func decodeRefusesOtherFilesAndNewerVersions() throws {
        func file(format: String = "my-bodegas-walk-history", version: Int) -> Data {
            Data(#"{"format":"\#(format)","version":\#(version),"fixes":[]}"#.utf8)
        }
        #expect(try WalkHistoryFile.decode(file(version: 1)).fixes.isEmpty)
        #expect(throws: WalkHistoryFile.DecodeError.notWalkHistory) { try WalkHistoryFile.decode(Data("[]".utf8)) }
        #expect(throws: WalkHistoryFile.DecodeError.notWalkHistory) {
            try WalkHistoryFile.decode(file(format: "gpx", version: 1))
        }
        #expect(throws: WalkHistoryFile.DecodeError.notWalkHistory) { try WalkHistoryFile.decode(file(version: 0)) }
        #expect(throws: WalkHistoryFile.DecodeError.newerVersion(2)) { try WalkHistoryFile.decode(file(version: 2)) }
    }
}
