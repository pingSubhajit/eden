import EdenCore
import AppKit
import SwiftUI
import XCTest
@testable import Eden

/// The column's hands made the same everywhere (#41): Escape calls off any
/// carry, a pin dragged leaves you on the tab you were on, picked tabs go
/// together, a split's half and a row say alike what closing them does, the
/// column's own places have a menu, rows and squares answer VoiceOver, and
/// the field in a row takes ⌘Return. Hosted as RowCarryTests is, in a
/// borderless window far off every screen.
@MainActor
final class ColumnHandsTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        setenv("EDEN_PROBE", "column-hands-\(getpid())", 1)
        super.setUp()
    }

    /// From a space as a new install has it, whatever the suites before
    /// left in this process's world (CleanWorld).
    override func setUp() async throws {
        try await super.setUp()
        CleanWorld.reset()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("column-hands-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.subhajit.eden.beta.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        TabDrag.testPointer = nil
        CarryGuard.endAll()
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers {
            browser.window = nil
            browser.cancelTabEdit()
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            Pins.setGroups(browser.spaceID, [], from: nil)
            browser.closeAll()
        }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        CleanWorld.reset()
        try await Task.sleep(for: .milliseconds(250))
        try await super.tearDown()
    }

    // MARK: - Escape calls off any carry

    /// A square carried across the grid, Escape pressed with the button
    /// still down: the squares as they stood, and the next moves of the
    /// hand don't pick it up again.
    func testEscapeCallsOffASquareCarry() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        for tab in t[0...2] { browser.pin(tab) }
        browser.select(t[0])
        let window = makeWindow(browser)
        try await ready(browser)
        let squares = browser.squarePins.map(\.id)
        // Three squares in one row, 0–34.
        let room = browser.prefs.sideWidth - 20
        let y: CGFloat = 17
        try await send(.leftMouseDown, at: pins(10 + room / 6, y, in: window), in: window)
        for x in stride(from: 10 + room / 6 + 4, through: 10 + room * 5 / 6, by: 4) {
            try await send(.leftMouseDragged, at: pins(x, y, in: window), in: window)
        }
        XCTAssertEqual(CarryGuard.count, 1, "carried")
        XCTAssertNotEqual(browser.squarePins.map(\.id), squares, "the others made way")
        XCTAssertTrue(CarryGuard.escape(), "there was a carry to call off")
        try await settle()
        XCTAssertEqual(CarryGuard.count, 0)
        XCTAssertEqual(browser.squarePins.map(\.id), squares, "back as they stood")
        for x in stride(from: 10 + room * 5 / 6, through: 10 + room / 2, by: -4) {
            try await send(.leftMouseDragged, at: pins(x, y, in: window), in: window)
        }
        XCTAssertEqual(CarryGuard.count, 0, "not picked up again")
        try await send(.leftMouseUp, at: pins(10 + room / 2, y, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.squarePins.map(\.id), squares, "nothing dropped")
        XCTAssertFalse(CarryGuard.escape(), "nothing left to call off")
    }

    /// A pinned row carried along the kept rows, and then one carried over
    /// the line: Escape puts each back, nothing pinned or unpinned.
    func testEscapeCallsOffAKeptRowCarry() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        for tab in t[0...2] { browser.pin(tab, listed: true) }
        browser.select(t[0])
        let window = makeWindow(browser)
        try await ready(browser)
        let rows = browser.listedPins.map(\.id)
        // Kept: one 0–28, two 30–58, three 60–88; the line 90–108; four
        // 110–138, five 140–168.
        try await carry(from: 14, to: 76, in: window, letGo: false)
        XCTAssertEqual(CarryGuard.count, 1, "carried")
        XCTAssertNotEqual(browser.listedPins.map(\.id), rows, "the others made way")
        CarryGuard.escape()
        try await settle()
        XCTAssertEqual(browser.listedPins.map(\.id), rows, "back as they stood")
        try await send(.leftMouseUp, at: point(y: 76, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.listedPins.map(\.id), rows)

        SideBar.shownGap = nil
        try await carry(from: 44, to: 150, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.carried, .tab(t[1].id), "the tabs part for it")
        CarryGuard.escape()
        try await settle()
        XCTAssertNil(SideBar.shownGap, "the gap closed")
        try await send(.leftMouseUp, at: point(y: 150, in: window), in: window)
        try await settle()
        XCTAssertNotNil(t[1].pin, "still a pin")
        XCTAssertEqual(browser.listedPins.map(\.id), rows)
    }

    /// A group carried by its heading up over the line: Escape closes the
    /// gap the kept rows opened, and letting go there leaves it open.
    func testEscapeCallsOffAHeadingCarry() async throws {
        let browser = makeBrowser()
        browser.prefs.usesTabGroups = true
        let t = browser.tabs
        browser.pin(t[0], listed: true)
        let group = browser.addTabGroup(containing: t[2])
        browser.move(t[3], toGroup: group)
        browser.editingGroupID = nil
        browser.select(t[4])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // one 0–28; the line 30–48; two 50–78; the group 80–168, its
        // heading 83–105; five 170–198.
        try await carry(from: 94, to: 10, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.carried, .group(group), "the kept rows part for it")
        XCTAssertTrue(CarryGuard.escape())
        try await settle()
        XCTAssertNil(SideBar.shownGap, "the gap closed")
        try await send(.leftMouseUp, at: point(y: 10, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.area(ofGroup: group), .open, "still among the tabs")
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[2], t[3]].map(\.id))
    }

    // MARK: - back where you were after a pin is dragged

    /// A square pressed and carried to another cell: the press brought it
    /// forward, and once it is let go the tab you were on is back. With
    /// Tabs give when pressed on, which a square now does too, and which
    /// mustn't call its carry off.
    func testASquareDraggedLeavesYouWhereYouWere() async throws {
        let browser = makeBrowser()
        browser.prefs.tabsGive = true
        let t = browser.tabs
        for tab in t[0...2] { browser.pin(tab) }
        let window = makeWindow(browser)
        // Each pin's page loaded once, so the press that brings it forward
        // starts no load under the hand (see ready).
        for tab in t[0...2] { browser.select(tab); try await ready(browser) }
        browser.select(t[4])
        try await ready(browser)
        let room = browser.prefs.sideWidth - 20
        let y: CGFloat = 17
        try await send(.leftMouseDown, at: pins(10 + room / 6, y, in: window), in: window)
        XCTAssertEqual(browser.activeID, t[0].id, "brought forward by the press")
        for x in stride(from: 10 + room / 6 + 4, through: 10 + room * 5 / 6, by: 4) {
            try await send(.leftMouseDragged, at: pins(x, y, in: window), in: window)
        }
        try await send(.leftMouseUp, at: pins(10 + room * 5 / 6, y, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.squarePins.last?.id, t[0].id, "moved")
        XCTAssertEqual(browser.activeID, t[4].id, "back on the tab you were on")

        // A plain click still goes to it.
        try await send(.leftMouseDown, at: pins(10 + room * 5 / 6, y, in: window), in: window)
        try await send(.leftMouseUp, at: pins(10 + room * 5 / 6, y, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.activeID, t[0].id, "a click goes to it")
    }

    /// A pinned row pressed and carried down under the line: unpinned
    /// there, and you are back on the tab you were on.
    func testAPinnedRowDraggedAcrossTheLineLeavesYouWhereYouWere() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        for tab in t[0...1] { browser.pin(tab, listed: true) }
        let window = makeWindow(browser)
        for tab in t[0...1] { browser.select(tab); try await ready(browser) }
        browser.select(t[4])
        try await ready(browser)
        // Kept: one 0–28, two 30–58; the line 60–78; three 80–108, four
        // 110–138, five 140–168.
        try await send(.leftMouseDown, at: point(y: 14, in: window), in: window)
        XCTAssertEqual(browser.activeID, t[0].id, "brought forward by the press")
        try await carry(from: 16, to: 124, in: window, pressing: false)
        try await settle()
        XCTAssertNil(t[0].pin, "unpinned under the line")
        XCTAssertEqual(browser.activeID, t[4].id, "back on the tab you were on")
    }

    // MARK: - picked tabs go together

    /// Two tabs picked, one carried up over the line: both pinned there, in
    /// their order; the two carried back down, both unpinned there.
    func testPickedTabsCrossTheLineTogether() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.pin(t[0], listed: true)
        browser.select(t[2])
        browser.extendTabSelection(to: t[3], modifiers: [.command])
        XCTAssertEqual(browser.selectedTabIDs, [t[2].id, t[3].id])
        let window = makeWindow(browser)
        try await ready(browser)
        // one 0–28; the line 30–48; two 50–78, three 80–108, four 110–138,
        // five 140–168. "four" carried to the head of the kept rows.
        try await carry(from: 124, to: 8, in: window)
        try await settle()
        XCTAssertEqual(browser.listedPins.map(\.id), [t[2], t[3], t[0]].map(\.id), "both pinned, in order")

        // three 0–28, four 30–58, one 60–88; the line 90–108; two 110–138,
        // five 140–168. "four" carried down between two and five: past
        // "one" on its way, and not past "three", which keeps the two in
        // their order along the kept rows.
        browser.clearTabSelection()
        browser.select(t[2])
        browser.extendTabSelection(to: t[3], modifiers: [.command])
        try await settle()
        try await carry(from: 44, to: 152, in: window)
        try await settle()
        XCTAssertEqual(browser.listedPins.map(\.id), [t[0].id], "both unpinned")
        XCTAssertEqual(browser.tabs.filter { $0.pin == nil }.map(\.id), [t[1], t[2], t[3], t[4]].map(\.id),
                       "together, in their order")
    }

    /// A square of this space's and a row every space shows, picked: the
    /// row carried onto the squares makes both squares, the shared one at
    /// the head as shared ones stand; carried up over the line, both rows;
    /// carried under it, both tabs. Mid-move, the shared one was counted
    /// among the squares where nothing stood yet, and inserting there
    /// trapped.
    func testSharedAndOwnPinsPickedTogetherMoveWithoutLosingCount() throws {
        let browser = makeBrowser()
        let prefs = browser.prefs
        let before = (prefs.usesSpaces, prefs.sharesPins)
        let t = browser.tabs
        addTeardownBlock { @MainActor in
            for tab in t where tab.everywhere { browser.keepHere(tab) }
            (prefs.usesSpaces, prefs.sharesPins) = before
        }
        prefs.usesSpaces = true
        prefs.sharesPins = true
        browser.pin(t[0])
        browser.pin(t[1], listed: true)
        browser.shareEverywhere(t[1])
        XCTAssertTrue(t[1].everywhere)
        pick([t[0], t[1]], in: browser)

        XCTAssertTrue(browser.square(carrying: t[1], at: 1))
        XCTAssertEqual(browser.squarePins.map(\.id), [t[1], t[0]].map(\.id), "both squares, the shared one first")

        pick([t[0], t[1]], in: browser)
        XCTAssertTrue(browser.move(carrying: t[0], to: ColumnPlace(area: .kept, index: 0)))
        XCTAssertTrue([t[0], t[1]].allSatisfy { $0.pin != nil && $0.listed }, "both rows")
        XCTAssertTrue(browser.squarePins.isEmpty)

        pick([t[0], t[1]], in: browser)
        XCTAssertTrue(browser.move(carrying: t[0], to: ColumnPlace(area: .open, index: 0)))
        XCTAssertTrue([t[0], t[1]].allSatisfy { $0.pin == nil }, "both tabs")
    }

    /// Two pinned rows picked, one carried down along the kept rows: the
    /// other goes with it, as tabs under the line and squares move.
    func testPickedPinnedRowsMoveTogetherAlongTheKeptRows() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        for tab in t[0...3] { browser.pin(tab, listed: true) }
        browser.select(t[0])
        browser.extendTabSelection(to: t[1], modifiers: [.command])
        let window = makeWindow(browser)
        try await ready(browser)
        // Kept: one 0–28, two 30–58, three 60–88, four 90–118. "one"
        // carried down past "three".
        try await carry(from: 14, to: 80, in: window)
        try await settle()
        XCTAssertEqual(browser.listedPins.map(\.id), [t[2], t[0], t[1], t[3]].map(\.id), "together, in order")
    }

    /// A pinned row and a tab picked, the tab carried up over the line: the
    /// row goes with it, still a pin, and the tab is pinned beside it, in
    /// the order they had.
    func testPickedPinsAndTabsGoAboveTheLineTogether() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        for tab in t[0...1] { browser.pin(tab, listed: true) }
        pick([t[1], t[3]], in: browser)
        let window = makeWindow(browser)
        try await ready(browser)
        // Kept: one 0–28, two 30–58; the line 60–78; three 80–108, four
        // 110–138, five 140–168. "four" carried to the head of the kept rows.
        try await carry(from: 124, to: 8, in: window)
        try await settle()
        XCTAssertEqual(browser.listedPins.map(\.id), [t[1], t[3], t[0]].map(\.id))
    }

    /// A pinned row and a tab picked, the row carried down under the line:
    /// it is unpinned there, the tab beside it, in the order they had.
    func testPickedPinsAndTabsGoBelowTheLineTogether() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        for tab in t[0...1] { browser.pin(tab, listed: true) }
        pick([t[0], t[3]], in: browser)
        let window = makeWindow(browser)
        try await ready(browser)
        // As above; "one" carried down among the tabs, in front of five.
        try await carry(from: 14, to: 100, in: window)
        try await settle()
        XCTAssertEqual(browser.listedPins.map(\.id), [t[1].id])
        XCTAssertEqual(browser.tabs.filter { $0.pin == nil }.map(\.id), [t[2], t[0], t[3], t[4]].map(\.id))
    }

    /// A pinned row and a tab picked, the tab carried onto the squares:
    /// both squares, in the order they had.
    func testPickedPinsAndTabsGoOntoTheSquaresTogether() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.pin(t[0])
        browser.pin(t[1], listed: true)
        pick([t[1], t[3]], in: browser)
        let window = makeWindow(browser)
        try await ready(browser)
        // The grid 0–34 and 10 under it; two 44–72; the line 74–92; three
        // 94–122, four 124–152, five 154–182.
        let room = browser.prefs.sideWidth - 20
        let x = 10 + room * 5 / 6
        try await send(.leftMouseDown, at: pins(x, 138, in: window), in: window)
        for y in stride(from: CGFloat(136), through: 17, by: -2) {
            try await send(.leftMouseDragged, at: pins(x, y, in: window), in: window)
        }
        try await send(.leftMouseUp, at: pins(x, 17, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.squarePins.map(\.id), [t[0], t[1], t[3]].map(\.id))
        XCTAssertTrue(browser.listedPins.isEmpty)
    }

    /// Two tabs picked, one a page the phone has open already: carried
    /// onto the phone's group, it opens a gap there all the same, as the
    /// other can go; let go, the other goes, nothing said of it, and why
    /// the first didn't is. Both stay here.
    func testPickedTabsGoToADeviceThatTakesAnyOfThem() async throws {
        let browser = makeBrowser()
        let wasOn = Sync.shared.on
        addTeardownBlock { @MainActor in Sync.shared.pretend([], on: wasOn) }
        Sync.shared.pretend([DeviceTabs(device: "phone", name: "Phone", kind: .iphone,
                                        tabs: [DeviceTabs.Page(url: "https://a.phone.invalid/", title: "", space: nil)], at: 0)],
                            on: true)
        let t = browser.tabs
        t[3].restore(url: try XCTUnwrap(URL(string: "https://a.phone.invalid/")), title: "four")
        t[4].restore(url: try XCTUnwrap(URL(string: "https://five.invalid/")), title: "five")
        pick([t[3], t[4]], in: browser)
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // The phone's group, folded, 0–28; the line 30–48; one 50–78 …
        // five 170–198. "four", which the phone has open, carried onto it.
        try await carry(from: 154, to: 14, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.device, "phone", "taken, for the other")
        try await send(.leftMouseUp, at: point(y: 14, in: window), in: window)
        try await settle()
        let phone = try XCTUnwrap(Sync.shared.devicesWithTabs.first { $0.device == "phone" })
        XCTAssertTrue(phone.tabs.contains { $0.url == "https://five.invalid/" }, "the other sent")
        XCTAssertEqual(phone.tabs.filter { $0.url == "https://a.phone.invalid/" }.count, 1, "never twice")
        XCTAssertEqual(browser.announcement, "Already open on Phone")
        XCTAssertEqual(browser.tabs.map(\.id), t.map(\.id), "both kept here")
    }

    /// Two tabs picked, one carried up onto the squares: both squares.
    func testPickedTabsGoOntoTheSquaresTogether() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.pin(t[0])
        browser.select(t[2])
        browser.extendTabSelection(to: t[3], modifiers: [.command])
        let window = makeWindow(browser)
        try await ready(browser)
        // The grid 0–34 and 10 under it; the line 44–62; two 64–92, three
        // 94–122, four 124–152, five 154–182.
        let room = browser.prefs.sideWidth - 20
        let x = 10 + room * 5 / 6
        try await send(.leftMouseDown, at: pins(x, 138, in: window), in: window)
        for y in stride(from: CGFloat(136), through: 17, by: -2) {
            try await send(.leftMouseDragged, at: pins(x, y, in: window), in: window)
        }
        try await send(.leftMouseUp, at: pins(x, 17, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.squarePins.map(\.id), [t[0], t[2], t[3]].map(\.id), "both squares, in order")
    }

    /// Two tabs picked, one dragged out over another window: both go there,
    /// in their order, the one carried in front.
    func testPickedTabsLeaveTheWindowTogether() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        let window = makeWindow(browser)
        browser.window = window
        let other = Browser(record: WindowRecord(space: browser.spaceID))
        browsers.append(other)
        let otherWindow = NSWindow(contentRect: NSRect(x: -16_000, y: -20_000, width: 600, height: 400),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        windows.append(otherWindow)
        other.window = otherWindow
        Browsers.register(other)
        defer { Browsers.discard(other) }
        browser.select(t[1])
        browser.extendTabSelection(to: t[3], modifiers: [.command])
        XCTAssertTrue(browser.dragOut(t[3], at: NSPoint(x: -15_700, y: -19_800)), "let go over the other window")
        try await settle()
        XCTAssertFalse(browser.tabs.contains { $0.id == t[1].id || $0.id == t[3].id }, "both gone from here")
        let moved = other.tabs.filter { $0.id == t[1].id || $0.id == t[3].id }.map(\.id)
        XCTAssertEqual(moved, [t[1], t[3]].map(\.id), "both there, in order")
        XCTAssertEqual(other.activeID, t[3].id, "the one carried in front")
    }

    // MARK: - the close mark

    /// A split's half says what closing it does as a row does: a minus,
    /// Put Away, for a grouped page; a cross, Close Tab, otherwise. Its named
    /// action is VoiceOver's.
    func testASplitHalfShowsAMinusWhereItsPageIsPutAway() async throws {
        speaking()
        let browser = makeBrowser()
        browser.prefs.usesTabGroups = true
        let t = browser.tabs
        let group = browser.addTabGroup(containing: t[1])
        browser.move(t[2], toGroup: group)
        browser.editingGroupID = nil
        browser.pair(t[2], with: t[1], onLeft: false)
        // Each with a page open, to put away.
        for tab in [t[0], t[1], t[3], t[4]] { browser.select(tab) }
        XCTAssertTrue(browser.putsAway(t[1]))
        XCTAssertEqual(CloseMark.of(t[1], putsAway: browser.putsAway(t[1])), .putAway)
        XCTAssertEqual(CloseMark.putAway.symbol, "minus")
        XCTAssertEqual(CloseMark.of(t[3], putsAway: browser.putsAway(t[3])), .close)
        XCTAssertEqual(CloseMark.close.symbol, "xmark")
        browser.pin(t[0])
        XCTAssertEqual(CloseMark.of(t[0], putsAway: false), .putDown)
        XCTAssertEqual(CloseMark.putDown.symbol, "minus")

        let window = makeWindow(browser)
        try await ready(browser)
        let half = try XCTUnwrap(element(named: t[1].label, in: window), "the half, to VoiceOver")
        XCTAssertTrue(actions(of: half).contains("Put Away"), "named as its mark: \(actions(of: half))")
        XCTAssertFalse(actions(of: half).contains("Close Tab"))
    }

    // MARK: - the column's own menu

    /// The New Tab row, the line and the room under the tabs: one menu,
    /// New Group only with groups on, Clear Tabs only with tabs to clear.
    func testTheColumnsMenuOffersWhatCanBeMade() async throws {
        let browser = makeBrowser()
        func titles(clears: Bool) -> [String] {
            ColumnMenu.make(for: browser, clears: clears).items.filter { !$0.isSeparatorItem }.map(\.title)
        }
        browser.prefs.usesTabGroups = false
        XCTAssertEqual(titles(clears: false), ["New Tab", "New Folder"])
        browser.prefs.usesTabGroups = true
        XCTAssertEqual(titles(clears: true), ["New Tab", "New Group", "New Folder", "Clear Tabs"])

        // New Folder, from the menu, makes one.
        let menu = ColumnMenu.make(for: browser, clears: true)
        let folder = try XCTUnwrap(menu.items.first { $0.title == "New Folder" })
        let before = browser.keptGroups.count
        menu.performActionForItem(at: menu.index(of: folder))
        XCTAssertEqual(browser.keptGroups.count, before + 1)
        browser.editingGroupID = nil

        // The room under the tabs has it on a right-click.
        let window = makeWindow(browser)
        try await ready(browser)
        let empty = NSPoint(x: 100, y: 40)
        let strip = try XCTUnwrap(window.contentView?.hitTest(empty), "the room under the tabs")
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: empty, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let offered = strip.menu(for: click)?.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(offered, ["New Tab", "New Group", "New Folder", "Clear Tabs"])
    }

    // MARK: - VoiceOver

    /// A row and a square each one thing to VoiceOver, named by its page:
    /// pressed, it goes to the tab; its close mark is a named action.
    func testRowsAndSquaresHaveActions() async throws {
        speaking()
        let browser = makeBrowser()
        let t = browser.tabs
        browser.pin(t[0])
        browser.pin(t[1], listed: true)
        // Their pages open, so each is put down rather than deleted.
        for tab in [t[0], t[1], t[4]] { browser.select(tab) }
        let window = makeWindow(browser)
        try await ready(browser)

        let row = try XCTUnwrap(element(named: t[2].label, in: window), "the row, to VoiceOver")
        XCTAssertTrue(actions(of: row).contains("Close Tab"), "\(actions(of: row))")
        XCTAssertTrue(actions(of: row).contains("Show Menu"), "its menu reachable")
        XCTAssertFalse(actions(of: row).contains("Mute Tab"), "no speaker, no mute")
        XCTAssertTrue(press(row))
        try await settle()
        XCTAssertEqual(browser.activeID, t[2].id, "pressed, it goes there")

        let pinned = try XCTUnwrap(element(named: t[1].label, in: window), "the pinned row")
        XCTAssertTrue(actions(of: pinned).contains("Put Down"), "\(actions(of: pinned))")

        let square = try XCTUnwrap(element(named: t[0].label, in: window), "the square")
        XCTAssertTrue(actions(of: square).contains("Put Down"), "\(actions(of: square))")
        XCTAssertTrue(actions(of: square).contains("Show Menu"))
        XCTAssertTrue(press(square))
        try await settle()
        XCTAssertEqual(browser.activeID, t[0].id)
    }

    // MARK: - helpers

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.usesTabGroups, prefs.splitView, prefs.roomyTabs, prefs.newTabPlace,
                        prefs.sharesPins, prefs.glyph, prefs.pinCommandOpensTab, prefs.tabsGive)
        restorePreferences = {
            (prefs.usesTabGroups, prefs.splitView, prefs.roomyTabs, prefs.newTabPlace,
             prefs.sharesPins, prefs.glyph, prefs.pinCommandOpensTab, prefs.tabsGive) = previous
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = true
        browser.prefs.roomyTabs = false
        browser.prefs.sharesPins = false
        browser.prefs.glyph = .letters
        browser.prefs.pinCommandOpensTab = false
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

    /// `tabs` picked, as ⌘-clicks pick them, and nothing else: the tab in
    /// front, which the first ⌘-click picks too, is one of the others, and
    /// is let go of again.
    private func pick(_ tabs: [Eden.Tab], in browser: Browser) {
        browser.clearTabSelection()
        if let active = browser.active, tabs.contains(where: { $0 === active }),
           let other = browser.tabs.first(where: { tab in !tabs.contains { $0 === tab } }) {
            browser.select(other)
        }
        for tab in tabs { browser.extendTabSelection(to: tab, modifiers: [.command]) }
        if let active = browser.active, !tabs.contains(where: { $0 === active }),
           browser.selectedTabIDs.contains(active.id) {
            browser.extendTabSelection(to: active, modifiers: [.command])
        }
        XCTAssertEqual(browser.selectedTabIDs, Set(tabs.map(\.id)))
    }

    /// A point down the rows, from their top, in the window's terms.
    private func point(y: CGFloat, in window: NSWindow) -> NSPoint {
        NSPoint(x: 70, y: window.frame.height - Metrics.columnTop - y)
    }

    /// A point from the top of the squares, or of the rows with none.
    private func pins(_ x: CGFloat, _ y: CGFloat, in window: NSWindow) -> NSPoint {
        NSPoint(x: x, y: window.frame.height - Metrics.columnTop - y)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    /// Settled, and no page loading: a row or a square changing under the
    /// hand as its page loads calls SwiftUI's drag off (see CarryGuard).
    private func ready(_ browser: Browser) async throws {
        try await settle()
        let deadline = Date().addingTimeInterval(5)
        while browser.tabs.contains(where: \.loading), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await settle()
    }

    private func carry(from start: CGFloat, to end: CGFloat, in window: NSWindow,
                       letGo: Bool = true, pressing: Bool = true) async throws {
        if pressing { try await send(.leftMouseDown, at: point(y: start, in: window), in: window) }
        let step: CGFloat = end < start ? -2 : 2
        for y in stride(from: start + step, through: end, by: step) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        if letGo { try await send(.leftMouseUp, at: point(y: end, in: window), in: window) }
    }

    /// Through the app, as a real event comes (see RowCarryTests.send).
    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        NSApp.postEvent(event, atStart: true)
        let queued = try XCTUnwrap(NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true))
        NSApp.sendEvent(queued)
        try await Task.sleep(for: .milliseconds(30))
    }

    /// The first thing in the window VoiceOver would read as `label`.
    /// SwiftUI's nodes answer the accessibility methods without saying
    /// they take the protocol, so they are asked by name.
    private func element(named label: String, in window: NSWindow) -> AnyObject? {
        func search(_ node: AnyObject, depth: Int) -> AnyObject? {
            guard depth < 40 else { return nil }
            if node.accessibilityLabel?() == label { return node }
            for child in (node.accessibilityChildren?() ?? nil) ?? [] {
                if let found = search(child as AnyObject, depth: depth + 1) { return found }
            }
            return nil
        }
        return window.contentView.flatMap { search($0, depth: 0) }
    }

    /// The named actions VoiceOver offers on `element`.
    private func actions(of element: AnyObject) -> [String] {
        ((element.accessibilityCustomActions?() ?? nil) ?? []).map(\.name)
    }

    /// VoiceOver's press on `element`: true when it was taken.
    private func press(_ element: AnyObject) -> Bool {
        element.accessibilityPerformPress?() == true
    }

    /// SwiftUI builds what VoiceOver reads only once something asks for
    /// it, as VoiceOver does by turning this on; off again once done.
    private func speaking() {
        func enhanced(_ on: Bool) {
            _ = NSApplication.shared.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: on),
                              with: "AXEnhancedUserInterface" as NSString)
        }
        enhanced(true)
        addTeardownBlock { @MainActor in enhanced(false) }
    }
}
