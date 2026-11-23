import AppKit
import SwiftUI
import XCTest
@testable import Eden

@MainActor
final class SidebarPressTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        // Pins are kept for the space in every window (Pins.swift): put
        // down, or the next test's window would hold them too, its rows
        // under their grid.
        for browser in browsers {
            browser.cancelTabEdit()
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
        }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await settle()
        try await super.tearDown()
    }

    override class func setUp() {
        setenv("EDEN_PROBE", "sidebar-press-\(getpid())", 1)
        super.setUp()
    }

    /// From a space as a new install has it, whatever the suites before
    /// left in this process's world (CleanWorld).
    override func setUp() async throws {
        try await super.setUp()
        CleanWorld.reset()
    }

    func testSelectsOnPressWithoutEditingOnRelease() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let point = rowPoint(0, in: window)
        try await send(.leftMouseDown, at: point, in: window)
        XCTAssertEqual(browser.activeID, first.id, "The page must change while the button is held")
        XCTAssertNil(browser.editingTab)
        try await send(.leftMouseUp, at: point, in: window)
        XCTAssertNil(browser.editingTab, "Releasing the selecting press must not edit the address")
        try await send(.leftMouseDown, at: point, in: window)
        try await send(.leftMouseUp, at: point, in: window)
        XCTAssertEqual(browser.editingTab, first.id, "A fresh click on the active row still edits")
    }

    func testEditedRowTakesTheKeys() async throws {
        let browser = makeBrowser()
        let window = makeWindow(browser)
        try await settle()
        let point = rowPoint(0, in: window)
        for _ in 0..<2 {
            try await send(.leftMouseDown, at: point, in: window)
            try await send(.leftMouseUp, at: point, in: window)
        }
        try await settle()
        XCTAssertEqual(browser.editingTab, browser.tabs[0].id)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "The row's field must have the keys")
        XCTAssertEqual(editor.selectedRange().length, (editor.string as NSString).length)
        XCTAssertFalse(editor.string.isEmpty)
    }

    func testRowLeftPickedAloneSelectsOnPressAgain() async throws {
        let browser = makeBrowser()
        let active = try XCTUnwrap(browser.active)
        let index = try XCTUnwrap(browser.shownTabs.firstIndex { $0.id != active.id })
        let other = browser.shownTabs[index]
        let window = makeWindow(browser)
        try await settle()
        // ⌘ picks it along with the tab you're on.
        browser.extendTabSelection(to: other, modifiers: .command)
        try await settle()
        XCTAssertTrue(browser.isPickedAmongOthers(other))
        // Still picked, but alone now: its row's press is a plain press again.
        browser.extendTabSelection(to: active, modifiers: .command)
        try await settle()
        XCTAssertEqual(browser.selectedTabIDs, [other.id])
        XCTAssertFalse(browser.isPickedAmongOthers(other))
        let point = rowPoint(index, in: window)
        try await send(.leftMouseDown, at: point, in: window)
        XCTAssertEqual(browser.activeID, other.id, "The page must change while the button is held")
        try await send(.leftMouseUp, at: point, in: window)
    }

    func testPressThenDragStillReordersWithoutEditing() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let start = rowPoint(0, in: window)
        try await send(.leftMouseDown, at: start, in: window)
        XCTAssertEqual(browser.activeID, first.id)
        for distance in [8.0, 20, 40, 60] {
            try await send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - distance), in: window)
        }
        try await send(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - 60), in: window)
        try await settle()
        XCTAssertEqual(browser.tabs.last?.id, first.id)
        XCTAssertNil(browser.editingTab)
    }

    func testSiblingControlsDoNotSelectTheRow() async throws {
        _ = NSApplication.shared
        var selected = 0
        var muted = 0
        var closed = 0
        let window = makeWindow(root: ControlsFixture(select: { selected += 1 }, mute: { muted += 1 }, close: { closed += 1 }))
        try await settle()
        for x in [200.0, 235] {
            let point = NSPoint(x: x, y: 20)
            try await send(.leftMouseDown, at: point, in: window)
            XCTAssertEqual(selected, 0)
            try await send(.leftMouseUp, at: point, in: window)
        }
        XCTAssertEqual(muted, 1)
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(selected, 0)
    }

    func testPinSelectsOnPressAndStillDoubleClicks() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        browser.pin(first)
        let window = makeWindow(browser)
        try await settle()
        let point = NSPoint(x: 40, y: window.frame.height - Metrics.strip - 17)
        try await send(.leftMouseDown, at: point, in: window)
        XCTAssertEqual(browser.activeID, first.id)
        try await send(.leftMouseUp, at: point, in: window)
        XCTAssertNil(browser.editingPin)
        try await send(.leftMouseDown, at: point, in: window)
        try await send(.leftMouseUp, at: point, in: window)
        try await send(.leftMouseDown, at: point, in: window, clicks: 2)
        try await send(.leftMouseUp, at: point, in: window, clicks: 2)
        XCTAssertEqual(browser.editingPin, first.id, "A pin already home still edits its letter on double-click")
    }

    func testEachSplitHalfFocusesOnPressWithoutEditingOnRelease() async throws {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.prefs.splitView = true
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.select(tabs[2])
        let window = makeWindow(browser)
        try await settle()
        for index in [0, 1] {
            let point = NSPoint(x: 70, y: window.frame.height - Metrics.strip - 14 - CGFloat(index) * 28)
            try await send(.leftMouseDown, at: point, in: window)
            XCTAssertEqual(browser.activeID, tabs[index].id)
            try await send(.leftMouseUp, at: point, in: window)
            XCTAssertNil(browser.editingTab)
        }
    }

    func testSplitPaddingClickAfterEarlierSelectionIsNotSuppressed() async throws {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.prefs.splitView = true
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.select(tabs[2])
        let window = makeWindow(browser)
        try await settle()
        let title = rowPoint(0, in: window)
        try await send(.leftMouseDown, at: title, in: window)
        try await send(.leftMouseUp, at: title, in: window)
        browser.select(tabs[2])
        try await settle()
        let padding = NSPoint(x: 14, y: title.y)
        try await send(.leftMouseDown, at: padding, in: window)
        XCTAssertEqual(browser.activeID, tabs[0].id, "The leading padding must also select on press")
        try await send(.leftMouseUp, at: padding, in: window)
        XCTAssertEqual(browser.activeID, tabs[0].id)
    }

    func testSmallPointerMovementDoesNotTurnSelectionIntoEditing() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let start = rowPoint(0, in: window)
        let end = NSPoint(x: start.x + 1, y: start.y)
        try await send(.leftMouseDown, at: start, in: window)
        try await send(.leftMouseDragged, at: end, in: window)
        try await send(.leftMouseUp, at: end, in: window)
        XCTAssertEqual(browser.activeID, first.id)
        XCTAssertNil(browser.editingTab)
    }

    // What else a press in the column does, checked when it landed (#625).

    func testPressOnTheCrossLeavesTheRowAlone() async throws {
        // The cross is there only under the pointer (onHover), which a
        // hidden test gives the row through the bench (Bench.hoverRows), as
        // IconColumnTests does. Under it, its place at the end of the row
        // takes the press, so the row isn't selected under a click meant for
        // the cross, and the click closes the tab. (Before, the cross's reach
        // took a press with no pointer on the row too, and the test pressed
        // there unhovered; since the cross became one that wears its square
        // under the pointer, its reach comes and goes with it.) The press
        // goes through the app, as a real one does: the cross takes it as
        // a split's half's does (CloseClick), by the event AppKit is
        // delivering, which one sent straight to the window isn't (#41).
        let browser = makeBrowser()
        let first = browser.tabs[0], second = browser.tabs[1], before = browser.activeID
        XCTAssertNotEqual(before, first.id)
        XCTAssertNotEqual(before, second.id)
        let window = makeWindow(browser)
        try await settle()
        Bench.hoverRows[first.id]?(true)
        try await settle()
        let cross = NSPoint(x: browser.prefs.sideWidth - 24, y: rowPoint(0, in: window).y)
        try await post(.leftMouseDown, at: cross, in: window)
        XCTAssertEqual(browser.activeID, before, "A press on the cross must not select its row")
        try await post(.leftMouseUp, at: cross, in: window)
        try await settle()
        XCTAssertEqual(browser.activeID, before)
        XCTAssertFalse(browser.tabs.contains { $0 === first }, "its click closes the tab")
        // The next row, now the first, still selects on press.
        let title = rowPoint(0, in: window)
        try await send(.leftMouseDown, at: title, in: window)
        XCTAssertEqual(browser.activeID, second.id, "The rest of the row still selects on press")
        try await send(.leftMouseUp, at: title, in: window)
    }

    /// The line comes with the first thing kept, a square alone with no
    /// tab under it too, and goes with the last.
    func testTheLineShowsWhileSomethingIsKeptAboveIt() async throws {
        let browser = makeBrowser()
        let window = makeWindow(browser)
        try await settle()
        XCTAssertEqual(KeepLine.drawn, 0, "nothing kept: no line")
        for tab in browser.tabs { browser.pin(tab) }
        try await settle()
        XCTAssertTrue(browser.tabs.allSatisfy { $0.pin != nil })
        XCTAssertEqual(KeepLine.drawn, 1, "squares alone, no tab under them: the line")
        for tab in browser.tabs { browser.unpin(tab) }
        // Settled twice: the line fades out before it is gone.
        try await settle()
        try await settle()
        XCTAssertEqual(KeepLine.drawn, 0, "nothing kept again: no line")
        _ = window
    }

    /// One line between what is kept and the tabs (#6): with new tabs
    /// going to the top, the New Tab row comes straight under the line, the
    /// line under the pins, and no second line under the New Tab row.
    func testTheNewTabRowIsUnderTheOneLine() async throws {
        let browser = makeBrowser()
        browser.prefs.newTabPlace = .top
        browser.pin(browser.tabs[0])
        let before = browser.tabs.count
        let window = makeWindow(browser)
        try await settle()
        XCTAssertEqual(KeepLine.drawn, 1, "one line")
        // The grid, 34 and 10 under it, then the line: New tab.
        let y = window.frame.height - Metrics.strip - 44 - KeepLine.height - SideBar.gap - 14
        try await send(.leftMouseDown, at: NSPoint(x: 70, y: y), in: window)
        try await send(.leftMouseUp, at: NSPoint(x: 70, y: y), in: window)
        try await settle()
        XCTAssertTrue(browser.launching || browser.tabs.count > before, "New tab, under the line")
        if browser.launching { browser.launch() }
    }

    func testRenameFieldKeepsItsClicks() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        browser.select(first)
        let window = makeWindow(browser)
        try await settle()
        browser.beginTabRename(first)
        try await settle()
        // The field's own press waits in a loop for its release from the
        // queue: the release is queued first, in this process only.
        let point = rowPoint(0, in: window)
        NSApp.postEvent(try event(.leftMouseUp, at: point, in: window), atStart: false)
        window.sendEvent(try event(.leftMouseDown, at: point, in: window))
        try await settle()
        XCTAssertEqual(browser.editingTab, first.id, "A click in the name field keeps the rename open")
        XCTAssertTrue(browser.renamingTab)
        XCTAssertEqual(browser.activeID, first.id)
        browser.tabDraft = "Renamed"
        browser.commitTabEdit()
        XCTAssertEqual(first.name, "Renamed")
    }

    func testOtherButtonsDoNotSelectOnPress() async throws {
        _ = NSApplication.shared
        var selected = 0
        let window = makeWindow(root: ControlsFixture(select: { selected += 1 }, mute: {}, close: {}))
        try await settle()
        let point = NSPoint(x: 60, y: 20)
        // Through the app's own queue, as a real click comes: which button
        // went down is the event's, and only an event the app took off its
        // queue says so.
        for (down, up) in [(NSEvent.EventType.rightMouseDown, NSEvent.EventType.rightMouseUp),
                           (.otherMouseDown, .otherMouseUp)] {
            try await post(down, at: point, in: window)
            try await post(up, at: point, in: window)
        }
        XCTAssertEqual(selected, 0, "Only the left button selects on press; right-click stays the menu's")
    }

    func testPinDragStillReorders() async throws {
        let browser = makeBrowser()
        let (first, second) = (browser.tabs[0], browser.tabs[1])
        browser.pin(first)
        browser.pin(second)
        let window = makeWindow(browser)
        try await settle()
        let start = NSPoint(x: 40, y: window.frame.height - Metrics.strip - 17)
        try await send(.leftMouseDown, at: start, in: window)
        XCTAssertEqual(browser.activeID, first.id)
        for distance in [8.0, 20, 40, 60, 80] {
            try await send(.leftMouseDragged, at: NSPoint(x: start.x + distance, y: start.y), in: window)
        }
        try await send(.leftMouseUp, at: NSPoint(x: start.x + 80, y: start.y), in: window)
        try await settle()
        XCTAssertEqual(browser.tabs.prefix(2).map(\.id), [second.id, first.id], "A pin carried past the next swaps with it")
        XCTAssertNil(browser.editingPin)
    }

    /// The press that selects (TabPress) held the drag back until the
    /// release: nothing moved under the hand, the row jumped on letting go,
    /// and a pin held still a moment before letting go wasn't moved at all.
    func testRowsAndPinsMoveWhileTheButtonIsDown() async throws {
        for kind in ["row", "pin"] {
            let browser = makeBrowser()
            let tabs = browser.tabs
            if kind == "pin" { browser.pin(tabs[0]); browser.pin(tabs[1]) }
            let window = makeWindow(browser)
            try await settle()
            let before = browser.tabs.map(\.id)
            let start = kind == "pin" ? NSPoint(x: 40, y: window.frame.height - Metrics.strip - 17) : rowPoint(0, in: window)
            try await send(.leftMouseDown, at: start, in: window)
            var last = start
            for distance in [8.0, 20, 40, 60, 80] {
                last = kind == "pin" ? NSPoint(x: start.x + distance, y: start.y) : NSPoint(x: start.x, y: start.y - distance * 0.8)
                try await send(.leftMouseDragged, at: last, in: window)
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNotEqual(browser.tabs.map(\.id), before, "\(kind): moved while the button is still down")
            // Held still a little, then let go (not long: a window off the
            // screen gets no real button, and a pin's tooltip ends the drag).
            try await Task.sleep(for: .milliseconds(150))
            try await send(.leftMouseUp, at: last, in: window)
            try await settle()
            XCTAssertNotEqual(browser.tabs.map(\.id), before, "\(kind): still moved once let go")
            XCTAssertNil(browser.editingTab)
            XCTAssertNil(browser.editingPin)
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
        }
    }

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
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = false
        browser.prefs.roomyTabs = false
        // Each new tab after the last, so they stand in the order made and
        // the rows start at the column's top, the New Tab row under them:
        // new tabs go to the top unless told otherwise, and a second blank
        // one there would be the first one reused.
        browser.prefs.newTabPlace = .next
        for word in ["one", "two", "three"] {
            if browser.tabs.last?.isBlank != true { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        makeWindow(root: SideBar(browser: browser, prefs: browser.prefs), width: browser.prefs.sideWidth, height: 500)
    }

    private func makeWindow<V: View>(root: V, width: CGFloat = 250, height: CGFloat = 40) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private func rowPoint(_ index: Int, in window: NSWindow) -> NSPoint {
        NSPoint(x: 70, y: window.frame.height - Metrics.strip - 14 - CGFloat(index) * 30)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    /// As PinStuckTests posts: to this app alone, taken off the queue here.
    private func post(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        NSApp.postEvent(try event(type, at: point, in: window), atStart: false)
        // Until this one is through, however many are queued before it:
        // what earlier tests left on the queue (their windows' AppKit events,
        // forty and more by this point of a full run) ran past a count of
        // twenty, and the press was never sent.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            guard let queued = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.2),
                                               inMode: .default, dequeue: true) else { break }
            NSApp.sendEvent(queued)
            if queued.type == type, queued.window === window { break }
        }
        try await Task.sleep(for: .milliseconds(30))
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1) async throws {
        window.sendEvent(try event(type, at: point, in: window, clicks: clicks))
        try await Task.sleep(for: .milliseconds(30))
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }
}

private struct ControlsFixture: View {
    let select: () -> Void
    let mute: () -> Void
    let close: () -> Void
    @State private var selected = false

    var body: some View {
        HStack(spacing: 0) {
            Text("Tab").frame(width: 185, height: 40)
                .contentShape(Rectangle())
                .modifier(TabPress(enabled: true, active: false, selected: $selected, act: select))
            Button(action: mute) { Text("Mute").frame(width: 35, height: 40) }
                .buttonStyle(.plain)
            Color.clear.frame(width: 30, height: 40)
        }
        .overlay(alignment: .trailing) {
            Color.clear.frame(width: 30, height: 40).contentShape(Rectangle()).onTapGesture(perform: close)
        }
    }
}
