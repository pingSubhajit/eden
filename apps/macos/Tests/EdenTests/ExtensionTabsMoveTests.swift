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
        // One moved past the next: its order alone can't tell which moved;
        // the tab the move was asked of is the one told, not the one passed.
        let (a, b, c) = (ids[0], ids[1], ids[2])
        XCTAssertEqual(Extensions.moved(from: [a, b, c], to: [b, a, c], movers: [a]), [a])
        XCTAssertEqual(Extensions.moved(from: [a, b, c], to: [b, a, c], movers: [b]), [b])
        // A mover that came back to its place moved nowhere.
        XCTAssertEqual(Extensions.moved(from: [a, b, c], to: [a, b, c], movers: [a]), [])
    }

    /// A tab dragged one place along the column, or moved so by an
    /// extension, is the one the window says moved (Browser.movers).
    func testTheTabMovedIsTheOneSaidToHaveMoved() async throws {
        let browser = makeBrowser()
        for word in ["a", "b", "c"] {
            browser.newTab()
            browser.tabs.last?.restore(url: try XCTUnwrap(URL(string: "https://\(word).example/")), title: word)
        }
        let shown = browser.displayedTabs.filter { !$0.isBlank }
        let a = try XCTUnwrap(shown.first { $0.title == "a" })
        let before = browser.tabs.map(\.id)
        browser.movers = []
        let at = try XCTUnwrap(browser.displayedTabs.firstIndex { $0.id == a.id })
        browser.moveDisplayedTab(a, to: at + 1)
        XCTAssertEqual(browser.movers, [a.id], "dragged: the tab carried")
        XCTAssertEqual(Extensions.moved(from: before, to: browser.tabs.map(\.id), movers: browser.movers), [a.id])

        let context = try await extensionContext()
        let b = try XCTUnwrap(browser.tabs.first { $0.title == "b" })
        let rows = Extensions.shared.visibleRows(of: browser, for: context)
        let place = try XCTUnwrap(rows.firstIndex { $0.tab === b })
        browser.movers = []
        let middle = browser.tabs.map(\.id)
        let reply = try await ExtensionShims.answer(["api": "tabs.move", "args": [place, place + 1]],
                                                    from: context, owner: Extensions.shared) as? [String: Any]
        XCTAssertNil(reply?["error"], "\(String(describing: reply))")
        XCTAssertTrue(browser.movers.contains(b.id), "moved by an extension: the tab it named")
        XCTAssertEqual(Extensions.moved(from: middle, to: browser.tabs.map(\.id), movers: browser.movers), [b.id])
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

    /// A folder moved past a row is the one said to have moved, by its rows
    /// as extensions have them: held as data, tabs, or some of each.
    func testAFolderMovedPastARowIsTheOneSaidToHaveMoved() async throws {
        let browser = makeBrowser()
        func site(_ title: String) -> Bookmark {
            Bookmark(title: title, url: "https://\(title.lowercased()).example/", children: nil)
        }
        browser.pinShelf.take([Bookmark(title: "Work", url: nil, children: [site("w1"), site("w2")]), site("B")], into: nil)
        defer { Pins.setGroups(browser.spaceID, [], from: nil) }
        let work = try XCTUnwrap(browser.keptGroups.first { $0.name == "Work" }?.id)
        let context = try await extensionContext()
        func ids() -> [Eden.Tab.ID] { Extensions.shared.visibleRows(of: browser, for: context).map(\.id) }
        func titles() -> [String] {
            Extensions.shared.visibleRows(of: browser, for: context).compactMap { row in
                row.tab?.title ?? browser.heldRows.first { browser.pinTabID($0.id) == row.id }?.title
            }
        }
        func moveWork(below: Bool) throws -> [Eden.Tab.ID] {
            let before = ids()
            browser.movers = []
            XCTAssertTrue(browser.move(group: work, to: ColumnPlace(area: .kept, index: below ? 1 : 0)))
            return Extensions.moved(from: before, to: ids(), movers: browser.movers)
        }
        func rows(_ titles: [String]) -> [Eden.Tab.ID] {
            let all = Extensions.shared.visibleRows(of: browser, for: context)
            return titles.compactMap { title in
                all.first { row in (row.tab?.title ?? browser.heldRows.first { browser.pinTabID($0.id) == row.id }?.title) == title }?.id
            }
        }

        browser.setGroupFolded(work, true)
        XCTAssertEqual(browser.heldRows(ofGroup: work).count, 2, "both held")
        XCTAssertEqual(titles().prefix(3), ["w1", "w2", "B"])
        XCTAssertEqual(try moveWork(below: true), rows(["w1", "w2"]), "held: the folder's rows, not B")
        XCTAssertEqual(titles().prefix(3), ["B", "w1", "w2"])
        XCTAssertEqual(try moveWork(below: false), rows(["w1", "w2"]))

        browser.setGroupFolded(work, false)
        XCTAssertEqual(browser.heldRows(ofGroup: work).count, 0, "both tabs")
        XCTAssertEqual(try moveWork(below: true), rows(["w1", "w2"]), "tabs")
        XCTAssertEqual(try moveWork(below: false), rows(["w1", "w2"]))

        let w1 = try XCTUnwrap(browser.tabs.first { $0.title == "w1" })
        browser.select(w1)
        browser.setGroupFolded(work, true)
        XCTAssertEqual(browser.heldRows(ofGroup: work).map(\.title), ["w2"], "one of each")
        XCTAssertEqual(try moveWork(below: true), rows(["w1", "w2"]), "one of each")
        XCTAssertEqual(titles().prefix(3), ["B", "w1", "w2"])
    }

    /// The tabs moved are noted only while extensions follow the row, and
    /// each time it is followed they are let go: never more than one
    /// change's.
    func testMoversAreNotedOnlyWhileFollowedAndLetGo() throws {
        let followed = makeBrowser()
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        for word in ["a", "b"] {
            browser.newTab()
            browser.tabs.last?.restore(url: try XCTUnwrap(URL(string: "https://\(word).example/")), title: word)
        }
        let a = try XCTUnwrap(browser.tabs.first { $0.title == "a" })
        let at = try XCTUnwrap(browser.displayedTabs.firstIndex { $0.id == a.id })
        XCTAssertFalse(browser.rowFollowed)
        browser.moveDisplayedTab(a, to: at == 0 ? 1 : 0)
        XCTAssertTrue(browser.movers.isEmpty, "not followed: nothing noted")

        XCTAssertTrue(followed.rowFollowed, "registered, extensions follow it")
        for word in ["c", "d"] {
            followed.newTab()
            followed.tabs.last?.restore(url: try XCTUnwrap(URL(string: "https://\(word).example/")), title: word)
        }
        let c = try XCTUnwrap(followed.tabs.first { $0.title == "c" })
        let from = try XCTUnwrap(followed.displayedTabs.firstIndex { $0.id == c.id })
        followed.moveDisplayedTab(c, to: from + 1)
        XCTAssertEqual(followed.movers, [c.id])
        let emptied = expectation(description: "followed")
        DispatchQueue.main.async { DispatchQueue.main.async { emptied.fulfill() } }
        wait(for: [emptied], timeout: 2)
        XCTAssertTrue(followed.movers.isEmpty, "the row followed, its movers let go")
    }

    /// A tab sent to another window by an extension goes as it is: the
    /// tab in front there stays in front, it isn't woken, and the window it
    /// left keeps its own tab in front.
    func testATabSentToAnotherWindowGoesAsItIs() throws {
        let here = makeBrowser()
        let there = Browser(record: WindowRecord())
        Browsers.register(there)
        defer { Browsers.discard(there); there.closeAll() }
        func page(_ word: String, in browser: Browser) throws -> Eden.Tab {
            browser.newTab()
            let tab = try XCTUnwrap(browser.tabs.last)
            tab.restore(url: try XCTUnwrap(URL(string: "https://\(word).example/")), title: word)
            return tab
        }
        let front = try page("front", in: here)
        let going = try page("going", in: here)
        let theirs = try page("theirs", in: there)
        here.select(front)
        there.select(theirs)
        XCTAssertTrue(going.asleep)
        XCTAssertTrue(here.hand(going, to: there))
        XCTAssertTrue(there.tabs.contains { $0 === going })
        XCTAssertEqual(there.activeID, theirs.id, "the tab in front there stays in front")
        XCTAssertEqual(here.activeID, front.id, "and here")
        XCTAssertTrue(going.asleep, "not woken")
        XCTAssertFalse(here.hand(front, to: here), "not to its own window")
    }

    /// A page of a split sent to another window takes the split with it,
    /// whole, in its order and a split there, as a move along the row does;
    /// neither page is woken nor put in front, in either window.
    func testASplitSentToAnotherWindowGoesWhole() throws {
        let here = makeBrowser()
        let there = Browser(record: WindowRecord())
        Browsers.register(there)
        defer { Browsers.discard(there); there.closeAll() }
        let split = here.prefs.splitView
        here.prefs.splitView = true
        defer { here.prefs.splitView = split }
        let front = try pages(["front"], in: here)[0]
        let pair = try pages(["a", "b"], in: here)
        let theirs = try pages(["theirs"], in: there)[0]
        here.pair(pair[1], with: pair[0], onLeft: false)
        XCTAssertEqual(here.split(for: pair[0])?.tabs, pair.map(\.id))
        here.select(front)
        there.select(theirs)
        // Shown as a split, they woke: asleep again out of sight.
        for page in pair where !page.asleep { page.sleep(picture: nil) }
        XCTAssertTrue(pair.allSatisfy(\.asleep))

        XCTAssertTrue(here.hand(pair[1], to: there))
        XCTAssertFalse(here.tabs.contains { $0 === pair[0] || $0 === pair[1] }, "neither page left behind")
        XCTAssertEqual(row(there).suffix(2), ["a", "b"], "both, in their order")
        XCTAssertEqual(there.split(for: pair[0])?.tabs, pair.map(\.id), "a split there too")
        XCTAssertEqual(there.activeID, theirs.id, "the tab in front there stays in front")
        XCTAssertEqual(here.activeID, front.id, "and here")
        XCTAssertTrue(pair.allSatisfy(\.asleep), "neither woken")
    }

    /// A split sent to another window by one of its pages goes whole, to
    /// the end there, and the call says so: its place there, within the
    /// split itself, is where it already is, which is no failure.
    func testASplitSentToAnotherWindowByAnExtensionSucceeds() async throws {
        let here = makeBrowser()
        let there = Browser(record: WindowRecord())
        Browsers.register(there)
        defer { Browsers.discard(there); there.closeAll() }
        func frame(of browser: Browser, at x: CGFloat) -> [String: Any] {
            let window = NSWindow(contentRect: NSRect(x: x, y: -30_000, width: 800, height: 600), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            browser.window = window
            addTeardownBlock { @MainActor in window.close() }
            let height = (window.screen ?? NSScreen.main)?.frame.height ?? 0
            return ["left": window.frame.minX, "top": height - window.frame.maxY, "width": window.frame.width, "height": window.frame.height]
        }
        let mine = frame(of: here, at: -40_000), theirs = frame(of: there, at: -30_000)
        let split = here.prefs.splitView
        here.prefs.splitView = true
        defer { here.prefs.splitView = split }
        let pair = try pages(["a", "b"], in: here)
        _ = try pages(["theirs"], in: there)
        here.pair(pair[1], with: pair[0], onLeft: false)
        let context = try await extensionContext()
        let source: [String: Any] = ["i": try place("a", in: here, for: context), "w": mine]
        let reply = try await ExtensionShims.answer(["api": "tabs.move", "args": [source, -1, theirs]],
                                                    from: context, owner: Extensions.shared) as? [String: Any]
        XCTAssertNil(reply?["error"], "\(String(describing: reply))")
        XCTAssertEqual(row(there).suffix(2), ["a", "b"])
        XCTAssertEqual(there.split(for: pair[0])?.tabs, pair.map(\.id), "a split there")
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
