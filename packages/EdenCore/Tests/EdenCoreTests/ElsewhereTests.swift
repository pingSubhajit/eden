import XCTest
@testable import EdenCore

/// Your other devices' pages as this one offers them (Elsewhere): one to
/// carry on with, the ones just closed, those answering to what is typed,
/// and each device's grouped by space — and the item they travel in, read
/// the same by an Eden from before.
final class ElsewhereTests: XCTestCase {
    private let now: Double = 1_000_000
    private let work = UUID()

    private func page(_ path: String, space: UUID? = nil) -> DeviceTabs.Page {
        DeviceTabs.Page(url: "https://\(path).example/", title: path.capitalized, space: space)
    }

    private func device(_ id: String, seen: Double? = nil, front: Int? = nil, tabs: [DeviceTabs.Page],
                        closed: [DeviceTabs.Closed]? = nil) -> DeviceTabs {
        DeviceTabs(device: id, name: id.capitalized, kind: .mac, tabs: tabs, at: now - 60, front: front, seen: seen, closed: closed)
    }

    private func identity(_ path: String) -> String {
        History.identity(for: URL(string: "https://\(path).example/")!)
    }

    func testTheItemReadsTheSameByAnEdenFromBefore() throws {
        let old = #"{"device":"mac","name":"Mac","kind":"mac","tabs":[{"url":"https://a.example/","title":"A"}],"at":5}"#
        let read = try XCTUnwrap(SyncMerge.value(DeviceTabs.self, old))
        XCTAssertNil(read.front)
        XCTAssertNil(read.tabs.first?.space)
        let full = device("mac", seen: now, front: 0, tabs: [DeviceTabs.Page(url: "https://a.example/", title: "A", space: work,
                                                                              scroll: 0.4, reading: true)])
        XCTAssertEqual(SyncMerge.value(DeviceTabs.self, try XCTUnwrap(SyncMerge.text(full))), full)
    }

    func testAReadingPositionGoesInTwentiethsTheTopIncluded() {
        XCTAssertEqual(DeviceTabs.Page.scroll(0.43), 0.45)
        XCTAssertEqual(DeviceTabs.Page.scroll(0.01), 0, "the top said, not left unknown")
        XCTAssertEqual(DeviceTabs.Page.scroll(3), 1)
    }

    func testOnlyAChangeOfWhatItSaysIsANewItem() {
        let one = device("mac", tabs: [page("a")])
        var later = one
        later.at += 500
        XCTAssertTrue(one.says(later))
        later.tabs[0].scroll = 0.5
        XCTAssertFalse(one.says(later))
    }

    func testTheDevicePutDownLatelyOffersItsPageInFront() {
        let mac = device("mac", seen: now - 120, front: 1, tabs: [page("a"), page("b")])
        let pad = device("pad", seen: now - 600, front: 0, tabs: [page("c")])
        XCTAssertEqual(Elsewhere.continuing(from: [pad, mac], now: now, frontHere: nil)?.page, page("b"))
        XCTAssertNil(Elsewhere.continuing(from: [mac], now: now, frontHere: identity("b")), "already in front here")
        let long = device("mac", seen: now - DeviceTabs.continueLife - 1, front: 0, tabs: [page("a")])
        XCTAssertNil(Elsewhere.continuing(from: [long], now: now, frontHere: nil), "put down too long ago")
        XCTAssertNil(Elsewhere.continuing(from: [device("old", tabs: [page("a")])], now: now, frontHere: nil),
                     "an Eden from before says neither")
    }

    func testPagesJustClosedElsewhereNewestFirstNoneOpenHere() {
        let closed = [DeviceTabs.Closed(url: "https://a.example/", title: "A", at: now - 30),
                      DeviceTabs.Closed(url: "https://b.example/", title: "B", at: now - 10),
                      DeviceTabs.Closed(url: "https://c.example/", title: "C", at: now - DeviceTabs.closedLife - 1)]
        let mac = device("mac", tabs: [page("z")], closed: closed)
        let offered = Elsewhere.closed(on: [mac], now: now, openHere: [identity("a")])
        XCTAssertEqual(offered.map(\.page.url), ["https://b.example/"])
        XCTAssertEqual(DeviceTabs.recent(closed, now: now).map(\.title), ["A", "B"], "the old one gone")
    }

    func testWhatIsTypedFindsOtherDevicesPagesNotOpenHere() {
        let mac = device("mac", tabs: [page("github"), page("gitlab"), page("news")])
        let found = Elsewhere.matching("git", in: [mac], openHere: [identity("gitlab")])
        XCTAssertEqual(found.map(\.page.title), ["Github"])
        XCTAssertEqual(found.first?.deviceName, "Mac")
        XCTAssertTrue(Elsewhere.matching("  ", in: [mac], openHere: []).isEmpty)
        let row = Suggestion(found[0])
        XCTAssertEqual(row.kind, .elsewhere)
        XCTAssertEqual(row.elsewhere, found[0])
    }

    func testADevicesPagesGroupByTheSpacesThisDeviceHas() {
        let other = UUID()
        let pages = [page("a", space: work), page("b"), page("c", space: Space.firstID), page("d", space: other)]
        let groups = Elsewhere.bySpace(pages, order: [Space.firstID, work])
        XCTAssertEqual(groups.map(\.space), [Space.firstID, work, nil])
        XCTAssertEqual(groups.last?.pages.map(\.title), ["B", "D"], "no space said, or one unknown here, last")
    }

    func testAHandedOffPageCarriesHowItWasLeftInAFewShortStrings() throws {
        let url = URL(string: "https://a.example/story")!
        let info = Continuity.info(scroll: 0.43, reading: true, space: work, device: "MacBook", kind: .mac)
        let offer = Continuity.offer(url, title: "Story", info: info)
        XCTAssertEqual(offer.page, DeviceTabs.Page(url: url.absoluteString, title: "Story", space: work, scroll: 0.45, reading: true))
        XCTAssertEqual(offer.deviceName, "MacBook")
        XCTAssertEqual(offer.kind, .mac)
        // Whatever the page or the device's name, the payload stays small.
        let long = Continuity.info(scroll: 1, reading: false, space: work, device: String(repeating: "名", count: 500), kind: .iphone)
        XCTAssertLessThan(long.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }, 300)
        XCTAssertEqual(Continuity.offer(url, title: nil, info: long).deviceName, String(repeating: "名", count: 42),
                       "128 bytes, whole characters")
        // One character of a letter and ten thousand marks: none of it goes.
        let marked = "A" + String(repeating: "\u{301}", count: 10_000)
        XCTAssertEqual(Continuity.info(scroll: nil, reading: false, space: nil, device: marked, kind: .mac)["eden.device"], "")
        XCTAssertEqual(Continuity.offer(url, title: nil, info: ["eden.device": marked]).deviceName, "another device")
        // From an Eden from before, or Safari: nothing but the address.
        let bare = Continuity.offer(url, title: nil, info: nil)
        XCTAssertEqual(bare.page.url, url.absoluteString)
        XCTAssertEqual(bare.deviceName, "another device")
    }

    // MARK: - closing a page on another device

    func testOnlyThisDevicesStandingAsksToCloseAreRead() {
        var live = SyncItems.ask(close: "https://a.example/", on: "phone", now: now, id: "1")
        live.merge(SyncItems.ask(close: "https://b.example/", on: "mac", now: now, id: "2")) { a, _ in a }
        live.merge(SyncItems.ask(close: "https://c.example/", on: "phone", now: now - CloseAsk.life - 1, id: "3")) { a, _ in a }
        live["tabs:phone"] = "{}"
        let asks = SyncItems.closeAsks(live, on: "phone", now: now)
        XCTAssertEqual(asks.keys.sorted(), [SyncItems.closeKey("phone", id: "1")], "the mac's, and a stale one, aren't")
        XCTAssertEqual(asks.values.first?.url, "https://a.example/")
    }

    func testAPageAskedClosedIsHiddenWhileTheAskStands() {
        let phone = device("phone", front: 1, tabs: [page("a"), page("b"), page("c")])
        let asked = [Elsewhere.Asked(device: "phone", page: identity("a"), at: now - 30, key: "close:phone:1")]
        let (shown, waiting) = Elsewhere.asAsked([phone], asked: asked, standing: ["close:phone:1"], now: now)
        XCTAssertEqual(shown.first?.tabs.map(\.url), [page("b").url, page("c").url])
        XCTAssertEqual(shown.first?.frontPage, page("b"), "the page in front stays in front")
        XCTAssertEqual(waiting, asked)

        // The phone saying its tabs again isn't an answer: a newer list may
        // be from before the ask reached it.
        var newer = phone
        newer.at = now
        XCTAssertEqual(Elsewhere.asAsked([newer], asked: asked, standing: ["close:phone:1"], now: now).waiting, asked)

        // The ask gone: answered, and what the phone says stands.
        let after = Elsewhere.asAsked([newer], asked: asked, standing: [], now: now)
        XCTAssertEqual(after.devices, [newer])
        XCTAssertEqual(after.waiting, [])
    }

    func testAnAskStandsUntilItsDeviceHasDoneIt() {
        var agreed = SyncItems.ask(close: page("a").url, on: "phone", now: now, id: "1")
        agreed.merge(SyncItems.ask(open: page("b"), on: "phone", now: now, id: "2")) { a, _ in a }
        agreed.merge(SyncItems.ask(open: page("c"), on: "phone", now: now - CloseAsk.life - 1, id: "3")) { a, _ in a }
        agreed.merge(SyncItems.ask(close: page("d").url, on: "mac", now: now, id: "4")) { a, _ in a }
        agreed["tabs:phone"] = "{}"
        let standing = SyncItems.standingAsks(agreed, of: "phone", answered: [SyncItems.openKey("phone", id: "2")], now: now)
        XCTAssertEqual(standing.keys.sorted(), [SyncItems.closeKey("phone", id: "1")],
                       "not one done, a stale one, or one for another device")
        XCTAssertEqual(standing.values.first, agreed[SyncItems.closeKey("phone", id: "1")], "said back as it was")
    }

    func testOnlyThisDevicesStandingAsksToOpenAreRead() {
        var live = SyncItems.ask(open: page("a", space: work), on: "phone", now: now, id: "1")
        live.merge(SyncItems.ask(open: page("b"), on: "mac", now: now, id: "2")) { a, _ in a }
        live.merge(SyncItems.ask(close: page("c").url, on: "phone", now: now, id: "3")) { a, _ in a }
        let asks = SyncItems.openAsks(live, on: "phone", now: now)
        XCTAssertEqual(asks.keys.sorted(), [SyncItems.openKey("phone", id: "1")], "not the mac's, nor an ask to close")
        XCTAssertEqual(asks.values.first?.page, page("a", space: work), "the page whole, its space with it")
        XCTAssertTrue(SyncItems.asks(SyncItems.openKey("phone", id: "1"), of: "phone"))
        XCTAssertTrue(SyncItems.asks(SyncItems.closeKey("phone", id: "3"), of: "phone"))
        XCTAssertFalse(SyncItems.asks(SyncItems.openKey("mac", id: "2"), of: "phone"))
    }

    func testAPageAskedOpenedShowsInItsDevicesListWhileTheAskStands() {
        let phone = device("phone", tabs: [page("a")])
        let asked = [Elsewhere.Asked(device: "phone", page: identity("b"), at: now - 30, key: "open:phone:1", opening: page("b")),
                     Elsewhere.Asked(device: "phone", page: identity("a"), at: now - 30, key: "open:phone:2", opening: page("a"))]
        let standing: Set<String> = ["open:phone:1", "open:phone:2"]
        let (shown, waiting) = Elsewhere.asAsked([phone], asked: asked, standing: standing, now: now)
        XCTAssertEqual(shown.first?.tabs.map(\.url), [page("a").url, page("b").url], "once each, at the end")
        XCTAssertEqual(waiting, asked)
        XCTAssertEqual(Elsewhere.asAsked([phone], asked: asked, standing: [], now: now).devices, [phone])
    }

    @MainActor
    func testAnAskIsDoneOnlyOnceWhatItWroteHasLanded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("answer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = folder.appendingPathComponent("tabs.json")
        XCTAssertTrue(SyncItems.answer({}, rewrite: { Disk.write(written) { Data("[]".utf8) } }))
        XCTAssertEqual(try Data(contentsOf: written), Data("[]".utf8), "on disk by the time it says so")
        // A file where its folder should be: the write can't land.
        let blocked = written.appendingPathComponent("inside.json")
        let rewrite = { Disk.write(blocked) { Data("[]".utf8) } }
        XCTAssertFalse(SyncItems.answer({}, rewrite: rewrite), "not done: it stands")
        // Tried again with nothing left to change: still written again, and
        // still not done while the write can't land.
        XCTAssertFalse(SyncItems.answer({}, rewrite: rewrite), "a retry that changes nothing isn't done either")
        try FileManager.default.removeItem(at: written)
        try FileManager.default.createDirectory(at: written, withIntermediateDirectories: true)
        XCTAssertTrue(SyncItems.answer({}, rewrite: rewrite), "done once it lands")
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
    }

    func testAnAskWhoseTabsDidntLandWaitsLongerEachTime() {
        var retries = AskRetries()
        XCTAssertTrue(retries.ready("close:mac:1", now: now))
        retries.failed(["close:mac:1"], now: now)
        XCTAssertFalse(retries.ready("close:mac:1", now: now + 1), "not at the very next pass")
        XCTAssertTrue(retries.ready("close:mac:1", now: now + AskRetries.first))
        retries.failed(["close:mac:1"], now: now + AskRetries.first)
        XCTAssertFalse(retries.ready("close:mac:1", now: now + AskRetries.first * 2), "twice as long the second time")
        XCTAssertTrue(retries.ready("close:mac:1", now: now + AskRetries.first * 3))
        XCTAssertTrue(retries.ready("open:mac:2", now: now), "each ask its own")
        for _ in 0..<20 { retries.failed(["close:mac:1"], now: now) }
        XCTAssertTrue(retries.ready("close:mac:1", now: now + AskRetries.longest), "never longer than the longest")
        retries.forget(["close:mac:1"])
        XCTAssertTrue(retries.ready("close:mac:1", now: now))
        retries.failed(["close:mac:1", "open:mac:2"], now: now)
        retries.keep(["open:mac:2"])
        XCTAssertTrue(retries.ready("close:mac:1", now: now), "gone from the items: forgotten")
        XCTAssertFalse(retries.ready("open:mac:2", now: now))
    }
}
