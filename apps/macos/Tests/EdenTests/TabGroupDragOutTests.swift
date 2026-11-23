import EdenCore
import AppKit
import SwiftUI
import XCTest
@testable import Eden

/// A tab carried out of its group and let go among the tabs in none leaves
/// the group and lands there (#1009). Where it lands is worked out from the
/// column's layout (ColumnLayout), the move itself is the browser's
/// (Browser.move(_:outOfGroupBefore:)), and a hand carries one out of a
/// group in the column, hosted as RowCarryTests does, in a borderless
/// window far off every screen.
@MainActor
final class TabGroupDragOutTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        setenv("EDEN_PROBE", "group-drag-out-\(getpid())", 1)
        super.setUp()
    }

    /// From a space as a new install has it, whatever the suites before
    /// left in this process's world (CleanWorld).
    override func setUp() async throws {
        try await super.setUp()
        CleanWorld.reset()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("group-drag-out-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.subhajit.eden.beta.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.closeAll() }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        TabDrag.testPointer = nil
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(250))
        try await super.tearDown()
    }

    // MARK: - where it lands

    // MARK: - the move

    func testTheMoveOutOfAGroup() throws {
        let browser = makeBrowser()
        let t = browser.tabs
        let group = browser.addTabGroup(containing: t[0])
        browser.move(t[1], toGroup: group)
        browser.move(t[2], toGroup: group)
        // Group: one two three. In none: four five.
        XCTAssertEqual(browser.tabs.map(\.id), t.map(\.id))

        browser.move(t[1], outOfGroupBefore: .tab(t[4].id))
        XCTAssertNil(browser.group(of: t[1]), "out of the group")
        XCTAssertEqual(browser.tabs.map(\.id), [t[0], t[2], t[3], t[1], t[4]].map(\.id), "in front of five")

        browser.move(t[2], outOfGroupBefore: nil)
        XCTAssertEqual(browser.tabs.last?.id, t[2].id, "after the last")

        // In no group already: nothing moves.
        let order = browser.tabs.map(\.id)
        browser.move(t[3], outOfGroupBefore: .tab(t[1].id))
        XCTAssertEqual(browser.tabs.map(\.id), order)

        // The last tab out takes the group with it, as Remove from Group does.
        browser.move(t[0], outOfGroupBefore: .tab(t[3].id))
        XCTAssertFalse(browser.tabGroups.contains { $0.id == group }, "the empty group goes")
        XCTAssertEqual(browser.tabs.first?.id, t[0].id)
    }

    func testWhatGoesWithItGoesOutToo() throws {
        let browser = makeBrowser()
        let t = browser.tabs
        let group = browser.addTabGroup(containing: t[0])
        for tab in t[1...3] { browser.move(tab, toGroup: group) }
        // A pair leaves whole and stays a pair.
        browser.pair(t[2], with: t[1], onLeft: false)
        XCTAssertNotNil(browser.split(for: t[1]))
        browser.move(t[1], outOfGroupBefore: nil)
        XCTAssertNil(browser.group(of: t[1]))
        XCTAssertNil(browser.group(of: t[2]))
        XCTAssertNotNil(browser.split(for: t[1]), "still a pair")
        XCTAssertEqual(Array(browser.tabs.suffix(2)).map(\.id), [t[1], t[2]].map(\.id))

        // A half shown leaving its pair goes on its own, out of the pair.
        browser.move(t[1], toGroup: group)
        XCTAssertEqual(browser.group(of: t[2]), group, "the pair back in, whole")
        browser.move(t[2], outOfGroupBefore: nil, detaching: true)
        XCTAssertNil(browser.group(of: t[2]))
        XCTAssertEqual(browser.group(of: t[1]), group, "its other half stays")
        XCTAssertNil(browser.split(for: t[1]), "no longer a pair")
        browser.move(t[1], toGroup: nil)

        // Tabs picked together leave together.
        browser.select(t[0])
        browser.extendTabSelection(to: t[3], modifiers: .command)
        XCTAssertEqual(browser.selectedTabIDs, Set([t[0].id, t[3].id]))
        browser.move(t[0], outOfGroupBefore: .tab(t[4].id))
        XCTAssertNil(browser.group(of: t[0]))
        XCTAssertNil(browser.group(of: t[3]))
        XCTAssertFalse(browser.tabGroups.contains { $0.id == group }, "nothing left in it")
    }

    func testNothingWithGroupsOff() {
        let browser = makeBrowser()
        let t = browser.tabs
        let group = browser.addTabGroup(containing: t[0])
        browser.prefs.usesTabGroups = false
        browser.move(t[0], outOfGroupBefore: nil)
        XCTAssertEqual(t[0].groupID, group, "asleep with groups off, not taken out")
    }

    // MARK: - by hand

    func testCarriedOutOfItsGroupDownTheColumn() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        let group = browser.addTabGroup(containing: t[0])
        browser.move(t[1], toGroup: group)
        browser.editingGroupID = nil
        browser.select(t[4])
        let window = makeWindow(browser)
        try await settle()
        TabDrag.testPointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
        // Down the rows from their top: no line over them, nothing being
        // kept above it (a group is among the tabs, #6). The heading 0–28,
        // one 30–58, two 60–88, then three, four, five and New tab; empty
        // from about 210.
        let grab: CGFloat = 44

        // A hand that barely moves leaves it where it was.
        try await carry(from: grab, to: grab + 8, in: window)
        XCTAssertEqual(browser.group(of: t[0]), group, "stayed in its group")

        // Down past everything, into the column's empty foot.
        try await carry(from: grab, to: 250, in: window)
        XCTAssertNil(browser.group(of: t[0]), "out of its group")
        XCTAssertEqual(browser.tabs.last?.id, t[0].id, "after the last tab in no group")
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[1].id], "the other stays")
    }

    // MARK: - helpers

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.usesTabGroups, prefs.splitView, prefs.roomyTabs, prefs.newTabPlace)
        restorePreferences = {
            (prefs.usesTabGroups, prefs.splitView, prefs.roomyTabs, prefs.newTabPlace) = previous
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.usesTabGroups = true
        browser.prefs.splitView = true
        browser.prefs.roomyTabs = false
        // Each new tab after the last, so they stand in the order made.
        browser.prefs.newTabPlace = .next
        for word in ["one", "two", "three", "four", "five"] {
            if browser.tabs.last?.isBlank != true { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs))
        window.orderFrontRegardless()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }

    private func point(y: CGFloat, in window: NSWindow) -> NSPoint {
        NSPoint(x: 70, y: window.frame.height - Metrics.strip - y)
    }

    private func carry(from: CGFloat, to: CGFloat, in window: NSWindow) async throws {
        try await send(.leftMouseDown, at: point(y: from, in: window), in: window)
        for y in stride(from: from + 2, through: to, by: 2) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        try await send(.leftMouseUp, at: point(y: to, in: window), in: window)
        try await settle()
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(30))
    }
}
