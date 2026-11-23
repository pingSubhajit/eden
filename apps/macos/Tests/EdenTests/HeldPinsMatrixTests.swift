import AppKit
import EdenCore
import WebKit
import XCTest
@testable import Eden

/// What else moves or changes a folded folder's rows held as data (#9,
/// HeldPins.swift), beside HeldPinsTests and HeldPinsUndoTests: several rows
/// carried in at once, a row unpinned or made a square out of a folder half
/// held, chrome.tabs.remove and chrome.bookmarks.move on held rows, a merge
/// from another device, a switch of spaces, the rows every space shows, and
/// a relaunch, each leaving the rows held where they stand.
@MainActor
final class HeldPinsMatrixTests: XCTestCase {
    private var browsers: [Browser] = []
    private var restorePreferences: (() -> Void)?

    override class func setUp() {
        setenv("EDEN_PROBE", "held-pins-matrix-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        CleanWorld.reset()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("held-pins-matrix-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.subhajit.eden.beta.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        for browser in browsers {
            Browsers.discard(browser)
            Pins.setGroups(browser.spaceID, [], from: nil)
            browser.closeAll()
            CleanWorld.reset(space: browser.spaceID)
        }
        browsers.removeAll()
        restorePreferences?()
        try await Task.sleep(for: .milliseconds(100))
        try await super.tearDown()
    }

    // MARK: - carried in, several at once

    /// Rows picked together and carried into a folded folder whose rows are
    /// all held go in where they are let go, in their order, and the held
    /// rows stay held, in theirs.
    func testRowsPickedTogetherCarriedIntoAHeldFolderGoInWhereLetGo() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        let a = try tab(browser, "A"), b = try tab(browser, "B")
        browser.select(a)
        browser.extendTabSelection(to: b, modifiers: .command)
        XCTAssertEqual(browser.selectedTabIDs, [a.id, b.id])
        XCTAssertTrue(browser.move(carrying: a, to: ColumnPlace(area: .kept, group: kept.work)))
        XCTAssertEqual(saved(browser), ["w1 Work", "w2 Work", "w3 Work", "A Work", "B Work", "d1 Docs", "d2 Docs"])
        XCTAssertEqual(browser.heldRows(ofGroup: kept.work).map(\.title).prefix(3), ["w1", "w2", "w3"], "still held")
    }

    // MARK: - out of a folder half held

    /// A tab of a folder half held unpinned (⌘D, the menu's Unpin) leaves
    /// the folder's other rows where they were, the held one still held.
    func testARowUnpinnedOutOfAFolderHalfHeldLeavesTheRestAsTheyWere() throws {
        let browser = makeBrowser()
        let work = try halfHeld(browser)
        browser.unpin(try tab(browser, "w1"))
        XCTAssertEqual(saved(browser), ["A", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])
        XCTAssertEqual(browser.heldRows(ofGroup: work).map(\.title), ["w2"])
        XCTAssertTrue(browser.tabs.contains { $0.title == "w1" && $0.pin == nil }, "a tab that comes and goes now")
        XCTAssertEqual(described(browser), ["pin 0 A", "folder 0 Work", "pin 0 B", "folder 0 Docs", "pin 1 d1", "pin 1 d2"],
                       "the folder where it stood, folded")
    }

    /// Made a square, it leaves the folder for the squares; the rest stays.
    func testARowMadeASquareOutOfAFolderHalfHeldLeavesTheRestAsTheyWere() throws {
        let browser = makeBrowser()
        let work = try halfHeld(browser)
        browser.setListed(try tab(browser, "w3"), false)
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "B", "d1 Docs", "d2 Docs"])
        XCTAssertEqual(browser.heldRows(ofGroup: work).map(\.title), ["w2"])
        XCTAssertTrue(Pins.defs(browser.spaceID).contains { $0.title == "w3" && $0.listed != true && $0.group == nil })
    }

    // MARK: - extensions

    /// chrome.tabs.remove on a held row puts it down at its page, as on any
    /// pin: it is there already, so it stays held, nothing made or told.
    @available(macOS 15.4, *)
    func testAnExtensionClosingAHeldRowLeavesItHeld() async throws {
        let browser = makeBrowser()
        Browsers.register(browser)
        let kept = try keep(browser)
        let context = try await extensionContext()
        let w2 = try XCTUnwrap(browser.heldRows(ofGroup: kept.work).first { $0.title == "w2" })
        let row = try XCTUnwrap(Extensions.shared.visibleRows(of: browser, for: context).first { $0.id == browser.pinTabID(w2.id) })
        try await row.close(for: context)
        XCTAssertTrue(browser.holds(pin: w2.id))
        XCTAssertEqual(rows(browser), ["A", "B", "d1", "d2"], "no tab made for it")
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])
    }

    /// chrome.bookmarks.move on rows held as data: one moved within its
    /// folder, one out of it, which is shown as a tab there, and one moved
    /// in, which is held with the rest.
    func testChromeBookmarksMovesHeldRows() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        let shelf = browser.pinShelf
        func pin(_ title: String) throws -> UUID { try XCTUnwrap(Pins.defs(browser.spaceID).first { $0.title == title }?.id) }
        XCTAssertTrue(shelf.move(try pin("w3"), into: kept.work, at: 0))
        XCTAssertEqual(saved(browser), ["A", "w3 Work", "w1 Work", "w2 Work", "B", "d1 Docs", "d2 Docs"])
        XCTAssertEqual(browser.heldRows(ofGroup: kept.work).map(\.title), ["w3", "w1", "w2"])

        XCTAssertTrue(shelf.move(try pin("w1"), into: nil, at: 0))
        XCTAssertEqual(saved(browser).first, "w1")
        XCTAssertEqual(browser.heldRows(ofGroup: kept.work).map(\.title), ["w3", "w2"])
        XCTAssertTrue(rows(browser).contains("w1"), "out of the folder, a tab")

        XCTAssertTrue(shelf.move(try pin("B"), into: kept.work, at: 1))
        XCTAssertEqual(saved(browser).filter { $0.hasSuffix("Work") }, ["w3 Work", "B Work", "w2 Work"])
        XCTAssertFalse(rows(browser).contains("B"), "into the folded folder, held")
        writeAndRead(browser)
        XCTAssertEqual(saved(browser).filter { $0.hasSuffix("Work") }, ["w3 Work", "B Work", "w2 Work"], "and written so")
    }

    // MARK: - another device, another space

    /// The pins merged from another device, a held row renamed and moved
    /// within its folder there: held still, in the order merged, as named.
    func testAMergeFromAnotherDeviceKeepsHeldRowsHeldInItsOrder() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        var defs = Pins.defs(browser.spaceID)
        let w1 = try XCTUnwrap(defs.firstIndex { $0.title == "w1" })
        var moved = defs.remove(at: w1)
        moved.name = "First"
        let w3 = try XCTUnwrap(defs.firstIndex { $0.title == "w3" })
        defs.insert(moved, at: w3 + 1)
        Pins.adopt([browser.spaceID: defs], in: [browser.spaceID], shared: [], profile: browser.profileID)
        browser.pinsChanged(in: browser.spaceID)
        XCTAssertEqual(browser.heldRows(ofGroup: kept.work).map { $0.name ?? $0.title }, ["w2", "w3", "First"])
        XCTAssertEqual(rows(browser), ["A", "B", "d1", "d2"], "no tab made for them")
        writeAndRead(browser)
        XCTAssertEqual(saved(browser), ["A", "w2 Work", "w3 Work", "w1 Work", "B", "d1 Docs", "d2 Docs"])
    }

    /// Off to another space and back, the folded folder's rows are held
    /// there all along, where they stood, and no tab is made for them.
    func testASpaceLeftAndComeBackToKeepsItsRowsHeld() throws {
        let browser = makeBrowser()
        let prefs = browser.prefs
        let spaces = (prefs.usesSpaces, browser.spaces)
        defer { prefs.usesSpaces = spaces.0; browser.spaces = spaces.1 }
        prefs.usesSpaces = true
        let first = browser.spaceID, second = UUID()
        browser.spaces = [Space(id: first, name: "First", colour: 0), Space(id: second, name: "Second", colour: 1)]
        let kept = try keep(browser)
        browser.switchSpace(to: second)
        XCTAssertEqual(browser.heldPinIDs(in: first).count, 3, "held while parked")
        XCTAssertFalse(browser.parkedTabs.contains { $0.pinID.map { browser.holds(pin: $0, in: first) } == true })
        browser.switchSpace(to: first)
        XCTAssertEqual(browser.heldRows(ofGroup: kept.work).map(\.title), ["w1", "w2", "w3"])
        XCTAssertEqual(rows(browser), ["A", "B", "d1", "d2"])
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])
    }

    /// The rows every space shows keep the head of the row, ahead of the
    /// space's own rows and the folders held among them, to an extension as
    /// in the column; none of them is ever held.
    @available(macOS 15.4, *)
    func testTheRowsEverySpaceShowsStandAheadOfTheHeldOnes() async throws {
        let browser = makeBrowser()
        Browsers.register(browser)
        let shared = (browser.prefs.usesSpaces, browser.prefs.sharesPins)
        defer { (browser.prefs.usesSpaces, browser.prefs.sharesPins) = shared }
        (browser.prefs.usesSpaces, browser.prefs.sharesPins) = (true, true)
        let kept = try keep(browser)
        let b = try tab(browser, "B")
        browser.shareEverywhere(b)
        XCTAssertTrue(b.everywhere)
        let context = try await extensionContext()
        let titles = Extensions.shared.visibleRows(of: browser, for: context).compactMap { $0.title(for: context) }
        XCTAssertEqual(Array(titles.prefix(6)), ["B", "A", "w1", "w2", "w3", "d1"], "B first, the held rows in their place")
        XCTAssertEqual(browser.heldRows(ofGroup: kept.work).count, 3)
        XCTAssertFalse(browser.holds(pin: try XCTUnwrap(b.pinID)))
    }

    // MARK: - a relaunch

    /// A folder half held, relaunched: the rows that were tabs with their
    /// sound off come back tabs, the held one held, all in their order.
    func testAFolderHalfHeldComesBackSoAfterARelaunch() throws {
        let browser = makeBrowser()
        let work = try halfHeld(browser)
        XCTAssertTrue(browser.move(try tab(browser, "w3"), to: ColumnPlace(area: .kept, group: work, index: 0)))
        let order = saved(browser)
        XCTAssertEqual(order, ["A", "w3 Work", "w1 Work", "w2 Work", "B", "d1 Docs", "d2 Docs"])
        browser.writeSession(now: true)
        let again = makeBrowser()
        XCTAssertEqual(rows(again), ["A", "w3", "w1", "B", "d1", "d2"])
        XCTAssertEqual(again.heldRows(ofGroup: work).map(\.title), ["w2"])
        again.writeSession(now: true)
        XCTAssertEqual(saved(again), order)
    }

    // MARK: - the pieces

    @available(macOS 15.4, *)
    private func extensionContext() async throws -> WKWebExtensionContext {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("held-pins-matrix-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Held matrix", "version": "1", "permissions": ["tabs"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.uniqueIdentifier = "held-pins-matrix-\(UUID().uuidString)"
        context.setPermissionStatus(.grantedExplicitly, for: .tabs)
        return context
    }

    /// The pins written and read back, as another window would read them.
    private func writeAndRead(_ browser: Browser) {
        browser.writeSession(now: true)
        browser.pinsChanged(in: browser.spaceID)
    }

    /// A, a folder Work of three, folded, B, and a folder Docs of two,
    /// unfolded, brought in as bookmarks are.
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

    /// keep's rows, with Work folded half held: w1 and w3 tabs, their sound
    /// turned off, which a row held as data can't keep, and w2 held.
    private func halfHeld(_ browser: Browser) throws -> UUID {
        let kept = try keep(browser)
        browser.setGroupFolded(kept.work, false)
        for title in ["w1", "w3"] { try tab(browser, title).muted = true }
        browser.setGroupFolded(kept.work, true)
        XCTAssertEqual(rows(browser), ["A", "w1", "w3", "B", "d1", "d2"])
        XCTAssertEqual(browser.heldRows(ofGroup: kept.work).map(\.title), ["w2"])
        return kept.work
    }

    /// The window's pinned tab titled so.
    private func tab(_ browser: Browser, _ title: String) throws -> Eden.Tab {
        try XCTUnwrap(browser.tabs.first { $0.pin != nil && $0.title == title }, title)
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
            let previous = (prefs.usesTabGroups, prefs.sharesPins)
            restorePreferences = { (prefs.usesTabGroups, prefs.sharesPins) = previous }
        }
        prefs.usesTabGroups = false
        prefs.sharesPins = false
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browsers.append(browser)
        return browser
    }
}
