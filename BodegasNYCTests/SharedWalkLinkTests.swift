//
//  SharedWalkLinkTests.swift
//  BodegasNYCTests
//
//  The walk link's format (#177 PR 2, eng E5, E7; AC 1 to 3): round trips,
//  the length and block caps, every damaged shape one by one, the version
//  rule, the bounded inflate, and that the host and path agree with the
//  entitlement and the fallback page. Payloads for the damaged cases are
//  built here from raw varints and raw DEFLATE, independent of `encode`.
//

import Foundation
import Testing

@testable import BodegasNYC

/// `count` ascending ids with pseudo-random gaps of 1 to 200 (no walk is
/// that scattered, so its link is long): deterministic for `seed`.
func scatteredIDs(count: Int, seed: UInt64) -> Set<UInt32> {
    var state = seed
    var id: UInt32 = 0
    var ids = Set<UInt32>()
    for _ in 0 ..< count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        id += UInt32((state >> 33) % 200) + 1
        ids.insert(id)
    }
    return ids
}

@Suite
struct SharedWalkLinkTests {
    /// The UI tests' valid link (`BodegasNYCUITests.SharedWalkUITests`
    /// holds the same text): `UITestFixtures.sharedWalkFixtureIDs`, Nov 3
    /// to 9, 2026, 3,380 m, 6 new, no estimate. Made outside the app (raw
    /// DEFLATE level 9 by Python's zlib), so it also proves the decoder
    /// reads another encoder's output.
    static let uiTestLink = "https://yukichikawada.github.io/BodegasNYC/walk/#1.e3_xCifbFik2BtNfrIHLGBMZ0YD-NkYFNuZpYk8T7"
        + "FhVmH5uYZ5jwcqozK_DlMJ3ioN5Y-3MJYzLlzHdrH_E5zjJ_IJgwV8rAA.w"

    static func walk(_ ids: Set<UInt32>, estimate: Bool = false) -> SharedWalk {
        SharedWalk(
            firstDay: WalkedDayKey(value: 20261103),
            lastDay: WalkedDayKey(value: 20261109),
            blockIDs: ids,
            meters: 3_380,
            newCount: min(6, ids.count),
            isEstimate: estimate
        )
    }

    /// Simulated walks: the first `count` Manhattan blocks of the bundled
    /// street file in file order, as a person walking block after block
    /// picks up near-consecutive ids.
    static func manhattanIDs(_ count: Int) throws -> Set<UInt32> {
        let grid = try StreetGridLoader.shared.grid()
        let ids = (0 ..< grid.segmentCount).lazy
            .filter { grid.borough(for: $0) == .manhattan }
            .prefix(count)
            .map { grid.physicalIDs[$0] }
        return Set(ids)
    }

    /// A fragment from raw varints (and extra raw bytes), deflated raw.
    static func fragment(_ varints: [UInt32], extra: [UInt8] = [], version: String = "1") -> String {
        var bytes: [UInt8] = []
        for value in varints { SharedWalkLink.appendVarint(value, to: &bytes) }
        bytes += extra
        return fragment(rawPayload: bytes, version: version)
    }

    static func fragment(rawPayload bytes: [UInt8], version: String = "1") -> String {
        let deflated = try? (Data(bytes) as NSData).compressed(using: .zlib) as Data
        return version + "." + SharedWalkLink.base64URL(deflated ?? Data()) + ".w"
    }

    /// The header of a valid one-block walk: Nov 3, 2026, one day, 100 m,
    /// 1 new, no flags, n = 1.
    static let header: [UInt32] = [20261103, 0, 100, 1, 0, 1]

    /// protects=AC 1: walks of 1, 25, 400 and 2,500 blocks, with and
    /// without the estimate flag, encode to a link of at most 2,000
    /// characters on the walk host and path that decodes to the same walk
    /// (ids, dates, metres, new count, flag); fails_when=any field changes
    /// in the round trip, the flag is lost, or a simulated walk passes the
    /// cap; no_claim=real walks' link lengths (the owner's AC 4 device
    /// check); the simulated walk is the bundle's Manhattan blocks in file
    /// order.
    @Test(arguments: [1, 25, 400, 2_500])
    func roundTrips(_ count: Int) throws {
        let ids = try Self.manhattanIDs(count)
        #expect(ids.count == count)
        for estimate in [false, true] {
            let walk = Self.walk(ids, estimate: estimate)
            guard case .url(let url) = SharedWalkLink.encode(walk) else {
                Issue.record("\(count) blocks did not encode")
                continue
            }
            #expect(url.absoluteString.count <= SharedWalkLink.maxURLLength)
            #expect(url.absoluteString.hasPrefix("https://yukichikawada.github.io/BodegasNYC/walk/#1."))
            #expect(url.absoluteString.hasSuffix(".w"))
            #expect(SharedWalkLink.decode(url) == .walk(walk))
        }
    }

    /// protects=eng E5's caps on encoding: 5,001 blocks is `.tooLong` even
    /// when its link would be short (consecutive ids), and a 4,000-block
    /// set whose link passes 2,000 characters is `.tooLong`; 5,000
    /// consecutive ids still encode; fails_when=either over-cap set makes a
    /// URL, or the 5,000 cap is off by one; no_claim=the form's line
    /// (ShareWalkFormTests).
    @Test func capsAreTooLong() {
        #expect(SharedWalkLink.encode(Self.walk(Set(1 ... 5_001))) == .tooLong)
        guard case .url = SharedWalkLink.encode(Self.walk(Set(1 ... 5_000))) else {
            Issue.record("5,000 consecutive ids did not encode")
            return
        }
        #expect(SharedWalkLink.encode(Self.walk(scatteredIDs(count: 4_000, seed: 1))) == .tooLong)
        #expect(SharedWalkLink.encode(Self.walk([])) == .tooLong)
    }

    /// protects=AC 2 and eng E5, one damaged shape per argument: each
    /// decodes to `.damaged` and none crashes; fails_when=any of them
    /// decodes to a walk or to `.needsUpdate`; no_claim=links this list
    /// does not name (the decoder's rules are the list).
    @Test(arguments: SharedWalkLinkTests.damagedCases)
    func damaged(_ name: String, _ fragment: String) {
        #expect(SharedWalkLink.decode(fragment: fragment) == .damaged, "\(name)")
    }

    static let truncatedDeflate: String = {
        let deflated = (try? (Data(repeating: 7, count: 200) as NSData).compressed(using: .zlib) as Data) ?? Data()
        return "1." + SharedWalkLink.base64URL(deflated.dropLast(3)) + ".w"
    }()

    static let oneBlock: [UInt32] = header + [7]
    static let manyOnes: [UInt32] = Array(repeating: 1, count: 5_001)

    static let damagedCases: [(String, String)] = [
        ("missing dot", "1abc"),
        ("no end letter", String(fragment(oneBlock).dropLast(2))),
        ("wrong end letter", String(fragment(oneBlock).dropLast(1)) + "x"),
        ("empty payload", "1..w"),
        ("only the end letter", "1.w"),
        ("bad base64", "1.ab$d.w"),
        ("base64 padding", "1.YQ==.w"),
        ("failed inflate", "1." + SharedWalkLink.base64URL(Data([0xFF, 0xFF, 0xFF, 0xFF])) + ".w"),
        ("truncated deflate", truncatedDeflate),
        ("trailing bytes", fragment(oneBlock, extra: [1])),
        ("missing ids", SharedWalkLinkTests.fragment([20261103, 0, 100, 1, 0, 3, 7])),
        ("zero delta", SharedWalkLinkTests.fragment([20261103, 0, 100, 2, 0, 2, 7, 0])),
        ("id past UInt32", SharedWalkLinkTests.fragment([20261103, 0, 100, 2, 0, 2, UInt32.max, 1])),
        ("varint past UInt32", SharedWalkLinkTests.fragment(rawPayload: [0xFF, 0xFF, 0xFF, 0xFF, 0x7F])),
        ("varint longer than 5 bytes", SharedWalkLinkTests.fragment(rawPayload: [0x80, 0x80, 0x80, 0x80, 0x80, 0x01])),
        ("not a real date", SharedWalkLinkTests.fragment([20261131, 0, 100, 1, 0, 1, 7])),
        ("month 13", SharedWalkLinkTests.fragment([20261303, 0, 100, 1, 0, 1, 7])),
        ("day count over 3,660", SharedWalkLinkTests.fragment([20261103, 3_660, 100, 1, 0, 1, 7])),
        ("n of 0", SharedWalkLinkTests.fragment([20261103, 0, 100, 0, 0, 0])),
        ("n over 5,000", SharedWalkLinkTests.fragment([20261103, 0, 100, 1, 0, 5_001] + manyOnes)),
        ("unknown flag bit", SharedWalkLinkTests.fragment([20261103, 0, 100, 1, 2, 1, 7])),
        ("fragment over 4,096", "1." + String(repeating: "A", count: 4_100) + ".w"),
        ("more new blocks than blocks", SharedWalkLinkTests.fragment([20261103, 0, 100, 2, 0, 1, 7])),
        ("metres over 10,000,000", SharedWalkLinkTests.fragment([20261103, 0, 10_000_001, 1, 0, 1, 7])),
        ("first day before 2020", SharedWalkLinkTests.fragment([20191231, 0, 100, 1, 0, 1, 7])),
        ("last day after 2100", SharedWalkLinkTests.fragment([21001231, 1, 100, 1, 0, 1, 7])),
        ("version 0", SharedWalkLinkTests.fragment(oneBlock, version: "0")),
        ("version 01", SharedWalkLinkTests.fragment(oneBlock, version: "01")),
        ("empty version", SharedWalkLinkTests.fragment(oneBlock, version: "")),
        ("non-digit version", SharedWalkLinkTests.fragment(oneBlock, version: "v1")),
        ("percent-encoded fragment", "1.%41%41.w")
    ]

    /// protects=the decoder's new bounds from the valid side: exactly
    /// 10,000,000 m, as many new blocks as blocks, Jan 1, 2020 and a span
    /// ending Dec 31, 2100 all decode; fails_when=a bound is off by one;
    /// no_claim=none beyond protects.
    @Test func boundsDecodeAtTheirEdges() {
        let cases: [[UInt32]] = [
            [20261103, 0, 10_000_000, 1, 0, 1, 7],
            [20200101, 0, 100, 1, 0, 1, 7],
            [21001230, 1, 100, 1, 0, 1, 7]
        ]
        for varints in cases {
            guard case .walk = SharedWalkLink.decode(fragment: Self.fragment(varints)) else {
                Issue.record("\(varints) did not decode")
                continue
            }
        }
    }

    /// protects=encode never makes a link the decoder refuses: a block id
    /// of 0 (unwritable, since every delta is at least 1; the bundled file
    /// has none), more new blocks than blocks, metres past 10,000,000 and a
    /// day outside 2020 to 2100 are all `.tooLong`, never a URL;
    /// fails_when=any of them encodes; no_claim=the form's reason line
    /// for these (they cannot arise from real history).
    @Test func encodeRefusesWhatDecodeRejects() throws {
        #expect(SharedWalkLink.encode(Self.walk([0, 5])) == .tooLong)
        let grid = try StreetGridLoader.shared.grid()
        #expect(grid.index(ofPhysicalID: 0) == nil)
        func walk(first: Int, last: Int, meters: Int = 100, new: Int = 1) -> SharedWalk {
            SharedWalk(
                firstDay: WalkedDayKey(value: first), lastDay: WalkedDayKey(value: last),
                blockIDs: [7], meters: meters, newCount: new, isEstimate: false
            )
        }
        #expect(SharedWalkLink.encode(walk(first: 20261103, last: 20261103, new: 2)) == .tooLong)
        #expect(SharedWalkLink.encode(walk(first: 20261103, last: 20261103, meters: 10_000_001)) == .tooLong)
        #expect(SharedWalkLink.encode(walk(first: 20191231, last: 20200101)) == .tooLong)
        #expect(SharedWalkLink.encode(walk(first: 21001231, last: 21010101)) == .tooLong)
    }

    /// protects=which URLs count as walk links: a port, a user or a
    /// password make it not a walk link (ignored, `nil`); a query string is
    /// ignored and the walk still decodes; a percent-encoded fragment is
    /// damaged; fails_when=a URL with a port or credentials is read, a
    /// query stops a walk decoding, or an encoded fragment decodes;
    /// no_claim=which URLs iOS routes to the app.
    @Test func portsCredentialsQueriesAndEncodedFragments() throws {
        let walk = Self.walk([7, 9, 30])
        guard case .url(let url) = SharedWalkLink.encode(walk), let fragment = url.fragment() else {
            Issue.record("did not encode")
            return
        }
        let host = "yukichikawada.github.io"
        for text in [
            "https://\(host):443/BodegasNYC/walk/#\(fragment)",
            "https://\(host):8443/BodegasNYC/walk/#\(fragment)",
            "https://someone@\(host)/BodegasNYC/walk/#\(fragment)",
            "https://someone:secret@\(host)/BodegasNYC/walk/#\(fragment)",
            "ftp://\(host)/BodegasNYC/walk/#\(fragment)"
        ] {
            #expect(SharedWalkLink.decode(try #require(URL(string: text))) == nil, "\(text)")
        }
        let queried = try #require(URL(string: "https://\(host)/BodegasNYC/walk/?utm_source=x#\(fragment)"))
        #expect(SharedWalkLink.decode(queried) == .walk(walk))
        let percent = try #require(URL(string: "https://\(host)/BodegasNYC/walk/#1.%41\(fragment.dropFirst(2))"))
        #expect(SharedWalkLink.decode(percent) == .damaged)
    }

    /// protects=the same rules hold at their edge from the valid side: 3,660
    /// days (offset 3,659), 5,000 ids, the estimate bit and Feb 29 of a leap
    /// year decode; fails_when=a bound is off by one and rejects a valid
    /// link; no_claim=none beyond protects.
    @Test func edgesDecode() {
        let longest = SharedWalkLink.decode(fragment: SharedWalkLinkTests.fragment([20240229, 3_659, 100, 1, 1, 1, 7]))
        guard case .walk(let walk) = longest else {
            Issue.record("the longest span did not decode: \(longest)")
            return
        }
        #expect(walk.firstDay == WalkedDayKey(value: 20240229))
        #expect(SharedWalkLink.dayOffset(from: walk.firstDay, to: walk.lastDay) == 3_659)
        #expect(walk.isEstimate && walk.blockIDs == [7])
        let most = SharedWalkLinkTests.fragment([20261103, 0, 100, 1, 0, 5_000] + Array(repeating: 1, count: 5_000))
        #expect(SharedWalkLink.decode(fragment: most) == .walk(Self.walkOfConsecutive(5_000)))
    }

    private static func walkOfConsecutive(_ count: UInt32) -> SharedWalk {
        SharedWalk(
            firstDay: WalkedDayKey(value: 20261103),
            lastDay: WalkedDayKey(value: 20261103),
            blockIDs: Set(1 ... count),
            meters: 100,
            newCount: 1,
            isEstimate: false
        )
    }

    /// protects=AC 7's version rule: a version other than `1` is
    /// `.needsUpdate`, checked first, whatever follows it (garbage, no end
    /// letter, past 4,096 characters); fails_when=a version-2 link reads as
    /// damaged or decodes; no_claim=what a later version will hold.
    @Test func newerVersionsNeedAnUpdate() {
        #expect(SharedWalkLink.decode(fragment: "2.abc.w") == .needsUpdate)
        #expect(SharedWalkLink.decode(fragment: "2.!!!garbage") == .needsUpdate)
        #expect(SharedWalkLink.decode(fragment: "10." + String(repeating: "A", count: 5_000)) == .needsUpdate)
        #expect(SharedWalkLink.decode(fragment: SharedWalkLinkTests.fragment(SharedWalkLinkTests.header + [7], version: "2")) == .needsUpdate)
        let url = URL(string: "https://yukichikawada.github.io/BodegasNYC/walk/#2.zz.w")!
        #expect(SharedWalkLink.decode(url) == .needsUpdate)
    }

    /// protects=AC 2's memory bound on the bounded function itself: a
    /// payload that inflates to 1 MB stops after 64 KB plus the one byte
    /// that proves the overflow, and its link is damaged; a payload of
    /// exactly 64 KB inflates whole; fails_when=the inflate returns more
    /// than the limit, reads the whole megabyte, or decodes; no_claim=peak
    /// process memory (the buffer is the bound, not a measured high-water).
    @Test func inflateStopsAtTheBound() throws {
        let limit = SharedWalkLink.maxInflatedBytes
        let bomb = try #require((Data(repeating: 0, count: 1_048_576) as NSData).compressed(using: .zlib) as Data)
        #expect(SharedWalkLink.inflate(bomb, limit: limit) == .overLimit(produced: limit + 1))
        #expect(SharedWalkLink.decode(fragment: "1." + SharedWalkLink.base64URL(bomb) + ".w") == .damaged)

        let exact = try #require((Data(repeating: 1, count: limit) as NSData).compressed(using: .zlib) as Data)
        #expect(SharedWalkLink.inflate(exact, limit: limit) == .inflated(Array(repeating: 1, count: limit)))
    }

    /// protects=the caller's "not a walk link" rule: another host, another
    /// path, another scheme or the site's privacy page decode to `nil`
    /// (ignored), while the walk path with or without its trailing slash is
    /// read; fails_when=a foreign URL becomes a pending walk, or the walk
    /// path is missed; no_claim=which URLs iOS hands the app (the
    /// association file's `/BodegasNYC/walk/*`).
    @Test func otherURLsAreNotWalkLinks() {
        for text in [
            "https://example.com/BodegasNYC/walk/#1.abc.w",
            "http://yukichikawada.github.io/BodegasNYC/walk/#1.abc.w",
            "https://yukichikawada.github.io/BodegasNYC/PRIVACY#1.abc.w",
            "https://yukichikawada.github.io/BodegasNYC/walk/more/#1.abc.w",
            "bodegas://walk/#1.abc.w"
        ] {
            #expect(SharedWalkLink.decode(URL(string: text)!) == nil, "\(text)")
        }
        #expect(SharedWalkLink.decode(URL(string: "https://yukichikawada.github.io/BodegasNYC/walk#1.abc.w")!) == .damaged)
        #expect(SharedWalkLink.decode(URL(string: "https://yukichikawada.github.io/BodegasNYC/walk/")!) == .damaged)
    }

    /// protects=the UI tests' fixture link decodes to the walk their
    /// assertions expect, and every one of its 53 blocks is in the bundled
    /// street file (so the sheet draws them all); fails_when=the fixture
    /// ids drift from the bundle or the link from the ids; no_claim=the
    /// sheet's rendering (UI tests).
    @Test func uiTestLinkIsTheFixtureWalk() throws {
        let url = try #require(URL(string: Self.uiTestLink))
        let expected = SharedWalk(
            firstDay: WalkedDayKey(value: 20261103),
            lastDay: WalkedDayKey(value: 20261109),
            blockIDs: UITestFixtures.sharedWalkFixtureIDs,
            meters: 3_380,
            newCount: 6,
            isEstimate: false
        )
        #expect(SharedWalkLink.decode(url) == .walk(expected))
        let grid = try StreetGridLoader.shared.grid()
        #expect(UITestFixtures.sharedWalkFixtureIDs.count == 53)
        #expect(UITestFixtures.sharedWalkFixtureIDs.allSatisfy { grid.index(ofPhysicalID: $0) != nil })
    }

    /// protects=eng's hand-synced-list rule: the Swift constant's host is
    /// the entitlement's only `applinks:` domain, and its path is where the
    /// fallback page sits under the project site (`docs/` is served at
    /// `/BodegasNYC/`); fails_when=the entitlement, the page's location or
    /// the constant changes alone; no_claim=the association file in the
    /// other repository (checked live, AC 10).
    @Test func hostAndPathAgreeWithTheEntitlementAndThePage() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let entitlements = try Data(contentsOf: root.appending(path: "BodegasNYC/BodegasNYC.entitlements"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: entitlements, format: nil) as? [String: Any]
        )
        let domains = try #require(plist["com.apple.developer.associated-domains"] as? [String])
        #expect(domains == ["applinks:" + SharedWalkLink.host])

        let sitePrefix = "/BodegasNYC/"
        #expect(SharedWalkLink.path.hasPrefix(sitePrefix))
        let pagePath = "docs/" + SharedWalkLink.path.dropFirst(sitePrefix.count) + "index.html"
        #expect(pagePath == "docs/walk/index.html")
        let page = try String(contentsOf: root.appending(path: pagePath), encoding: .utf8)
        #expect(page.contains("https://" + SharedWalkLink.host + SharedWalkLink.path))
    }

    /// protects=a link holds only what the walk is: decoding it back yields
    /// the six fields and nothing else can be inside (the payload is
    /// exactly the varints, so any extra byte is damaged); the URL carries
    /// no query and nothing outside the fragment but the fixed host and
    /// path; fails_when=a query or extra path appears; no_claim=what the
    /// message app adds around the link.
    @Test func aLinkIsOnlyTheFragment() throws {
        guard case .url(let url) = SharedWalkLink.encode(Self.walk([7, 9, 30])) else {
            Issue.record("did not encode")
            return
        }
        #expect(url.query() == nil)
        #expect(url.path() == SharedWalkLink.path)
        let fragment = try #require(url.fragment())
        #expect(url.absoluteString == SharedWalkLink.base + "#" + fragment)
    }
}
