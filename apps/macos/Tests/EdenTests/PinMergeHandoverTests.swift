import AppKit
import EdenCore
import XCTest
@testable import Eden

/// Two devices that pinned the same page apart come to one pin
/// (SyncItems.applyPins). On the device whose pin gave way, its tab
/// carries on as the other's, page and all, rather than closing for a
/// new one.
@MainActor
final class PinMergeHandoverTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "pin-merge-\(getpid())", 1)
        super.setUp()
    }

    func testTheTabOfAPinThatGaveWayIsTheOthersNow() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let tab = Eden.Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.prepare(tab)
        tab.restore(url: URL(string: "https://mail.google.com/")!, title: "Gmail")
        browser.insert(tab, at: browser.tabs.count)
        browser.pin(tab)
        let mine = try XCTUnwrap(Pins.defs(browser.spaceID).first)
        let count = browser.tabs.count

        // The other device's pin of the page, its id the lower, so it stays.
        let theirs = PinDef(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, letter: "G",
                            home: "https://mail.google.com", title: "Gmail")
        let merged = SyncItems.applyPins(
            SyncItems.pins(bySpace: [browser.spaceID: [theirs, mine]], shared: [], base: [:]),
            spaces: [browser.spaceID], local: [:], localShared: [])
        XCTAssertEqual(merged.bySpace[browser.spaceID]?.map(\.id), [theirs.id], "one pin of the page")
        Pins.adopt(merged.bySpace, in: [browser.spaceID], shared: merged.shared, profile: browser.profileID)
        browser.pinsChanged(in: browser.spaceID)

        XCTAssertEqual(browser.tabs.count, count, "no new tab, none closed")
        XCTAssertTrue(browser.tabs.contains { $0 === tab }, "the same tab")
        XCTAssertEqual(tab.pinID, theirs.id)
        XCTAssertEqual(tab.pin, "G")
    }
}
