import AppKit
import EdenCore
import XCTest
@testable import Eden

/// Closing the tab you're on goes back to the one you were on before, and a
/// close never makes a new tab by itself: with nowhere to go, the window
/// shows nothing in front (Browser.landing, Browser.showNothing).
@MainActor
final class NothingInFrontTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "nothing-in-front-\(getpid())", 1)
        super.setUp()
    }

    // MARK: - where a close lands

    /// The tab viewed before the one closed comes back, not its neighbour.
    func testCloseGoesBackToTheTabBefore() {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.select(tabs[1])
        browser.select(tabs[3])
        browser.select(tabs[0])
        browser.closeTab(tabs[0])
        XCTAssertEqual(browser.activeID, tabs[3].id, "the one before, not the neighbour below")
        browser.closeTab(tabs[3])
        XCTAssertEqual(browser.activeID, tabs[1].id, "and the one before that")
        XCTAssertFalse(browser.tabs.contains(where: \.isBlank), "no tab made on the way")
    }

    /// With Closing a tab goes back off, a loose tab still lands on its
    /// neighbour, below first.
    func testWithGoingBackOffALooseTabLandsOnItsNeighbour() {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.prefs.closeGoesBack = false
        browser.select(tabs[3])
        browser.select(tabs[1])
        browser.closeTab(tabs[1])
        XCTAssertEqual(browser.activeID, tabs[2].id, "the one below")
        browser.select(tabs[3])
        browser.closeTab(tabs[3])
        XCTAssertEqual(browser.activeID, tabs[2].id, "the one above, at the end of the row")
    }

    /// A pin put down, or closed, is forgotten: ⌘W on the pin landed on
    /// doesn't go back to it, so two pins don't take turns for ever.
    func testPutDownPinsAreForgottenSoWDoesNotPingPong() {
        let browser = makeBrowser(count: 3)
        let tabs = browser.tabs
        browser.pin(tabs[0])
        browser.pin(tabs[1])
        let (a, b, loose) = (tabs[0], tabs[1], tabs[2])
        browser.select(loose)
        browser.select(a)
        browser.select(b)

        browser.closeFront()
        XCTAssertEqual(browser.activeID, a.id, "back to the pin you were on before")
        XCTAssertTrue(b.asleep, "put down")
        browser.closeFront()
        XCTAssertEqual(browser.activeID, loose.id, "not back to the pin just put down")
        XCTAssertTrue(a.asleep && b.asleep, "neither pin woken again")
    }

    /// Off a pin with nothing before it to go back to, never onto another
    /// pin you weren't on: nothing in front instead, and no tab made.
    func testPinsAloneLeaveNothingInFront() {
        let browser = makeBrowser(count: 2)
        let tabs = browser.tabs
        browser.pin(tabs[0])
        browser.pin(tabs[1])
        browser.select(tabs[0])
        browser.select(tabs[1])
        browser.closeFront()
        XCTAssertEqual(browser.activeID, tabs[0].id)
        browser.closeFront()
        XCTAssertNil(browser.activeID, "nothing in front")
        XCTAssertEqual(browser.tabs.map(\.id), [tabs[0].id, tabs[1].id], "the pins, and no tab made beside them")
        XCTAssertTrue(tabs.allSatisfy(\.asleep))
    }

    /// A grouped tab put away goes back to the tab before it, and is not
    /// gone back to after.
    func testPutAwayGoesBackAndIsForgotten() {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.prefs.usesTabGroups = true
        let group = browser.addTabGroup(containing: tabs[2])
        browser.move(tabs[3], toGroup: group)
        browser.select(tabs[0])
        browser.select(tabs[2])
        browser.closeTab(tabs[2])
        XCTAssertTrue(tabs[2].asleep, "put away")
        XCTAssertTrue(browser.tabs.contains { $0.id == tabs[2].id }, "its row stays in the group")
        XCTAssertEqual(browser.activeID, tabs[0].id, "back to the tab before it")

        browser.select(tabs[3])
        browser.closeTab(tabs[3])
        XCTAssertEqual(browser.activeID, tabs[0].id, "not back to the tab put away before")
        XCTAssertFalse(browser.tabs.contains(where: \.isBlank))
    }

    /// The last loose tab closed beside groups goes back to the grouped tab
    /// you were on, and makes no new tab.
    func testLastLooseTabBesideGroupsGoesBack() {
        let browser = makeBrowser(count: 3)
        let tabs = browser.tabs
        browser.prefs.usesTabGroups = true
        let group = browser.addTabGroup(containing: tabs[0])
        browser.move(tabs[1], toGroup: group)
        browser.select(tabs[0])
        browser.select(tabs[2])
        browser.closeTab(tabs[2])
        XCTAssertEqual(browser.activeID, tabs[0].id)
        XCTAssertEqual(browser.tabs.count, 2, "no new tab in its place")
        XCTAssertFalse(browser.tabs.contains(where: \.isBlank))
    }

    /// Beside groups whose pages are all put away, nothing looks open to
    /// land on: nothing in front, the groups as they were.
    func testLastLooseTabBesideSleepingGroupsLeavesNothing() {
        let browser = makeBrowser(count: 3)
        let tabs = browser.tabs
        browser.prefs.usesTabGroups = true
        let group = browser.addTabGroup(containing: tabs[0])
        browser.move(tabs[1], toGroup: group)
        browser.select(tabs[0])
        browser.select(tabs[1])
        browser.closeTab(tabs[1])
        XCTAssertEqual(browser.activeID, tabs[0].id)
        browser.closeTab(tabs[0])
        XCTAssertEqual(browser.activeID, tabs[2].id)
        XCTAssertTrue(tabs[0].asleep && tabs[1].asleep, "both put away")
        browser.closeTab(tabs[2])
        XCTAssertNil(browser.activeID)
        XCTAssertEqual(browser.tabs.map(\.id), [tabs[0].id, tabs[1].id])
        XCTAssertTrue(tabs[0].asleep && tabs[1].asleep, "nothing woken")
    }

    // MARK: - nothing in front

    /// Every tab closed: nothing in front, an empty row, the window open,
    /// and no tab made for it.
    func testClosingEveryTabLeavesNothingInFront() {
        let browser = makeBrowser(count: 3)
        for _ in 0..<3 { browser.closeFront() }
        XCTAssertNil(browser.activeID)
        XCTAssertTrue(browser.tabs.isEmpty, "no tab made")
        XCTAssertFalse(browser.fieldShowing, "no field standing on the ground")
        XCTAssertEqual(browser.recentlyClosed.count, 3)
        browser.reopen()
        XCTAssertNotNil(browser.active, "⇧⌘T brings one back in front")
    }

    /// Clear closes the tabs that come and go and makes none in their place.
    func testClearMakesNoTab() {
        let browser = makeBrowser()
        browser.select(browser.tabs[1])
        browser.clearTabs()
        XCTAssertNil(browser.activeID)
        XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertFalse(browser.canClearTabs)
        browser.reopen()
        XCTAssertEqual(browser.tabs.count, 4, "one ⇧⌘T brings every tab back")
        XCTAssertFalse(browser.tabs.contains(where: \.isBlank))
    }

    /// Clear with a pin you were on lands back on it.
    func testClearGoesBackToThePinYouWereOn() {
        let browser = makeBrowser(count: 3)
        let tabs = browser.tabs
        browser.pin(tabs[0])
        browser.select(tabs[0])
        browser.select(tabs[2])
        browser.clearTabs()
        XCTAssertEqual(browser.activeID, tabs[0].id)
        XCTAssertEqual(browser.tabs.map(\.id), [tabs[0].id])
    }

    /// ⌘W with nothing in front closes the window, as it did on a lone
    /// empty tab.
    func testCommandWWithNothingInFrontClosesTheWindow() {
        let browser = makeBrowser(count: 1)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let asked = CloseWatch()
        window.delegate = asked
        browser.window = window
        defer { browser.window = nil }

        browser.closeFront()
        XCTAssertNil(browser.activeID, "the tab went first")
        XCTAssertEqual(asked.asked, 0, "the window stays while it had a tab")
        browser.closeFront()
        XCTAssertEqual(asked.asked, 1, "⌘W again: the window is asked to close")
    }

    /// ⌘W on a lone empty tab still closes the window.
    func testCommandWOnALoneEmptyTabClosesTheWindow() {
        let browser = makeBrowser(count: 0)
        browser.newTab()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let asked = CloseWatch()
        window.delegate = asked
        browser.window = window
        defer { browser.window = nil }
        browser.closeFront()
        XCTAssertEqual(asked.asked, 1)
        XCTAssertEqual(browser.tabs.count, 1, "the tab stays with the window it closes")
    }

    /// The field isn't up with nothing in front; ⌘T and ⌘L raise one whose
    /// Return opens a new tab, and Escape leaves nothing in front again.
    func testFieldWithNothingInFront() throws {
        let browser = makeBrowser(count: 0)
        XCTAssertNil(browser.activeID)
        XCTAssertFalse(browser.fieldShowing)

        browser.launch()
        XCTAssertTrue(browser.fieldShowing)
        XCTAssertEqual(browser.fieldMode, .newTab)
        XCTAssertTrue(browser.tabs.isEmpty, "⌘T's field is not a tab")
        browser.dismiss()
        XCTAssertFalse(browser.fieldShowing)
        XCTAssertNil(browser.activeID)

        browser.edit()
        XCTAssertTrue(browser.fieldShowing, "⌘L raises the same field")
        XCTAssertEqual(browser.fieldMode, .newTab)
        browser.edit()
        XCTAssertFalse(browser.fieldShowing, "and again puts it away")

        browser.launch()
        browser.typed = "https://typed.example/"
        browser.submit()
        let tab = try XCTUnwrap(browser.active)
        XCTAssertEqual(browser.tabs.count, 1, "Return made the one tab")
        XCTAssertEqual(tab.pending?.host() ?? tab.address?.host(), "typed.example")
    }

    /// With a pin beside nothing in front, Return in the field opens a tab
    /// of its own and leaves the pin as it was.
    func testReturnWithNothingInFrontNeverTakesAPin() {
        let browser = makeBrowser(count: 1)
        let pin = browser.tabs[0]
        browser.pin(pin)
        browser.closeFront()
        XCTAssertNil(browser.activeID)
        browser.edit()
        browser.typed = "https://typed.example/"
        browser.submit()
        XCTAssertNotEqual(browser.activeID, pin.id)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertNotEqual(pin.pending?.host() ?? pin.address?.host(), "typed.example")
    }

    /// ⌃Tab and ⌘1 work from nothing in front.
    func testSwitcherAndNumbersFromNothingInFront() {
        let browser = makeBrowser(count: 3)
        let tabs = browser.tabs
        browser.select(tabs[2])
        browser.select(tabs[1])
        browser.showNothing()
        XCTAssertNil(browser.activeID)

        browser.switchTabs(backwards: false)
        XCTAssertTrue(browser.tabSwitcher.active, "the gesture starts with no card of its own")
        browser.commitTabSwitch()
        XCTAssertEqual(browser.activeID, tabs[1].id, "the tab left last")

        browser.showNothing()
        browser.select(index: 0)
        XCTAssertEqual(browser.activeID, tabs[0].id)

        browser.showNothing()
        browser.step(1)
        XCTAssertEqual(browser.activeID, tabs[0].id, "Next Tab: the first")
    }

    /// The last tab moved to another window leaves this one open and empty.
    func testMovingTheLastTabOutLeavesNothingInFront() {
        let browser = makeBrowser(count: 1)
        let other = Browser(record: WindowRecord())
        other.closeAll()
        addTeardownBlock { @MainActor in other.closeAll() }
        let tab = browser.tabs[0]
        browser.move([tab], toWindow: other)
        XCTAssertNil(browser.activeID)
        XCTAssertTrue(browser.tabs.isEmpty, "no tab made to hold its place")
        XCTAssertEqual(other.activeID, tab.id)
    }

    /// The page on screen moved out of its pair: the other page of the
    /// pair comes to the front, not the tab viewed before the pair.
    func testMovingOnePageOfAPairLandsOnItsPartner() {
        let browser = makeBrowser(count: 3)
        browser.prefs.splitView = true
        let tabs = browser.tabs
        let other = Browser(record: WindowRecord())
        other.closeAll()
        addTeardownBlock { @MainActor in other.closeAll() }
        browser.select(tabs[2])
        browser.select(tabs[0])
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.select(tabs[1])
        XCTAssertNotNil(browser.split(for: tabs[1]), "a pair to start from")
        XCTAssertEqual(browser.activeID, tabs[1].id)
        browser.move([tabs[1]], toWindow: other)
        XCTAssertEqual(browser.activeID, tabs[0].id, "its partner, not the tab before")
    }

    /// Clear with an empty pane in front, then ⇧⌘T: the empty pane can't
    /// come back, and the page beside it comes to the front in its place
    /// rather than staying out of sight behind nothing in front.
    func testClearUndoWithAnEmptyPaneInFrontPutsAPageInFront() {
        let browser = makeBrowser(count: 1)
        browser.prefs.splitView = true
        let page = browser.tabs[0]
        browser.newTab()
        guard let empty = browser.active, empty.isBlank else { return XCTFail("an empty tab in front") }
        browser.pair(empty, with: page, onLeft: false)
        browser.select(empty)
        browser.clearTabs()
        XCTAssertNil(browser.activeID)
        browser.reopen()
        XCTAssertNotNil(browser.activeID, "something is in front again")
        XCTAssertEqual(browser.active?.address?.host, page.address?.host)
    }

    // MARK: - sessions

    /// Nothing in front is written as nothing in front, and comes back so:
    /// the tabs, and no empty tab in front of them.
    func testSessionsKeepNothingInFront() {
        let browser = makeWritingBrowser()
        browser.showNothing()
        browser.writeSession(now: true)
        let saved = browser.readRow(browser.spaceID)
        XCTAssertEqual(saved.active, -1)
        XCTAssertEqual(saved.tabs.map(\.url), ["https://one.example/", "https://two.example/"])

        let next = reopened(browser, saved)
        XCTAssertNil(next.activeID)
        XCTAssertEqual(next.tabs.compactMap { ($0.pending ?? $0.address)?.host() }, ["one.example", "two.example"])
        XCTAssertFalse(next.tabs.contains(where: \.isBlank), "no empty tab made for it")
        XCTAssertFalse(next.fieldShowing)
    }

    /// A tab in front still comes back in front.
    func testSessionsKeepTheTabInFront() {
        let browser = makeWritingBrowser()
        browser.select(browser.tabs[1])
        browser.writeSession(now: true)
        let saved = browser.readRow(browser.spaceID)
        XCTAssertEqual(saved.active, 1)
        let next = reopened(browser, saved)
        XCTAssertEqual((next.active?.pending ?? next.active?.address)?.host(), "two.example")
    }

    /// A fresh start (Session.startFresh) keeps a named tab and marks none
    /// in front: the window opens with nothing in front, and no empty tab.
    func testFreshStartShowsNothingInFront() {
        let browser = makeWritingBrowser()
        browser.tabs[0].name = "Kept"
        browser.select(browser.tabs[1])
        browser.writeSession(now: true)
        let fresh = Session.fresh(browser.readRow(browser.spaceID))
        XCTAssertEqual(fresh.active, -1)
        let next = reopened(browser, fresh)
        XCTAssertNil(next.activeID)
        XCTAssertEqual(next.tabs.map(\.name), ["Kept"])
        XCTAssertFalse(next.tabs.contains(where: \.isBlank))
    }

    // MARK: - helpers

    /// A window whose session is written: closeAll retires a browser, and
    /// one retired writes nothing. Its row is emptied by hand instead.
    private func makeWritingBrowser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let left = browser.tabs
        browser.showRow([], active: nil)
        left.forEach { $0.close() }
        browser.tabGroups = []
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView, prefs.newTabPlace)
        addTeardownBlock { @MainActor in
            browser.closeAll()
            prefs.usesTabGroups = saved.0
            prefs.splitView = saved.1
            prefs.newTabPlace = saved.2
            CleanWorld.reset()
        }
        prefs.usesTabGroups = false
        prefs.splitView = false
        prefs.newTabPlace = .next
        for word in ["one", "two"] {
            browser.newTab()
            if let url = URL(string: "https://\(word).example/") { browser.tabs.last?.restore(url: url, title: word) }
        }
        return browser
    }

    /// The window opened again from a row as saved, wherever this window
    /// keeps its rows (see TabGroupDropTests).
    private func reopened(_ browser: Browser, _ saved: Session.Shape) -> Browser {
        var record = browser.record
        record.rows[browser.spaceID.uuidString] = saved
        let next = Browser(record: record)
        addTeardownBlock { @MainActor in next.closeAll() }
        return next
    }

    private func makeBrowser(count: Int = 4) -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        // One session serves every suite in the process, so a Browser opens
        // with whatever tabs the last test left.
        browser.closeAll()
        browser.showNothing()
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView, prefs.newTabPlace, prefs.closeGoesBack)
        addTeardownBlock { @MainActor in
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
            prefs.usesTabGroups = saved.0
            prefs.splitView = saved.1
            prefs.newTabPlace = saved.2
            prefs.closeGoesBack = saved.3
            CleanWorld.reset()
        }
        prefs.usesTabGroups = false
        prefs.splitView = false
        prefs.closeGoesBack = true
        // Each new tab after the last, so they stand in the order made.
        prefs.newTabPlace = .next
        let words = ["one", "two", "three", "four", "five", "six"]
        for word in words.prefix(count) {
            if browser.tabs.last?.isBlank != true { browser.newTab() }
            if let url = URL(string: "https://\(word).example/") { browser.tabs.last?.restore(url: url, title: word) }
        }
        return browser
    }
}

/// A window's delegate that counts the asks to close and keeps it open.
@MainActor
private final class CloseWatch: NSObject, NSWindowDelegate {
    var asked = 0

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { asked += 1 }
        return false
    }
}
