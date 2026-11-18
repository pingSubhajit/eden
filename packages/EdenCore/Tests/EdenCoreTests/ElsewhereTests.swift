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
}
