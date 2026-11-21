import AppKit
import XCTest
@testable import Eden

/// Pin Tab, on a key of your own, and Pin Tab as Row, ⌘D as in Arc (#6):
/// each pins the tab on screen, and on a pinned tab unpins it. With the tabs
/// across the top, a row is drawn a square.
@MainActor
final class PinKeyTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "pin-key-\(getpid())", 1)
        super.setUp()
    }

    func testPinTabPinsASquareAndUnpins() throws {
        try withBrowser(rows: true) { browser, tab in
            press("tabs.pin", browser)
            XCTAssertNotNil(tab.pin)
            XCTAssertFalse(tab.listed, "a square")
            press("tabs.pin", browser)
            XCTAssertNil(tab.pin, "the same key unpins it")
        }
    }

    func testPinTabAsRowPinsARowAndUnpins() throws {
        try withBrowser(rows: true) { browser, tab in
            press("tabs.pinRow", browser)
            XCTAssertNotNil(tab.pin)
            XCTAssertTrue(tab.listed, "a row")
            press("tabs.pinRow", browser)
            XCTAssertNil(tab.pin, "the same key unpins it")
        }
    }

    func testAcrossTheTopTheRowsKeyPinsARowDrawnASquare() throws {
        try withBrowser(rows: false) { browser, tab in
            press("tabs.pinRow", browser)
            XCTAssertNotNil(tab.pin)
            XCTAssertTrue(tab.listed, "a row, for the column")
            XCTAssertEqual(browser.squarePins.map(\.id), [tab.id], "drawn a square across the top")
        }
    }

    /// ⌘D pins the page in front as a row, and again unpins it, a square
    /// as well; Duplicate Tab gave it up and has no key until you give it
    /// one.
    func testCommandDPinsAsRowThenUnpins() throws {
        XCTAssertEqual(Command.named("tabs.pinRow")?.defaultKey, KeyCombo("d"))
        XCTAssertNil(Command.named("tabs.duplicate")?.defaultKey)
        try withBrowser(rows: true) { browser, tab in
            browser.togglePinRow()
            XCTAssertNotNil(tab.pin)
            XCTAssertTrue(tab.listed, "a row")
            XCTAssertEqual(browser.listedPins.map(\.id), [tab.id])
            browser.togglePinRow()
            XCTAssertNil(tab.pin, "⌘D again unpins it")
            browser.pin(tab)
            XCTAssertFalse(tab.listed)
            browser.togglePinRow()
            XCTAssertNil(tab.pin, "a square too")
        }
    }

    /// As a key of your own runs it, through its command.
    private func press(_ id: String, _ browser: Browser) {
        guard let command = Command.named(id) else { return XCTFail("no \(id) command") }
        command.run(browser)
    }

    private func withBrowser(rows: Bool, _ body: (Browser, Tab) throws -> Void) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.sidebar, prefs.usesTabGroups)
        defer {
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
            (prefs.sidebar, prefs.usesTabGroups) = saved
        }
        // The rows are drawn only with the tabs down the side.
        prefs.sidebar = rows
        prefs.usesTabGroups = false
        browser.newTab()
        let tab = try XCTUnwrap(browser.tabs.last)
        tab.restore(url: URL(string: "about:blank#pin")!, title: "Pin")
        browser.select(tab)
        try body(browser, tab)
    }
}
