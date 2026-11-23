import AppKit
import EdenCore
import WebKit
import XCTest
@testable import Eden

/// chrome.tabs.move as the browser answers it, where WebKit's own says it
/// isn't implemented (the shim's own move, ExtensionShims "tabs.move"): a
/// tab to its place in the row, pins kept among pins, and only the tabs
/// that moved told as moved (Extensions.moved).
@available(macOS 15.4, *)
@MainActor
final class ExtensionTabsMoveTests: XCTestCase {
    private var browser: Browser?
    private var folder: URL?
    private var place: NewTabPlace?

    override class func setUp() {
        setenv("EDEN_PROBE", "tabs-move-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        CleanWorld.reset()
    }

    override func tearDown() async throws {
        if let browser {
            Browsers.discard(browser)
            browser.closeAll()
            CleanWorld.reset(space: browser.spaceID)
        }
        browser = nil
        if let place { Shared.prefs.newTabPlace = place }
        if let folder { try? FileManager.default.removeItem(at: folder) }
        try await super.tearDown()
    }

    func testOnlyTheTabsThatMovedAreTold() {
        let ids = (0..<6).map { _ in UUID() }
        XCTAssertEqual(Extensions.moved(from: ids, to: ids), [])
        // One tab from the end to the front passed five: one move.
        XCTAssertEqual(Extensions.moved(from: ids, to: [ids[5]] + ids[0..<5]), [ids[5]])
        XCTAssertEqual(Extensions.moved(from: ids, to: Array(ids[1...]) + [ids[0]]), [ids[0]])
        // Two swapped far apart: two moves.
        var swapped = ids
        swapped.swapAt(1, 4)
        XCTAssertEqual(Set(Extensions.moved(from: ids, to: swapped)), [ids[1], ids[4]])
    }

    func testATabMovesToItsPlaceAndStaysAfterThePins() async throws {
        let browser = makeBrowser()
        for word in ["a", "b", "c"] {
            browser.newTab()
            browser.tabs.last?.restore(url: try XCTUnwrap(URL(string: "https://\(word).example/")), title: word)
        }
        let pinned = try XCTUnwrap(browser.tabs.first { $0.title == "a" })
        browser.pin(pinned, listed: true)
        let context = try await extensionContext()
        func row() -> [String] { browser.tabs.filter { !$0.isBlank }.map(\.title) }
        func place(_ title: String) throws -> Int {
            try XCTUnwrap(Extensions.shared.visibleRows(of: browser, for: context).firstIndex { $0.tab?.title == title })
        }
        func move(_ title: String, to index: Int) async throws {
            let reply = try await ExtensionShims.answer(["api": "tabs.move", "args": [try place(title), index]],
                                                        from: context, owner: Extensions.shared) as? [String: Any]
            XCTAssertNil(reply?["error"], "\(String(describing: reply))")
        }
        XCTAssertEqual(row().first, "a", "the pin first")
        try await move("c", to: 0)
        XCTAssertEqual(row().prefix(2), ["a", "c"], "to the front of the tabs: after the pin, which keeps the head")
        try await move("c", to: -1)
        XCTAssertEqual(row().last, "c", "-1: the end")
        try await move("a", to: -1)
        XCTAssertEqual(row().first, "a", "a pin stays among the pins")
    }

    /// Several tabs in one call, as the shim's moveTabs moves them: each to
    /// the place asked of it, then the next to the place after where that
    /// one landed (-1: each to the end), as the extensions API does. So two
    /// moved forward together don't stay together: [A, B, C, D], A and B to
    /// 2, is [C, A, D, B]. held_pins_extension.py moves them through the
    /// shim itself.
    func testSeveralTabsMoveEachAfterTheOneBefore() async throws {
        let browser = makeBrowser()
        let words = ["a", "b", "c", "d"]
        for word in words {
            browser.newTab()
            browser.tabs.last?.restore(url: try XCTUnwrap(URL(string: "https://\(word).example/")), title: word)
        }
        let context = try await extensionContext()
        func row() -> [String] { browser.tabs.filter { !$0.isBlank }.map(\.title) }
        func place(_ title: String) throws -> Int {
            try XCTUnwrap(Extensions.shared.visibleRows(of: browser, for: context).firstIndex { $0.tab?.title == title })
        }
        // Any blank tab the window opened with stands ahead of them.
        let base = try place("a")
        func move(_ titles: [String], to index: Int) async throws {
            var at = index == -1 ? -1 : base + index
            for title in titles {
                let reply = try await ExtensionShims.answer(["api": "tabs.move", "args": [try place(title), at]],
                                                            from: context, owner: Extensions.shared) as? [String: Any]
                XCTAssertNil(reply?["error"], "\(String(describing: reply))")
                if at != -1 { at = try place(title) + 1 }
            }
        }
        func arrange() async throws {
            for (n, word) in words.enumerated() { try await move([word], to: n) }
            XCTAssertEqual(row(), words)
        }

        try await arrange()
        try await move(["a", "b"], to: 2)
        XCTAssertEqual(row(), ["c", "a", "d", "b"], "forward")
        try await arrange()
        try await move(["c", "d"], to: 0)
        XCTAssertEqual(row(), ["c", "d", "a", "b"], "backward")
        try await arrange()
        try await move(["d", "a"], to: 1)
        XCTAssertEqual(row(), ["d", "b", "a", "c"], "one back, one forward")
        try await arrange()
        try await move(["a", "b"], to: -1)
        XCTAssertEqual(row(), ["c", "d", "a", "b"], "-1: each to the end")
    }

    /// An extension's move moves the tab it names, not the tabs picked with
    /// it in the column, which a drag of it would carry; they stay picked.
    func testOnlyTheTabNamedMovesWithOthersPicked() async throws {
        let browser = makeBrowser()
        let tabs = try pages(["a", "b", "c", "d"], in: browser)
        let context = try await extensionContext()
        browser.select(tabs[0])
        browser.extendTabSelection(to: tabs[1], modifiers: .command)
        let picked = browser.selectedTabIDs
        XCTAssertEqual(picked, [tabs[0].id, tabs[1].id])
        let base = try place("a", in: browser, for: context)
        try await move("a", to: base + 2, in: browser, for: context)
        XCTAssertEqual(row(browser), ["b", "c", "a", "d"], "a alone")
        XCTAssertEqual(browser.selectedTabIDs, picked, "the pick as it was")
    }

    /// A page of a split moved by an extension takes the split with it, as
    /// a drag of that page alone does; a tab moved past a split goes past
    /// the whole of it, which stays a split.
    func testATabOfASplitMovesWithItsSplit() async throws {
        let browser = makeBrowser()
        let tabs = try pages(["a", "b", "c", "d"], in: browser)
        let split = browser.prefs.splitView
        browser.prefs.splitView = true
        defer { browser.prefs.splitView = split }
        browser.pair(tabs[2], with: tabs[1], onLeft: false)
        XCTAssertEqual(browser.split(for: tabs[1])?.tabs, [tabs[1].id, tabs[2].id])
        let context = try await extensionContext()
        let base = try place("a", in: browser, for: context)
        try await move("c", to: base, in: browser, for: context)
        XCTAssertEqual(row(browser), ["b", "c", "a", "d"], "c with b, its split")
        try await move("a", to: base + 3, in: browser, for: context)
        XCTAssertEqual(row(browser), ["b", "c", "d", "a"])
        // To its own partner's place: where the split already is, done.
        try await move("c", to: base, in: browser, for: context)
        XCTAssertEqual(row(browser), ["b", "c", "d", "a"])
        XCTAssertEqual(browser.split(for: tabs[1])?.tabs, [tabs[1].id, tabs[2].id], "still a split")
    }

    /// With groups on, a tab an extension moves lands at the place asked
    /// and takes the group of where it lands, as the extensions API has it:
    /// out of its group's span it leaves the group, forward or back; between
    /// two tabs of a group it joins it; at a group's edge it stays in none;
    /// several, each the same. The column's own drags are left as they are.
    func testAnExtensionsMoveTakesTheGroupOfWhereItLands() async throws {
        let browser = makeBrowser()
        let groups = browser.prefs.usesTabGroups
        browser.prefs.usesTabGroups = true
        defer { browser.prefs.usesTabGroups = groups }
        let tabs = try pages(["a", "b", "c", "d", "e"], in: browser)
        let g = browser.addTabGroup(containing: tabs[0])
        browser.editingGroupID = nil
        browser.move(tabs[1], toGroup: g)
        browser.move(tabs[2], toGroup: g)
        let context = try await extensionContext()
        func grouped() -> [String] { browser.tabs.filter { $0.groupID == g }.map(\.title) }
        func at(_ title: String) throws -> Int { try place(title, in: browser, for: context) }
        XCTAssertEqual(row(browser), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(grouped(), ["a", "b", "c"])

        try await move("c", to: -1, in: browser, for: context)
        XCTAssertEqual(row(browser), ["a", "b", "d", "e", "c"], "out of its group, forward: where it was sent")
        XCTAssertEqual(grouped(), ["a", "b"])
        try await move("c", to: try at("b"), in: browser, for: context)
        XCTAssertEqual(row(browser), ["a", "c", "b", "d", "e"], "into the middle of a group")
        XCTAssertEqual(grouped(), ["a", "c", "b"], "and in it")
        try await move("e", to: try at("d"), in: browser, for: context)
        XCTAssertEqual(row(browser), ["a", "c", "b", "e", "d"], "at the group's edge")
        XCTAssertEqual(grouped(), ["a", "c", "b"], "and in none")
        try await move("d", to: try at("a"), in: browser, for: context)
        XCTAssertEqual(row(browser), ["d", "a", "c", "b", "e"])
        XCTAssertNil(tabs[3].groupID, "before a group, in none")
        try await move("b", to: try at("d"), in: browser, for: context)
        XCTAssertEqual(row(browser), ["b", "d", "a", "c", "e"], "out of its group, back")
        XCTAssertEqual(grouped(), ["a", "c"])
        // Several, as the shim moves them: each to the place after the one
        // before it. e, sent back to c's place, lands between a and c and
        // joins; d, sent forward to the place after e's, lands after c, at
        // the group's edge, and stays in none.
        var index = try at("c")
        for title in ["e", "d"] {
            try await move(title, to: index, in: browser, for: context)
            index = try at(title) + 1
        }
        XCTAssertEqual(row(browser), ["b", "a", "e", "c", "d"])
        XCTAssertEqual(grouped(), ["a", "e", "c"])

        // A drag in the column keeps a tab's group, as it always has.
        let a = try XCTUnwrap(browser.tabs.first { $0.title == "a" })
        browser.moveDisplayedTab(a, to: try XCTUnwrap(browser.displayedTabs.firstIndex { $0.title == "b" }))
        XCTAssertEqual(a.groupID, g)
    }

    /// Two windows of one frame: a tab sent to the second goes there, not
    /// to the first of that frame nor moved in its own; one sent to a
    /// window of that frame whose pages are neither's fails, nothing moved.
    func testATabSentToOneOfTwoWindowsOfOneFrameGoesToThatOne() async throws {
        let here = makeBrowser()
        let there = Browser(record: WindowRecord())
        Browsers.register(there)
        defer { Browsers.discard(there); there.closeAll() }
        let rect = NSRect(x: -30_000, y: -30_000, width: 800, height: 600)
        var frame: [String: Any] = [:]
        for browser in [here, there] {
            let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            browser.window = window
            addTeardownBlock { @MainActor in window.close() }
            let height = (window.screen ?? NSScreen.main)?.frame.height ?? 0
            frame = ["left": window.frame.minX, "top": height - window.frame.maxY, "width": window.frame.width, "height": window.frame.height]
        }
        _ = try pages(["a1", "a2"], in: here)
        _ = try pages(["b1"], in: there)
        let context = try await extensionContext()
        func shown(_ browser: Browser) -> [String] {
            Extensions.shared.visibleRows(of: browser, for: context).map { $0.url(for: context)?.absoluteString ?? "" }
        }
        let number = { (key: String) in (frame[key] as? CGFloat) ?? .nan }
        let shared = CGRect(x: number("left"), y: number("top"), width: number("width"), height: number("height"))
        XCTAssertEqual(Extensions.shared.browsers(windowFrame: shared).count, 2, "two windows of one frame")
        func send(_ title: String, to window: [String: Any]) async throws -> [String: Any]? {
            let at = try XCTUnwrap(Extensions.shared.visibleRows(of: here, for: context).firstIndex { $0.tab?.title == title })
            let source: [String: Any] = ["i": at, "w": frame, "u": "https://\(title).example/"]
            return try await ExtensionShims.answer(["api": "tabs.move", "args": [source, 0, window]], from: context, owner: Extensions.shared)
                as? [String: Any]
        }
        var wrong = frame
        wrong["u"] = ["https://nowhere.example/"]
        let refused = try await send("a2", to: wrong)
        XCTAssertNotNil(refused?["error"], "\(String(describing: refused))")
        XCTAssertEqual(row(here).suffix(2), ["a1", "a2"], "nothing moved")
        var second = frame
        second["u"] = shown(there)
        let reply = try await send("a2", to: second)
        XCTAssertNil(reply?["error"], "\(String(describing: reply))")
        XCTAssertTrue(there.tabs.contains { $0.title == "a2" }, "in the second window")
        XCTAssertFalse(here.tabs.contains { $0.title == "a2" })
    }

    // MARK: - the pieces

    /// Tabs after any the window has, titled and in the order given.
    private func pages(_ words: [String], in browser: Browser) throws -> [Eden.Tab] {
        try words.map { word in
            browser.newTab()
            let tab = try XCTUnwrap(browser.tabs.last)
            tab.restore(url: try XCTUnwrap(URL(string: "https://\(word).example/")), title: word)
            return tab
        }
    }

    private func row(_ browser: Browser) -> [String] { browser.tabs.filter { !$0.isBlank }.map(\.title) }

    private func place(_ title: String, in browser: Browser, for context: WKWebExtensionContext) throws -> Int {
        try XCTUnwrap(Extensions.shared.visibleRows(of: browser, for: context).firstIndex { $0.tab?.title == title })
    }

    /// The tab titled so moved to `index` by an extension.
    private func move(_ title: String, to index: Int, in browser: Browser, for context: WKWebExtensionContext) async throws {
        let reply = try await ExtensionShims.answer(["api": "tabs.move", "args": [try place(title, in: browser, for: context), index]],
                                                    from: context, owner: Extensions.shared) as? [String: Any]
        XCTAssertNil(reply?["error"], "\(String(describing: reply))")
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let made = Browser(record: WindowRecord())
        made.welcoming = false
        place = made.prefs.newTabPlace
        made.prefs.newTabPlace = .end
        Browsers.register(made)
        browser = made
        return made
    }

    private func extensionContext() async throws -> WKWebExtensionContext {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("tabs-move-\(UUID())")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        folder = made
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Move", "version": "1", "permissions": ["tabs"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: made.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: made))
        context.uniqueIdentifier = "tabs-move-\(UUID().uuidString)"
        context.setPermissionStatus(.grantedExplicitly, for: .tabs)
        return context
    }
}
