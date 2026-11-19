import XCTest
@testable import EdenCore

/// A pin is one thing on every device (SyncItems.applyPins): one a page,
/// however many devices pinned it, and never also one of a device's open
/// tabs while it is at its home (PinDef.atHome).
final class PinMergeTests: XCTestCase {
    private let space = UUID()

    private func pin(_ home: String, _ letter: String = "A", id: UUID = UUID(), listed: Bool? = nil) -> PinDef {
        PinDef(id: id, letter: letter, home: home, title: home, listed: listed)
    }

    /// Ids in a known order: of two pins of a page, the lower stays.
    private func low(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    /// The items two devices' pins come to, merged: what each wrote, side by
    /// side, the order the later one's.
    private func merged(_ first: [PinDef], _ second: [PinDef], shared: [PinDef] = []) -> [String: String] {
        var items = SyncItems.pins(bySpace: [space: first], shared: shared, base: [:])
        for (key, value) in SyncItems.pins(bySpace: [space: second], shared: [], base: [:]) where key.hasPrefix("pin:") || key.hasPrefix("title:") {
            items[key] = value
        }
        items[SyncItems.pinOrder(space.uuidString)] = SyncMerge.text((first + second).map(\.id.uuidString))
        return items
    }

    func testThePageTwoDevicesPinnedApartIsOnePin() {
        let mac = [pin("https://mail.google.com/", "M", id: low(1)), pin("https://github.com/", "G")]
        let phone = [pin("https://mail.google.com", "N", id: low(2)), pin("https://www.youtube.com/", "Y")]
        let back = SyncItems.applyPins(merged(mac, phone), spaces: [space], local: [:], localShared: [])
        let pins = back.bySpace[space] ?? []
        XCTAssertEqual(pins.map(\.home), ["https://mail.google.com/", "https://github.com/", "https://www.youtube.com/"],
                       "Gmail once, whatever its trailing slash")
        XCTAssertEqual(pins.first?.letter, "M", "the one with the lower id")
    }

    func testASpacesOwnPinOfAPageEverySpaceShowsGivesWay() {
        let everywhere = pin("https://www.youtube.com/")
        let own = [pin("https://www.youtube.com/"), pin("https://github.com/")]
        let items = merged(own, [], shared: [everywhere])
        let back = SyncItems.applyPins(items, spaces: [space], local: [:], localShared: [])
        XCTAssertEqual(back.shared.map(\.id), [everywhere.id])
        XCTAssertEqual(back.bySpace[space]?.map(\.home), ["https://github.com/"])
    }

    func testThePinGivenUpGoesAtTheNextPass() {
        let mac = [pin("https://mail.google.com/", id: low(1))]
        let phone = [pin("https://mail.google.com/", id: low(2))]
        let items = merged(mac, phone)
        let back = SyncItems.applyPins(items, spaces: [space], local: [:], localShared: [])
        // What this device writes next is the one pin; the other is found
        // missing against what was agreed, and deleted everywhere.
        let next = SyncItems.pins(bySpace: back.bySpace, shared: back.shared, base: items)
        XCTAssertNotNil(next[SyncItems.pinKey(space.uuidString, mac[0].id)])
        XCTAssertNil(next[SyncItems.pinKey(space.uuidString, phone[0].id)])
        let base = items.mapValues { SyncEntry(v: $0, t: 1, d: "phone") }
        let stamped = SyncMerge.stamp(current: next, base: base, device: "mac", now: 2)
        XCTAssertNil(stamped[SyncItems.pinKey(space.uuidString, phone[0].id)]?.v, "a tombstone, not a pin")
    }

    func testTwoDevicesKeepTheSamePinWhateverOrderEachSees() throws {
        // A sees an order holding Y; B a newer one from a third device holding
        // neither. Kept by order, A would keep Y and B X, and each give up the
        // other's: the page would lose both.
        let other = pin("https://github.com/")
        let x = pin("https://mail.google.com/", id: low(1)), y = pin("https://mail.google.com/", id: low(2))
        var items = SyncItems.pins(bySpace: [space: [other, x]], shared: [], base: [:])
        for (key, value) in SyncItems.pins(bySpace: [space: [y]], shared: [], base: [:]) where key.hasPrefix("pin:") {
            items[key] = value
        }
        var seenByA = items, seenByB = items
        seenByA[SyncItems.pinOrder(space.uuidString)] = SyncMerge.text([y.id.uuidString, other.id.uuidString])
        seenByB[SyncItems.pinOrder(space.uuidString)] = SyncMerge.text([other.id.uuidString])
        let onA = SyncItems.applyPins(seenByA, spaces: [space], local: [space: [y]], localShared: [])
        let onB = SyncItems.applyPins(seenByB, spaces: [space], local: [space: [other, x]], localShared: [])
        let keptByA = try XCTUnwrap(onA.bySpace[space]?.first { $0.home.contains("mail") })
        let keptByB = try XCTUnwrap(onB.bySpace[space]?.first { $0.home.contains("mail") })
        XCTAssertEqual(keptByA.id, x.id)
        XCTAssertEqual(keptByB.id, x.id, "both keep the same one")
    }

    func testAPinGoneForAnotherOfItsPageHandsOverItsTab() {
        // Merged on the Mac first: this device hears only the one kept.
        let x = pin("https://mail.google.com/", id: low(2)), y = pin("https://mail.google.com", id: low(1))
        let gone = pin("https://news.example/")
        let handed = SyncItems.handedOver(before: [space: [x, gone]], beforeShared: [],
                                          after: [space: [y]], afterShared: [])
        XCTAssertEqual(handed, [x.id: y.id], "the one of its page; one simply taken away hands over nothing")
    }

    func testAPagesOwnQueryKeepsItsPin() {
        let pins = [pin("https://example.com/?q=/"), pin("https://example.com/?q=")]
        let back = SyncItems.applyPins(merged(pins, []), spaces: [space], local: [:], localShared: [])
        XCTAssertEqual(back.bySpace[space]?.count, 2)
        XCTAssertTrue(PinDef.samePage(URL(string: "https://example.com/a/"), URL(string: "https://example.com/a")))
        XCTAssertFalse(PinDef.samePage(URL(string: "https://example.com/?q=/"), URL(string: "https://example.com/?q=")))
    }

    func testDifferentPagesOfOneSiteStayTwoPins() {
        let pins = [pin("https://github.com/"), pin("https://github.com/notifications")]
        let back = SyncItems.applyPins(merged(pins, []), spaces: [space], local: [:], localShared: [])
        XCTAssertEqual(back.bySpace[space]?.count, 2)
    }

    func testAPinAtItsHomeIsThePinAndGoneOnItIsThatPage() {
        let home = URL(string: "https://mail.google.com/")
        XCTAssertTrue(PinDef.atHome(home, showing: URL(string: "https://mail.google.com")))
        XCTAssertFalse(PinDef.atHome(home, showing: URL(string: "https://mail.google.com/mail/u/0/#inbox/1")))
        XCTAssertFalse(PinDef.atHome(nil, showing: home), "not a pin: an open tab like any")
    }
}
