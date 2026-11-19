import Foundation

/// The walk history file (#180): the app's own versioned JSON, raw fixes
/// only, extension `mybodegas` (O3, O5: no GPX, no encryption). Pure: no
/// I/O and no SwiftData; `WalkHistoryTransfer` reads the store and writes
/// the files.
///
/// Version 1:
///
/// ```json
/// {
///   "format": "my-bodegas-walk-history",
///   "version": 1,
///   "exportedAt": "2026-11-19T18:42:00.000Z",
///   "appVersion": "1.0.0 (3)",
///   "fixes": [
///     { "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "lat": 40.70612, "lon": -74.01133,
///       "t": 1786910061.123456716537475586, "ride": 0 }
///   ]
/// }
/// ```
///
/// `fixes` is in history order (`recordedAt`, then `id`, as
/// `WalkedPointSnapshot.sortsBefore`). `lat` and `lon` are written with
/// full `Double` precision. `ride` is the stored `RideEvidence` raw value,
/// written as stored. Nothing derived is written: no masks, days, match
/// state or `isMatched`.
///
/// `t` is Unix time in seconds (eng E1), a JSON number that carries every
/// bit of `recordedAt`. A `Date` holds seconds since 2001, and adding the
/// 1970 offset in `Double` arithmetic rounds to the coarser grid of the
/// larger sum, so any `recordedAt` with a bit below that grid (one ulp at
/// 2^30 s, about 0.24 µs) would come back changed. So `t` is written as the
/// exact decimal sum instead: the whole seconds as an integer, then the
/// fraction's shortest round-trip digits (`unixSeconds(_:)`). Any JSON
/// reader gets the nearest `Double`; `date(unixSeconds:)` gets the exact
/// `recordedAt` back for every time from 2001 on. Earlier times (no real
/// fix has one) are written as the plain `Double` and come back within a
/// microsecond.
nonisolated enum WalkHistoryFile {
    static let format = "my-bodegas-walk-history"
    static let currentVersion = 1
    static let fileExtension = "mybodegas"
    /// Declared in `Info.plist` under `UTExportedTypeDeclarations` (eng A8:
    /// the document type and its handler come with import, PR 2).
    static let typeIdentifier = "yukichi.bodegasnyc.walk-history"
    /// The file's name before the date. A file name, not copy (design D4):
    /// it lives outside `AppCopy`, as the shared picture's name does.
    static let fileNamePrefix = "My Bodegas Walks"

    /// The most fixes in one file, shared by export and import (eng A2): a
    /// longer history exports as part files of at most this many each. The
    /// starting value; PR 2 measures import at the cap and lowers it to the
    /// largest size that imports under 30 s and 300 MB.
    static let maxFixCount = 1_000_000

    /// One fix as the file carries it.
    nonisolated struct Fix: Equatable, Sendable {
        let id: UUID
        let latitude: Double
        let longitude: Double
        let recordedAt: Date
        /// The stored `RideEvidence` raw value, as stored.
        let ride: Int

        /// History order (#108): `recordedAt`, then `id`.
        static func sortsBefore(_ lhs: Fix, _ rhs: Fix) -> Bool {
            lhs.recordedAt != rhs.recordedAt ? lhs.recordedAt < rhs.recordedAt : lhs.id < rhs.id
        }
    }

    /// A read file's fixes, in file order.
    nonisolated struct Decoded: Equatable, Sendable {
        let version: Int
        let fixes: [Fix]
    }

    nonisolated enum DecodeError: Error, Equatable {
        /// Not this format: not JSON, another `format`, or a version under 1.
        case notWalkHistory
        /// A version newer than `currentVersion`.
        case newerVersion(Int)
    }

    // MARK: Encode

    /// The file for `fixes`, in the order given (the caller sorts).
    static func encode(_ fixes: some Collection<Fix>, exportedAt: Date, appVersion: String) throws -> Data {
        let envelope = Envelope(
            format: format,
            version: currentVersion,
            exportedAt: exportedAt.formatted(exportedAtStyle),
            appVersion: appVersion,
            fixes: fixes.map { fix in
                Entry(
                    id: fix.id,
                    lat: fix.latitude,
                    lon: fix.longitude,
                    t: unixSeconds(fix.recordedAt),
                    ride: fix.ride
                )
            }
        )
        return try JSONEncoder().encode(envelope)
    }

    /// `fixes` cut into consecutive parts of at most `maxFixCount` each
    /// (eng A2). An empty history is one empty part, so an export always
    /// writes a file.
    static func parts(of fixes: [Fix], maxFixCount: Int = maxFixCount) -> [ArraySlice<Fix>] {
        precondition(maxFixCount > 0)
        guard !fixes.isEmpty else { return [fixes[...]] }
        return stride(from: 0, to: fixes.count, by: maxFixCount).map { start in
            fixes[start ..< min(start + maxFixCount, fixes.count)]
        }
    }

    /// How many files a history of `fixCount` fixes exports as.
    static func partCount(fixCount: Int, maxFixCount: Int = maxFixCount) -> Int {
        max(1, (fixCount + maxFixCount - 1) / maxFixCount)
    }

    /// "My Bodegas Walks 2026-11-19.mybodegas", the date being the export
    /// day in New York time; "My Bodegas Walks 2026-11-19 part 1 of 2.mybodegas"
    /// when the history comes as more than one file (design D12).
    static func fileName(exportedAt: Date, part: Int, of count: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WalkedDayKey.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: exportedAt)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let suffix = count > 1 ? " part \(part) of \(count)" : ""
        return "\(fileNamePrefix) \(day)\(suffix).\(fileExtension)"
    }

    // MARK: Decode

    /// The fixes in `data`, strictly: any malformed entry fails the whole
    /// file. The round trip of what `encode` writes (AC 1). PR 2's import
    /// replaces the strict entry rule with the validation table (an invalid
    /// entry is skipped and counted) and adds the size checks.
    static func decode(_ data: Data) throws -> Decoded {
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw DecodeError.notWalkHistory
        }
        guard header.format == format, header.version >= 1 else { throw DecodeError.notWalkHistory }
        guard header.version <= currentVersion else { throw DecodeError.newerVersion(header.version) }
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode(Body.self, from: data).fixes
        } catch {
            throw DecodeError.notWalkHistory
        }
        let fixes = try entries.map { entry in
            guard let recordedAt = date(unixSeconds: entry.t) else { throw DecodeError.notWalkHistory }
            return Fix(
                id: entry.id,
                latitude: entry.lat,
                longitude: entry.lon,
                recordedAt: recordedAt,
                ride: entry.ride ?? 0
            )
        }
        return Decoded(version: header.version, fixes: fixes)
    }

    // MARK: Exact Unix seconds (eng E1)

    /// Seconds between 1970 and 2001, `Date`'s own reference.
    static let referenceOffset: Int64 = 978_307_200

    /// `date` as Unix seconds, exactly: the whole seconds since 2001 plus the
    /// 1970 offset as an integer, then the fraction's shortest round-trip
    /// digits. Exact for every finite time from 2001 on. A time before 2001
    /// (including -0.0: below zero, `seconds - floor(seconds)` is not always
    /// representable) or a non-finite one falls back to the plain `Double`,
    /// within a microsecond; no real fix is either.
    static func unixSeconds(_ date: Date) -> Decimal {
        let seconds = date.timeIntervalSinceReferenceDate
        let fallback = Decimal(date.timeIntervalSince1970)
        guard seconds.isFinite, seconds.sign == .plus, seconds < 1e15 else { return fallback }
        let whole = seconds.rounded(.down)
        let unixWhole = Int64(whole) + referenceOffset
        guard unixWhole >= 0 else { return fallback }
        let text = "\(unixWhole)" + fractionDigits(seconds - whole)
        return Decimal(string: text, locale: posix) ?? fallback
    }

    /// The `Date` that `unixSeconds` wrote, bit for bit; `nil` for a value
    /// that is not a finite number of seconds.
    static func date(unixSeconds: Decimal) -> Date? {
        guard unixSeconds.isFinite else { return nil }
        let text = unixSeconds.description
        let plain = /^(\d+)(?:\.(\d+))?$/
        guard let match = text.wholeMatch(of: plain),
              let unixWhole = Int64(match.output.1),
              unixWhole < Int64(1) << 52
        else {
            // Negative, exponent form or huge: the nearest `Double` will do.
            let seconds = NSDecimalNumber(decimal: unixSeconds).doubleValue
            return seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
        }
        let fraction = match.output.2.flatMap { Double("0.\($0)") } ?? 0
        // Both terms are exact, and their sum is the stored `Double`.
        return Date(timeIntervalSinceReferenceDate: Double(unixWhole - referenceOffset) + fraction)
    }

    /// "" for 0, else "." and the digits of `fraction` (in 0..<1) that
    /// `Double` reads back as exactly `fraction`.
    private static func fractionDigits(_ fraction: Double) -> String {
        guard fraction > 0 else { return "" }
        let text = "\(fraction)"
        guard let exponentMark = text.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
            // "0.123…"
            return String(text.drop { $0 != "." })
        }
        // "1.1920928955078125e-07": shift the point left.
        let mantissa = text[..<exponentMark].replacingOccurrences(of: ".", with: "")
        let exponent = Int(text[text.index(after: exponentMark)...]) ?? 0
        return "." + String(repeating: "0", count: max(0, -exponent - 1)) + mantissa
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// "2026-11-19T18:42:00.000Z": ISO 8601, UTC, milliseconds. Informational.
    private static let exportedAtStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    // MARK: Wire shapes

    private nonisolated struct Envelope: Encodable {
        let format: String
        let version: Int
        let exportedAt: String
        let appVersion: String
        let fixes: [Entry]
    }

    private nonisolated struct Header: Decodable {
        let format: String
        let version: Int
    }

    private nonisolated struct Body: Decodable {
        let fixes: [Entry]
    }

    private nonisolated struct Entry: Codable {
        let id: UUID
        let lat: Double
        let lon: Double
        let t: Decimal // swiftlint:disable:this identifier_name
        let ride: Int?
    }
}
