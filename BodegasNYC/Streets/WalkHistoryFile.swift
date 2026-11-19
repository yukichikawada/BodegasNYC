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

    /// A walk history file handed to the app (`.onOpenURL`, #180 eng A10):
    /// a file URL with this format's extension.
    static func isHistoryFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == fileExtension
    }

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

    /// A file read for import (#180 PR 2, the spec's validation table): the
    /// valid fixes, each id once (its first valid occurrence), in file
    /// order, and how many entries were skipped as unreadable.
    nonisolated struct Validated: Equatable, Sendable {
        let version: Int
        let fixes: [Fix]
        /// Entries that were not a readable fix. A later valid duplicate of
        /// an id already read is dropped without being counted.
        let skippedCount: Int
    }

    nonisolated enum DecodeError: Error, Equatable {
        /// Not this format: not JSON, another `format`, a `version` or
        /// `fixes` missing or of the wrong type, or a version under 1.
        case notWalkHistory
        /// A version newer than `currentVersion`.
        case newerVersion(Int)
        /// More than `maxFixCount` entries (eng A2), or a file larger than
        /// `maxFileBytes` (checked by the transfer before reading).
        case tooLarge
    }

    /// The largest file import reads, derived from the cap (eng A2: cap ×
    /// 160 bytes, not a second number). A written fix is about 110 bytes.
    static func maxFileBytes(maxFixCount: Int = maxFixCount) -> Int {
        maxFixCount * bytesPerFixAllowance
    }

    static let bytesPerFixAllowance = 160

    /// No real fix is older: the app did not exist (validation table).
    static let earliestFixTime = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01T00:00:00Z
    /// How far past the importing phone's clock a fix may be: clocks and
    /// time zones drift; more than a day is a broken file.
    static let futureAllowance: TimeInterval = 24 * 60 * 60

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

    /// The fixes in `data`, strictly: any entry that is not a readable fix
    /// fails the whole file, every entry is kept (duplicates too) and no
    /// time bound applies. The round trip of what `encode` writes (AC 1);
    /// import reads through `validate` instead. One parser serves both.
    static func decode(_ data: Data) throws -> Decoded {
        let (version, entries) = try parse(data)
        let fixes = try entries.map { entry in
            guard let fix = entry.fix(notBefore: nil, notAfter: nil) else { throw DecodeError.notWalkHistory }
            return fix
        }
        return Decoded(version: version, fixes: fixes)
    }

    /// The fixes in `data` for import, by the spec's validation table: the
    /// file is refused when it is not this format, is newer, or holds more
    /// than `maxFixCount` entries; otherwise each entry that is not an
    /// object, lacks `id`, `lat`, `lon` or `t`, has one of the wrong type,
    /// an unparseable `id` or `t`, a non-finite or out-of-range coordinate,
    /// or a `t` before 2020 or more than a day after `now` is skipped and
    /// counted. A `ride` that is missing or not 0 to 3 reads as 0. An id
    /// seen twice keeps its first valid occurrence. Fixes outside New York
    /// are kept: they are raw history, and the matcher ignores them.
    static func validate(_ data: Data, now: Date, maxFixCount: Int = maxFixCount) throws -> Validated {
        let (version, entries) = try parse(data)
        guard entries.count <= maxFixCount else { throw DecodeError.tooLarge }
        let latest = now.addingTimeInterval(futureAllowance)
        var seen = Set<UUID>()
        var fixes: [Fix] = []
        fixes.reserveCapacity(entries.count)
        var skipped = 0
        for entry in entries {
            guard let fix = entry.fix(notBefore: earliestFixTime, notAfter: latest) else {
                skipped += 1
                continue
            }
            if seen.insert(fix.id).inserted { fixes.append(fix) }
        }
        return Validated(version: version, fixes: fixes, skippedCount: skipped)
    }

    /// The header checks, then every entry as read, in file order.
    private static func parse(_ data: Data) throws -> (version: Int, entries: [Entry]) {
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw DecodeError.notWalkHistory
        }
        guard header.format == format, header.version >= 1 else { throw DecodeError.notWalkHistory }
        guard header.version <= currentVersion else { throw DecodeError.newerVersion(header.version) }
        do {
            return (header.version, try JSONDecoder().decode(Body.self, from: data).fixes)
        } catch {
            throw DecodeError.notWalkHistory
        }
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

    /// One entry of `fixes`, read leniently: a field that is missing or of
    /// the wrong type is `nil` rather than a failure of the whole file, and
    /// an entry that is not an object has every field `nil`. `t` is read as
    /// `Decimal` (eng E1: the exact digits, not the nearest `Double`).
    private nonisolated struct Entry: Codable {
        let id: UUID?
        let lat: Double?
        let lon: Double?
        let t: Decimal? // swiftlint:disable:this identifier_name
        let ride: Int?

        init(id: UUID, lat: Double, lon: Double, t: Decimal, ride: Int) { // swiftlint:disable:this identifier_name
            self.id = id
            self.lat = lat
            self.lon = lon
            self.t = t
            self.ride = ride
        }

        init(from decoder: any Decoder) {
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            id = try? fields?.decode(UUID.self, forKey: .id)
            lat = try? fields?.decode(Double.self, forKey: .lat)
            lon = try? fields?.decode(Double.self, forKey: .lon)
            t = try? fields?.decode(Decimal.self, forKey: .t)
            ride = try? fields?.decode(Int.self, forKey: .ride)
        }

        /// The fix, or `nil` when the entry is not a readable one: an
        /// unparseable or missing field, a non-finite or out-of-range
        /// coordinate, or a time outside the bounds given. `ride` outside
        /// 0 to 3, or missing, reads as 0 (unknown).
        func fix(notBefore earliest: Date?, notAfter latest: Date?) -> Fix? {
            guard let id, let lat, let lon, let unixSeconds = t,
                  lat.isFinite, lon.isFinite, (-90.0 ... 90.0).contains(lat), (-180.0 ... 180.0).contains(lon),
                  let recordedAt = WalkHistoryFile.date(unixSeconds: unixSeconds)
            else { return nil }
            if let earliest, recordedAt < earliest { return nil }
            if let latest, recordedAt > latest { return nil }
            let ride = ride.flatMap { (0 ... 3).contains($0) ? $0 : nil } ?? 0
            return Fix(id: id, latitude: lat, longitude: lon, recordedAt: recordedAt, ride: ride)
        }
    }
}
