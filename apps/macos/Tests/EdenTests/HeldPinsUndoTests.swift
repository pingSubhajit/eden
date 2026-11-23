import AppKit
import EdenCore
import XCTest
@testable import Eden

/// ⇧⌘T beside folded folders whose rows are held as data (#9,
/// HeldPins.swift): a pin taken out for good comes back exactly where it
/// was among the rows and the folders, in the window and in the pins
/// store, and a Clear or Close Other Tabs comes back after the pins, however
/// many of them are tabs by then.
@MainActor
final class HeldPinsUndoTests: XCTestCase {
    private var browsers: [Browser] = []
    private var restorePreferences: (() -> Void)?

    override class func setUp() {
        setenv("EDEN_PROBE", "held-pins-undo-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        CleanWorld.reset()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("held-pins-undo-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.subhajit.eden.beta.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        for browser in browsers {
            Pins.setGroups(browser.spaceID, [], from: nil)
            browser.closeAll()
            CleanWorld.reset(space: browser.spaceID)
        }
        browsers.removeAll()
        restorePreferences?()
        try await Task.sleep(for: .milliseconds(100))
        try await super.tearDown()
    }

    // MARK: - a pin taken out, and back

    /// The first row, before a folded folder: back first, the folder still
    /// after it, rather than after the folder.
    func testARowBeforeAHeldFolderComesBackBeforeIt() throws {
        let browser = makeBrowser()
        try keep(browser)
        try deleteAndUndo("A", in: browser)
        XCTAssertEqual(rows(browser), ["A", "B", "d1", "d2"])
        XCTAssertEqual(described(browser), ["pin 0 A", "folder 0 Work", "pin 0 B", "folder 0 Docs", "pin 1 d1", "pin 1 d2"])
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])
    }

    func testARowAfterAHeldFolderComesBackAfterIt() throws {
        let browser = makeBrowser()
        try keep(browser)
        try deleteAndUndo("B", in: browser)
        XCTAssertEqual(rows(browser), ["A", "B", "d1", "d2"])
        XCTAssertEqual(described(browser), ["pin 0 A", "folder 0 Work", "pin 0 B", "folder 0 Docs", "pin 1 d1", "pin 1 d2"])
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])
    }

    /// Between two folded folders, the only row the window has a tab for.
    func testARowBetweenTwoHeldFoldersComesBackBetweenThem() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        browser.setGroupFolded(kept.docs, true)
        try deleteAndUndo("B", in: browser)
        XCTAssertEqual(rows(browser), ["A", "B"])
        XCTAssertEqual(described(browser), ["pin 0 A", "folder 0 Work", "pin 0 B", "folder 0 Docs"])
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])

        try deleteAndUndo("A", in: browser)
        XCTAssertEqual(described(browser), ["pin 0 A", "folder 0 Work", "pin 0 B", "folder 0 Docs"])
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])
    }

    /// A row of a folded folder gone to, so a tab among rows held as data:
    /// back between them, not after them.
    func testARowInsideAFolderComesBackBetweenItsHeldRows() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        for title in ["w2", "w1", "w3"] {
            let pin = try XCTUnwrap(browser.heldRows(ofGroup: kept.work).first { $0.title == title }?.id)
            let tab = try XCTUnwrap(browser.showHeld(pin))
            browser.select(tab)
            try deleteAndUndo(title, in: browser)
            XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"], title)
            XCTAssertEqual(described(browser), ["pin 0 A", "folder 0 Work", "pin 1 \(title)", "pin 0 B", "folder 0 Docs",
                                                "pin 1 d1", "pin 1 d2"], title)
            let a = try XCTUnwrap(browser.tabs.first { $0.title == "A" })
            browser.select(a)
            browser.closeTab(try XCTUnwrap(browser.tabs.first { $0.title == title }))
            XCTAssertEqual(rows(browser), ["A", "B", "d1", "d2"], title)
        }
        browser.setGroupFolded(kept.work, false)
        XCTAssertEqual(rows(browser), ["A", "w1", "w2", "w3", "B", "d1", "d2"])
    }

    /// Taken out asleep, never shown, and back so, beside the folder, while
    /// you stay on the row you were on.
    func testARowTakenOutAsleepComesBackWhereItWas() throws {
        let browser = makeBrowser()
        try keep(browser)
        let b = try XCTUnwrap(browser.tabs.first { $0.title == "B" })
        let a = try XCTUnwrap(browser.tabs.first { $0.title == "A" })
        browser.select(a)
        XCTAssertTrue(b.asleep, "never shown")
        browser.deletePin(b)
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "d1 Docs", "d2 Docs"])
        browser.reopen()
        XCTAssertEqual(browser.activeID, a.id, "you stay where you are")
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])
        XCTAssertEqual(described(browser), ["pin 0 A", "folder 0 Work", "pin 0 B", "folder 0 Docs", "pin 1 d1", "pin 1 d2"])
    }

    // MARK: - Clear and Close Other Tabs, and back

    /// Cleared with a folder folded, then unfolded, so the window has more
    /// pinned tabs than it had: the tabs come back after every pin.
    func testClearComesBackAfterThePinsHowEverManyAreTabs() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        loose(["x", "y"], in: browser)
        XCTAssertEqual(order(browser), ["A", "B", "d1", "d2", "x", "y"])
        browser.clearTabs()
        XCTAssertEqual(order(browser), ["A", "B", "d1", "d2"])
        browser.reopen()
        XCTAssertEqual(order(browser), ["A", "B", "d1", "d2", "x", "y"])
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])

        browser.clearTabs()
        browser.setGroupFolded(kept.work, false)
        browser.reopen()
        XCTAssertEqual(order(browser), ["A", "w1", "w2", "w3", "B", "d1", "d2", "x", "y"])

        browser.clearTabs()
        browser.setGroupFolded(kept.work, true)
        browser.setGroupFolded(kept.docs, true)
        browser.reopen()
        XCTAssertEqual(order(browser), ["A", "B", "x", "y"])
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])
    }

    func testCloseOtherTabsComesBackAfterThePinsHowEverManyAreTabs() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        loose(["x", "y", "z"], in: browser)
        let y = try XCTUnwrap(browser.tabs.first { $0.title == "y" })
        browser.closeOthers(but: y)
        XCTAssertEqual(order(browser), ["A", "B", "d1", "d2", "y"])
        browser.setGroupFolded(kept.work, false)
        browser.reopen()
        XCTAssertEqual(order(browser), ["A", "w1", "w2", "w3", "B", "d1", "d2", "x", "y", "z"])

        browser.closeOthers(but: y)
        browser.setGroupFolded(kept.work, true)
        browser.reopen()
        XCTAssertEqual(order(browser), ["A", "B", "d1", "d2", "x", "y", "z"])
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])
    }

    // MARK: - the pieces

    /// The pin of the row titled so taken out for good from its menu, and
    /// put back with ⇧⌘T.
    private func deleteAndUndo(_ title: String, in browser: Browser) throws {
        let tab = try XCTUnwrap(browser.tabs.first { $0.title == title && $0.pin != nil }, title)
        let before = saved(browser)
        browser.deletePin(tab)
        XCTAssertFalse(saved(browser).contains { $0.hasPrefix(title) }, title)
        XCTAssertEqual(saved(browser).count, before.count - 1, title)
        browser.reopen()
    }

    /// A, a folder Work of three, folded, B, and a folder Docs of two,
    /// unfolded, brought in as bookmarks are.
    @discardableResult
    private func keep(_ browser: Browser) throws -> (work: UUID, docs: UUID) {
        func site(_ title: String) -> Bookmark { Bookmark(title: title, url: "https://\(title.lowercased()).example/", children: nil) }
        let took = browser.pinShelf.take([
            site("A"), Bookmark(title: "Work", url: nil, children: [site("w1"), site("w2"), site("w3")]),
            site("B"), Bookmark(title: "Docs", url: nil, children: [site("d1"), site("d2")]),
        ], into: nil)
        XCTAssertEqual(took.added, 7)
        let groups = browser.keptGroups
        let work = try XCTUnwrap(groups.first { $0.name == "Work" }?.id)
        let docs = try XCTUnwrap(groups.first { $0.name == "Docs" }?.id)
        browser.setGroupFolded(work, true)
        browser.setGroupFolded(docs, false)
        return (work, docs)
    }

    /// Tabs that come and go, after the pins, in the order named.
    private func loose(_ titles: [String], in browser: Browser) {
        for title in titles {
            guard let url = URL(string: "https://\(title).example/") else { continue }
            browser.newTab()
            browser.tabs.last?.restore(url: url, title: title)
        }
    }

    /// The window's tabs, pins and not, in its order.
    private func order(_ browser: Browser) -> [String] {
        browser.tabs.map(\.title)
    }

    /// The pinned rows the window has tabs for, in its order.
    private func rows(_ browser: Browser) -> [String] {
        browser.tabs.filter { $0.pin != nil && $0.listed }.map(\.title)
    }

    /// The space's pinned rows as pins.json has them, each with its folder.
    private func saved(_ browser: Browser) -> [String] {
        let groups = Pins.groups(browser.spaceID)
        return Pins.defs(browser.spaceID).filter { $0.listed == true }.map { def in
            [def.title, def.group.flatMap { id in groups.first { $0.id == id }?.name }].compactMap { $0 }.joined(separator: " ")
        }
    }

    private func described(_ browser: Browser) -> [String] {
        browser.keptLines().map { line in
            switch line {
            case .heading(let group): "folder 0 \(group.name)"
            case .tab(let tab, let group): "pin \(group == nil ? 0 : 1) \(tab.title)"
            }
        }
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        if restorePreferences == nil {
            let previous = (prefs.usesTabGroups, prefs.sharesPins, prefs.newTabPlace)
            restorePreferences = { (prefs.usesTabGroups, prefs.sharesPins, prefs.newTabPlace) = previous }
        }
        prefs.usesTabGroups = false
        prefs.sharesPins = false
        // Each new tab after the last, so they stand in the order made.
        prefs.newTabPlace = .end
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browsers.append(browser)
        return browser
    }
}
