import AppKit
import XCTest
@testable import Eden

/// The empty page of a pair finds open tabs by what is typed: its list of
/// six goes once typing starts, and the field offered only places, so a tab
/// past those six could only be loaded again as a new copy. The open tabs
/// that answer come first, and taking one brings it into the pair.
@MainActor
final class EmptyHalfOpenTabsTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "empty-half-\(getpid())", 1)
        super.setUp()
    }

    func testTypingFindsATabPastTheFirstSix() throws {
        try withBrowser { browser, tabs in
            // "Notes" is the tab looked at longest ago, past the list's six.
            browser.select(tabs[0])
            browser.startSplit()
            let blank = try XCTUnwrap(browser.active)
            XCTAssertTrue(blank.isBlank)
            // Been there before, too: history would offer it as a place.
            browser.history.record(try XCTUnwrap(tabs[8].address), title: "Notes")
            browser.typed = "notes"
            let first = try XCTUnwrap(browser.offers.first)
            XCTAssertEqual(first.tab, tabs[8].id, "the open tab first")
            XCTAssertEqual(browser.offers.filter { $0.url == first.url }.count, 1, "not offered again as a place to load")
            browser.take(first)
            let pair = try XCTUnwrap(browser.activeSplit, "still a pair")
            XCTAssertEqual(pair.tabs, [tabs[0].id, tabs[8].id], "brought in beside the page")
            XCTAssertFalse(browser.tabs.contains { $0.id == blank.id }, "the empty page goes")
            XCTAssertEqual(browser.tabs.count, tabs.count, "nothing loaded again")
        }
    }

    func testReturnOnTheRowBringsItInToo() throws {
        try withBrowser { browser, tabs in
            browser.select(tabs[0])
            browser.startSplit()
            browser.typed = "notes"
            browser.walk(1)
            browser.submit()
            XCTAssertEqual(browser.activeSplit?.tabs, [tabs[0].id, tabs[8].id])
        }
    }

    func testThePairsOwnPageIsNotOffered() throws {
        try withBrowser { browser, tabs in
            browser.select(tabs[0])
            browser.startSplit()
            browser.typed = "page 1"
            XCTAssertFalse(browser.offers.contains { $0.tab == tabs[0].id }, "already beside it")
        }
    }

    /// On a tab of its own the field is ⌘T's, which finds open tabs too
    /// (FieldOffers.swift), but after the row Return takes: the empty tab
    /// is there for somewhere new, not to bring a page in.
    func testAnEmptyTabOnItsOwnOffersOpenTabsAfterTheFirstRow() throws {
        try withBrowser { browser, tabs in
            browser.newTab()
            browser.typed = "notes"
            XCTAssertNotNil(browser.offers.first)
            XCTAssertNil(browser.offers.first?.tab, "the row Return takes stays first")
            XCTAssertEqual(browser.offers.dropFirst().first?.tab, tabs[8].id)
        }
    }

    private func withBrowser(_ body: (Browser, [Tab]) throws -> Void) rethrows {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView, prefs.newTabPlace)
        defer {
            browser.closeAll()
            prefs.usesTabGroups = saved.0
            prefs.splitView = saved.1
            prefs.newTabPlace = saved.2
        }
        prefs.usesTabGroups = false
        prefs.splitView = true
        // Each new tab after the last, so they stand in the order made.
        prefs.newTabPlace = .next
        // Whatever an earlier test left in this world's session, gone: its
        // tabs would stand before these and take their places.
        let left = browser.tabs
        browser.showRow([], active: nil)
        left.forEach { $0.close() }
        let titles = (1...8).map { "Page \($0)" } + ["Notes"]
        for (number, title) in titles.enumerated() {
            if number > 0 || browser.tabs.isEmpty { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://example.invalid/\(number + 1)")!, title: title)
        }
        // Looked at from the last to the first: "Notes" longest ago.
        for tab in browser.tabs.reversed() { browser.select(tab) }
        try body(browser, browser.tabs)
    }
}
