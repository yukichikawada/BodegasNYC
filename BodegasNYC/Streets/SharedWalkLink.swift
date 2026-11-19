import Compression
import Foundation

/// A shared walk as a link (#177 PR 2, eng E5, E7): everything the walk is,
/// in the URL's fragment, which browsers and link previews never send to a
/// server. Pure and `nonisolated`.
///
/// `https://yukichikawada.github.io/BodegasNYC/walk/#1.<payload>.w`
///
/// `payload` is base64url without padding of the raw DEFLATE of these
/// unsigned LEB128 varints, in order: the first day as `yyyymmdd`; days
/// minus 1 (at most 3,659); metres; the new count; flags (bit 0: the range
/// includes estimated days; every other bit 0 in version 1); the block
/// count `n` (1 to 5,000); `n` deltas of the ascending `physicalid`s, the
/// first from 0, each at least 1. Every varint fits a `UInt32`. The trailing
/// `.w` is a fixed letter, so a linkifier that clips a trailing `-` or `_`
/// leaves a link that fails loudly instead of decoding to the wrong walk.
///
/// A link holds no times of day, no raw fixes, no name and no device or
/// account identifier.
nonisolated enum SharedWalkLink {
    /// The one place the link's host and path live. The entitlement
    /// (`applinks:` + `host`) and the fallback page (`docs/walk/index.html`,
    /// served at `path` from the project site) must agree; a unit test reads
    /// both.
    static let host = "yukichikawada.github.io"
    static let path = "/BodegasNYC/walk/"
    static var base: String { "https://" + host + path }

    static let version = "1"
    static let terminator = ".w"

    /// The largest walk a link holds (eng E5): the most blocks measured on
    /// a phone (DESIGN.md decisions log, 2026-10-23).
    static let maxBlocks = 5_000
    /// Days minus 1 is at most this: 3,660 days in all.
    static let maxDayOffset = 3_659
    /// A link the form makes is at most this long, in characters.
    static let maxURLLength = 2_000
    /// A fragment longer than this is not read.
    static let maxFragmentLength = 4_096
    /// Inflating stops here; a payload that would grow past it is damaged.
    static let maxInflatedBytes = 64 * 1_024

    /// Metres past this (about 6,200 miles) are not a walk.
    static let maxMeters = 10_000_000
    /// Days before the first or after the last of these are not a walk.
    static let earliestDay = WalkedDayKey(value: 20200101)
    static let latestDay = WalkedDayKey(value: 21001231)

    static func isInDayRange(_ day: WalkedDayKey) -> Bool {
        day >= earliestDay && day <= latestDay
    }

    /// Bit 0 of the flags: the range includes an estimated day.
    static let estimateFlag: UInt32 = 1

    enum Encoded: Equatable {
        case url(URL)
        /// Over 5,000 blocks, over 2,000 characters, or a value no link can
        /// hold (no blocks, a span past 3,660 days, a count past `UInt32`).
        case tooLong
    }

    enum Decoded: Equatable, Sendable {
        case walk(SharedWalk)
        /// A link format newer than this version reads.
        case needsUpdate
        /// A walk link that does not decode.
        case damaged
    }

    // MARK: Encoding

    /// Refuses (`.tooLong`) anything the decoder would call damaged, so a
    /// link is never made that cannot be opened: past the caps, outside the
    /// day range, more new blocks than blocks, metres past the cap, or a
    /// block id of 0. The first delta is at least 1, so 0 cannot be
    /// written; the bundled street file has no `physicalid` 0 (its ids run
    /// 3 to 208,400, checked 2026-11-19), so a real walk never holds one,
    /// and a walk that somehow did is refused whole rather than sent with
    /// a different block count than its picture.
    static func encode(_ walk: SharedWalk) -> Encoded {
        let ids = walk.blockIDs.sorted()
        guard let firstID = ids.first, firstID >= 1, ids.count <= maxBlocks,
              let offset = dayOffset(from: walk.firstDay, to: walk.lastDay), (0 ... maxDayOffset).contains(offset),
              isInDayRange(walk.firstDay), isInDayRange(walk.lastDay),
              (0 ... maxMeters).contains(walk.meters), (0 ... ids.count).contains(walk.newCount),
              let meters = UInt32(exactly: walk.meters), let newCount = UInt32(exactly: walk.newCount)
        else { return .tooLong }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(ids.count * 2 + 24)
        appendVarint(UInt32(walk.firstDay.value), to: &bytes)
        appendVarint(UInt32(offset), to: &bytes)
        appendVarint(meters, to: &bytes)
        appendVarint(newCount, to: &bytes)
        appendVarint(walk.isEstimate ? estimateFlag : 0, to: &bytes)
        appendVarint(UInt32(ids.count), to: &bytes)
        var previous: UInt32 = 0
        for id in ids {
            appendVarint(id - previous, to: &bytes)
            previous = id
        }
        // Raw DEFLATE (RFC 1951): what `compression_stream`'s ZLIB inflates.
        guard let deflated = try? (Data(bytes) as NSData).compressed(using: .zlib) as Data else { return .tooLong }
        let text = base + "#" + version + "." + base64URL(deflated) + terminator
        guard text.count <= maxURLLength, let url = URL(string: text) else { return .tooLong }
        return .url(url)
    }

    // MARK: Decoding

    /// Whether `url` is a walk link at all: `https`, this host with no port,
    /// user or password, this path. Anything else is not for this decoder
    /// and is ignored by the caller. A query string is ignored (the walk is
    /// in the fragment); a percent-encoded fragment is not base64url, so it
    /// reads as damaged.
    static func isWalkLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host()?.lowercased() == host,
              url.port == nil, url.user() == nil, url.password() == nil
        else { return false }
        let urlPath = url.path(percentEncoded: true)
        return urlPath == path || urlPath + "/" == path
    }

    /// `nil` for a URL that is not a walk link; otherwise what it holds.
    static func decode(_ url: URL) -> Decoded? {
        guard isWalkLink(url) else { return nil }
        return decode(fragment: url.fragment(percentEncoded: true) ?? "")
    }

    /// The version comes first: a canonical decimal (ASCII digits, no
    /// leading zero) other than `1` before the first dot is a newer format,
    /// whatever follows. An empty, zero, zero-padded or non-digit version,
    /// and everything else that is not a well-formed version 1 walk, is
    /// damaged.
    static func decode(fragment: String) -> Decoded {
        guard let dot = fragment.firstIndex(of: ".") else { return .damaged }
        let versionText = fragment[..<dot]
        guard let leading = versionText.first, leading != "0", versionText.allSatisfy(\.isASCIIDigit) else {
            return .damaged
        }
        guard versionText == version else { return .needsUpdate }
        guard fragment.count <= maxFragmentLength, fragment.hasSuffix(terminator) else { return .damaged }
        let rest = fragment[fragment.index(after: dot)...]
        guard rest.count > terminator.count else { return .damaged }
        let payload = rest.dropLast(terminator.count)
        guard let deflated = data(base64URL: payload),
              case .inflated(let bytes) = inflate(deflated, limit: maxInflatedBytes)
        else { return .damaged }
        return walk(from: bytes).map(Decoded.walk) ?? .damaged
    }

    /// The varints of a version 1 payload as a walk, or `nil` when any rule
    /// is broken: an unreal date, a day outside 2020 to 2100, a span past
    /// 3,660 days, an unknown flag, `n` outside 1 to 5,000, more new blocks
    /// than blocks, metres past 10,000,000, a zero delta, an id past
    /// `UInt32`, or bytes left over.
    static func walk(from bytes: [UInt8]) -> SharedWalk? {
        var reader = VarintReader(bytes: bytes)
        guard let dayValue = reader.next(), let offset = reader.next(), let meters = reader.next(),
              let newCount = reader.next(), let flags = reader.next(), let count = reader.next()
        else { return nil }
        guard let firstDay = realDay(Int(dayValue)), isInDayRange(firstDay), offset <= UInt32(maxDayOffset),
              flags & ~estimateFlag == 0, (1 ... UInt32(maxBlocks)).contains(count),
              newCount <= count, meters <= UInt32(maxMeters)
        else { return nil }
        let lastDay = firstDay.advanced(by: Int(offset))
        guard isInDayRange(lastDay) else { return nil }
        var ids = Set<UInt32>(minimumCapacity: Int(count))
        var previous: UInt32 = 0
        for _ in 0 ..< count {
            guard let delta = reader.next(), delta >= 1 else { return nil }
            let (id, overflow) = previous.addingReportingOverflow(delta)
            guard !overflow else { return nil }
            ids.insert(id)
            previous = id
        }
        guard reader.isAtEnd else { return nil }
        return SharedWalk(
            firstDay: firstDay,
            lastDay: lastDay,
            blockIDs: ids,
            meters: Int(meters),
            newCount: Int(newCount),
            isEstimate: flags & estimateFlag != 0
        )
    }

    // MARK: Bounded inflate

    enum Inflated: Equatable {
        case inflated([UInt8])
        /// The output would pass `limit`; `produced` bytes were made before
        /// it stopped: `limit + 1`, the one byte that proves the overflow,
        /// never more (the buffer is that size).
        case overLimit(produced: Int)
        /// Not a complete raw DEFLATE stream.
        case failed
    }

    /// Raw DEFLATE into one buffer of `limit` bytes with
    /// `compression_stream`, stopping as soon as that buffer is full and
    /// more output is pending. `NSData.decompressed` has no output bound,
    /// so it is never used to decode.
    static func inflate(_ input: Data, limit: Int) -> Inflated {
        guard !input.isEmpty else { return .failed }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        let initStatus = compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard initStatus == COMPRESSION_STATUS_OK else { return .failed }
        defer { compression_stream_destroy(stream) }
        // One byte past the limit: filling it means the output is too big.
        let capacity = limit + 1
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { output.deallocate() }
        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Inflated in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return .failed }
            stream.pointee.src_ptr = source
            stream.pointee.src_size = raw.count
            stream.pointee.dst_ptr = output
            stream.pointee.dst_size = capacity
            while true {
                let sourceBefore = stream.pointee.src_size
                let roomBefore = stream.pointee.dst_size
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = capacity - stream.pointee.dst_size
                if produced > limit { return .overLimit(produced: produced) }
                switch status {
                case COMPRESSION_STATUS_END:
                    // Bytes after the end of the DEFLATE stream are not part
                    // of any link this app made.
                    guard stream.pointee.src_size == 0 else { return .failed }
                    return .inflated(Array(UnsafeBufferPointer(start: output, count: produced)))
                case COMPRESSION_STATUS_OK:
                    // A call that neither reads nor writes will never end:
                    // the stream is truncated.
                    if stream.pointee.src_size == sourceBefore, stream.pointee.dst_size == roomBefore {
                        return .failed
                    }
                default:
                    return .failed
                }
            }
        }
    }

    // MARK: Pieces

    /// Calendar days from `first` to `last` in New York, or `nil`.
    static func dayOffset(from first: WalkedDayKey, to last: WalkedDayKey) -> Int? {
        WalkedDayKey.calendar.dateComponents([.day], from: first.noon, to: last.noon).day
    }

    /// The key for `value` when it names a real Gregorian date.
    static func realDay(_ value: Int) -> WalkedDayKey? {
        let key = WalkedDayKey(value: value)
        guard (1 ... 9_999).contains(key.year), (1 ... 12).contains(key.month), (1 ... 31).contains(key.day) else {
            return nil
        }
        let parts = DateComponents(year: key.year, month: key.month, day: key.day, hour: 12)
        guard let date = WalkedDayKey.calendar.date(from: parts) else { return nil }
        let back = WalkedDayKey.calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == key.year, back.month == key.month, back.day == key.day else { return nil }
        return key
    }

    static func appendVarint(_ value: UInt32, to bytes: inout [UInt8]) {
        var rest = value
        while rest >= 0x80 {
            bytes.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
    }

    /// Reads unsigned LEB128 varints of at most 5 bytes that fit a `UInt32`.
    struct VarintReader {
        let bytes: [UInt8]
        private(set) var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        var isAtEnd: Bool { index == bytes.count }

        mutating func next() -> UInt32? {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 35, by: 7) {
                guard index < bytes.count else { return nil }
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << UInt64(shift)
                if byte & 0x80 == 0 {
                    return UInt32(exactly: value)
                }
            }
            // A sixth byte: longer than any `UInt32`.
            return nil
        }
    }

    static func base64URL(_ data: Data) -> String {
        String(data.base64EncodedString()
            .replacing("+", with: "-")
            .replacing("/", with: "_")
            .prefix { $0 != "=" })
    }

    /// Base64url without padding; `nil` for any other character, padding,
    /// or a length no base64 text can have.
    static func data(base64URL text: Substring) -> Data? {
        guard !text.isEmpty, text.count % 4 != 1,
              text.utf8.allSatisfy({ isBase64URLByte($0) })
        else { return nil }
        var standard = String(text).replacing("-", with: "+").replacing("_", with: "/")
        standard += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: standard)
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }
}

nonisolated private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
