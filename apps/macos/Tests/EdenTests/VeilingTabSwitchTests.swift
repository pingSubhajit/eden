import AppKit
import XCTest
@testable import Eden

@MainActor
final class VeilingTabSwitchTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "veiling-tab-switch-\(getpid())", 1)
        super.setUp()
    }

    func testGoingToAnotherTabPutsThePickerAway() {
        withBrowser { browser, tabs in
            browser.select(tabs[0])
            browser.toggleHiding()
            XCTAssertTrue(browser.veiling)

            browser.select(tabs[1])
            XCTAssertFalse(browser.veiling)

            browser.toggleHiding()
            XCTAssertTrue(browser.veiling)
        }
    }

    func testOnlyThePickingTabEndsThePicking() {
        withBrowser { browser, tabs in
            browser.select(tabs[0])
            browser.toggleHiding()
            browser.select(tabs[1])
            browser.toggleHiding()

            tabs[0].pickingEnded()
            XCTAssertTrue(browser.veiling)

            tabs[1].pickingEnded()
            XCTAssertFalse(browser.veiling)
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
        prefs.splitView = false
        // Each new tab after the last, so they stand in the order made.
        prefs.newTabPlace = .next
        for number in 1...2 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        try body(browser, browser.tabs)
    }
}
