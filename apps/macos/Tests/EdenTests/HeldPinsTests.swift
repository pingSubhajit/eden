import AppKit
import EdenCore
import WebKit
import XCTest
@testable import Eden

/// Pinned rows in folded folders held as data, not tabs (#9, HeldPins.swift):
/// made tabs as their folder unfolds or one is gone to, let go again as it
/// folds, and every bit pins all the while: written back where they stand,
/// found by the address field, read and changed by chrome.bookmarks
/// (PinShelf), counted by the number keys and Copy All Links, out of the
/// session, and the same in every window.
@MainActor
final class HeldPinsTests: XCTestCase {
    private var browsers: [Browser] = []
    private var restorePreferences: (() -> Void)?

    override class func setUp() {
        setenv("EDEN_PROBE", "held-pins-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        CleanWorld.reset()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("held-pins-") {
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

    // MARK: - held, and made tabs

    func testAFoldedFoldersRowsAreDataNotTabs() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        XCTAssertEqual(rows(browser), ["A", "B", "d1", "d2"], "no tab for a folded folder's rows")
        XCTAssertEqual(browser.heldRows(ofGroup: kept.work).map(\.title), ["w1", "w2", "w3"])
        XCTAssertEqual(described(browser), ["pin 0 A", "folder 0 Work", "pin 0 B", "folder 0 Docs", "pin 1 d1", "pin 1 d2"],
                       "the folder drawn where it stands")
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])
    }

    func testUnfoldedItsRowsAreTabsWhereTheyStandAndFoldedAgainTheyGo() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        browser.setGroupFolded(kept.work, false)
        XCTAssertEqual(rows(browser), ["A", "w1", "w2", "w3", "B", "d1", "d2"])
        XCTAssertNil(browser.heldPins[browser.spaceID]?.first { $0.id == kept.work })
        XCTAssertEqual(described(browser), ["pin 0 A", "folder 0 Work", "pin 1 w1", "pin 1 w2", "pin 1 w3",
                                            "pin 0 B", "folder 0 Docs", "pin 1 d1", "pin 1 d2"])

        // Gone to, a row has a page of its own: folded, it stays a tab, and
        // the folder shows it while it is in front.
        let w2 = try XCTUnwrap(browser.tabs.first { $0.title == "w2" })
        browser.select(w2)
        browser.setGroupFolded(kept.work, true)
        XCTAssertEqual(rows(browser), ["A", "w2", "B", "d1", "d2"])
        XCTAssertEqual(browser.heldRows(ofGroup: kept.work).map(\.title), ["w1", "w3"])
        XCTAssertEqual(described(browser), ["pin 0 A", "folder 0 Work", "pin 1 w2", "pin 0 B", "folder 0 Docs",
                                            "pin 1 d1", "pin 1 d2"])
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])

        // Gone from, it stays a tab; put down at its page again out of
        // sight, it holds nothing its pin doesn't, and is data again.
        let a = try XCTUnwrap(browser.tabs.first { $0.title == "A" })
        browser.select(a)
        browser.pinsChanged(in: browser.spaceID)
        XCTAssertEqual(rows(browser), ["A", "w2", "B", "d1", "d2"])
        browser.closeTab(w2)
        XCTAssertEqual(rows(browser), ["A", "B", "d1", "d2"])
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])
    }

    /// Bookmarks come in folded, in a folder named after the file they come
    /// from or the folder they were in, and make no tab, ahead or after.
    func testBookmarksComeInFoldedAsData() async throws {
        let browser = makeBrowser()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eden-held-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var html = "<DL><p>\n<DT><H3>Reading</H3><DL><p>\n"
        for n in 0..<120 { html += #"<DT><A HREF="https://held-\#(n).example/">Held \#(n)</A>"# + "\n" }
        html += "</DL><p>\n</DL>\n"
        let file = folder.appendingPathComponent("Kept Pages.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        let took = await browser.takeFile(file)
        XCTAssertEqual(took.bookmarks, 120)
        let group = try XCTUnwrap(browser.keptGroups.first { $0.name == "Kept Pages Bookmarks" })
        XCTAssertTrue(group.collapsed)
        XCTAssertEqual(browser.heldRows(ofGroup: group.id).count, 120)
        XCTAssertEqual(rows(browser), [])
        XCTAssertEqual(Tab.live.allObjects.filter { tab in tab.pinID.map { browser.holds(pin: $0) } == true }.count, 0,
                       "no tab made for them ahead, nor kept")

        browser.pinShelf.take([Bookmark(title: "Later", url: nil, children: [
            Bookmark(title: "Later 1", url: "https://later-1.example/", children: nil),
        ])], into: nil)
        let later = try XCTUnwrap(browser.keptGroups.first { $0.name == "Later" })
        XCTAssertTrue(later.collapsed, "your own bookmarks' folders too")
        XCTAssertEqual(rows(browser), [])
    }

    func testFoldAllGroupsHoldsEveryFoldersRows() throws {
        let browser = makeBrowser()
        _ = try keep(browser)
        browser.foldAllGroups(true)
        XCTAssertEqual(rows(browser), ["A", "B"])
        browser.foldAllGroups(false)
        XCTAssertEqual(rows(browser), ["A", "w1", "w2", "w3", "B", "d1", "d2"])
    }

    // MARK: - written where they stand

    func testWrittenBackWhereTheyStandWhateverMovesAroundThem() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        browser.writeSession(now: true)
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])

        // B to the top: the folder stays after A.
        let b = try XCTUnwrap(browser.tabs.first { $0.title == "B" })
        XCTAssertTrue(browser.move(b, to: ColumnPlace(area: .kept, index: 0)))
        XCTAssertEqual(saved(browser), ["B", "A", "w1 Work", "w2 Work", "w3 Work", "d1 Docs", "d2 Docs"])
        XCTAssertEqual(described(browser), ["pin 0 B", "pin 0 A", "folder 0 Work", "folder 0 Docs", "pin 1 d1", "pin 1 d2"])

        // A, which it stood after, to the end: the folder stays where it is.
        let a = try XCTUnwrap(browser.tabs.first { $0.title == "A" })
        XCTAssertTrue(browser.move(a, to: ColumnPlace(area: .kept)))
        XCTAssertEqual(saved(browser), ["B", "w1 Work", "w2 Work", "w3 Work", "d1 Docs", "d2 Docs", "A"])
        XCTAssertEqual(described(browser), ["pin 0 B", "folder 0 Work", "folder 0 Docs", "pin 1 d1", "pin 1 d2", "pin 0 A"])

        // The folder itself carried to the end.
        XCTAssertTrue(browser.move(group: kept.work, to: ColumnPlace(area: .kept)))
        XCTAssertEqual(saved(browser), ["B", "d1 Docs", "d2 Docs", "A", "w1 Work", "w2 Work", "w3 Work"])
        XCTAssertEqual(described(browser), ["pin 0 B", "folder 0 Docs", "pin 1 d1", "pin 1 d2", "pin 0 A", "folder 0 Work"])

        // B unpinned: what stood after it stays in its place.
        XCTAssertTrue(browser.move(group: kept.work, to: ColumnPlace(area: .kept, index: 1)))
        XCTAssertEqual(described(browser), ["pin 0 B", "folder 0 Work", "folder 0 Docs", "pin 1 d1", "pin 1 d2", "pin 0 A"])
        browser.unpin(b)
        XCTAssertEqual(saved(browser), ["w1 Work", "w2 Work", "w3 Work", "d1 Docs", "d2 Docs", "A"])
        XCTAssertEqual(described(browser), ["folder 0 Work", "folder 0 Docs", "pin 1 d1", "pin 1 d2", "pin 0 A"])
    }

    func testARowDroppedIntoAHeldFolderGoesAfterItsRows() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        let b = try XCTUnwrap(browser.tabs.first { $0.title == "B" })
        XCTAssertTrue(browser.move(b, to: ColumnPlace(area: .kept, group: kept.work)))
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B Work", "d1 Docs", "d2 Docs"])
        // Asleep at its page, it is let go with the others.
        browser.pinsChanged(in: browser.spaceID)
        XCTAssertEqual(rows(browser), ["A", "d1", "d2"])
        XCTAssertEqual(browser.heldRows(ofGroup: kept.work).map(\.title), ["w1", "w2", "w3", "B"])
    }

    func testTheSessionKeepsNoTabForAHeldRow() throws {
        let browser = makeBrowser()
        _ = try keep(browser)
        browser.writeSession(now: true)
        let entries = browser.readRow(browser.spaceID).tabs
        XCTAssertEqual(entries.compactMap { $0.pin == nil ? nil : $0.title }, ["A", "B", "d1", "d2"])

        // A row a session from before kept as a tab comes back as data.
        let w1 = try XCTUnwrap(Pins.defs(browser.spaceID).first { $0.title == "w1" })
        var shape = browser.readRow(browser.spaceID)
        shape.tabs.append(Session.Entry(url: w1.home, title: w1.title, pin: w1.letter, home: w1.home, pinID: w1.id, listed: true))
        browser.writeRow(browser.spaceID, shape, now: true)
        let again = makeBrowser()
        XCTAssertEqual(rows(again), ["A", "B", "d1", "d2"])
    }

    // MARK: - every window

    func testEveryWindowHoldsThemAndFollowsTheFold() throws {
        let first = makeBrowser()
        let kept = try keep(first)
        let second = makeBrowser()
        XCTAssertEqual(rows(second), ["A", "B", "d1", "d2"], "a window opened afterwards makes no tab for them")
        first.setGroupFolded(kept.work, false)
        XCTAssertEqual(rows(second), ["A", "w1", "w2", "w3", "B", "d1", "d2"])
        first.setGroupFolded(kept.work, true)
        XCTAssertEqual(rows(second), ["A", "B", "d1", "d2"])
        XCTAssertEqual(described(second), described(first))
    }

    // MARK: - still pins

    func testChromeBookmarksReadsAndChangesThem() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        let shelf = browser.pinShelf
        XCTAssertEqual(shelf.roots.first { $0.id == kept.work }?.children?.map(\.title), ["w1", "w2", "w3"])

        let w2 = try XCTUnwrap(Pins.defs(browser.spaceID).first { $0.title == "w2" })
        XCTAssertTrue(shelf.update(w2.id, title: "Renamed", url: nil))
        XCTAssertEqual(browser.heldRows(ofGroup: kept.work).map { $0.name ?? $0.title }, ["w1", "Renamed", "w3"])
        browser.writeSession(now: true)
        XCTAssertEqual(Pins.def(w2.id)?.name, "Renamed", "the window writes back what the store has, not what it read")

        let w1 = try XCTUnwrap(Pins.defs(browser.spaceID).first { $0.title == "w1" })
        shelf.remove(w1.id)
        browser.writeSession(now: true)
        XCTAssertNil(Pins.def(w1.id), "taken out elsewhere, never written back")

        let added = try XCTUnwrap(shelf.insert(Bookmark(title: "w4", url: "https://w4.example/", children: nil), into: kept.work))
        XCTAssertTrue(browser.holds(pin: added.id), "a row put in a folded folder comes in as data")
        XCTAssertEqual(rows(browser), ["A", "B", "d1", "d2"])
    }

    func testTheAddressFieldFindsAHeldRowAndOpensItInItsFolder() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        let offers = browser.openPages(matching: "w2")
        let offer = try XCTUnwrap(offers.first { $0.title.contains("w2.example") })
        let id = try XCTUnwrap(offer.tab)
        let pin = try XCTUnwrap(browser.heldPin(tab: id), "offered by the id its tab will have")
        XCTAssertTrue(browser.openPages(matching: "").allSatisfy { browser.heldPin(tab: $0.tab ?? UUID()) == nil },
                      "nothing typed, only what has been looked at")

        browser.take(offer)
        let tab = try XCTUnwrap(browser.active)
        XCTAssertEqual(tab.pinID, pin)
        XCTAssertEqual(tab.id, id, "made under the id it was offered by")
        XCTAssertEqual(browser.keptGroups.first { $0.id == kept.work }?.collapsed, true, "its folder stays folded")
        XCTAssertEqual(described(browser), ["pin 0 A", "folder 0 Work", "pin 1 w2", "pin 0 B", "folder 0 Docs",
                                            "pin 1 d1", "pin 1 d2"])
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "w2 Work", "w3 Work", "B", "d1 Docs", "d2 Docs"])
    }

    func testAHeldFolderKeepsItsNumberAndItsLinks() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        let targets = browser.tabShortcutTargets
        let at = try XCTUnwrap(targets.firstIndex { $0.id == kept.work })
        XCTAssertEqual(targets.count, 5, "A, Work, B and Docs' two rows")
        browser.select(index: at)
        XCTAssertEqual(browser.active?.title, "w1", "its first row, made a tab")
        XCTAssertEqual(browser.keptGroups.first { $0.id == kept.work }?.collapsed, true)

        XCTAssertEqual(browser.links(of: kept.work), ["https://w1.example/", "https://w2.example/", "https://w3.example/"])
    }

    /// In a folder half held, a row carried among its tabs in the column
    /// stays where it is let go, the held row after the tab it followed,
    /// rather than the folder written back in its old order.
    func testARowCarriedAmongAFolderHalfHeldStaysThere() throws {
        let browser = makeBrowser()
        let work = try halfHeld(browser)
        XCTAssertTrue(browser.move(try tab(browser, "w1"), to: ColumnPlace(area: .kept, group: work, index: 1)))
        XCTAssertEqual(saved(browser), ["A", "w3 Work", "w1 Work", "w2 Work", "B", "d1 Docs", "d2 Docs"], "w1 after w3")
        browser.pinsChanged(in: browser.spaceID)
        XCTAssertEqual(saved(browser), ["A", "w3 Work", "w1 Work", "w2 Work", "B", "d1 Docs", "d2 Docs"], "and stays")
        XCTAssertEqual(rows(browser), ["A", "w3", "w1", "B", "d1", "d2"])
        XCTAssertEqual(browser.heldRows(ofGroup: work).map(\.title), ["w2"], "w2 still held")
    }

    /// As chrome.tabs.move asks, a row of a folder half held goes exactly
    /// to the place of the row it is moved to, past a held row or not, as
    /// an extension sees the row; and the held row is data again after.
    func testARowMovedInAFolderHalfHeldGoesExactlyThere() throws {
        let browser = makeBrowser()
        let work = try halfHeld(browser)
        XCTAssertTrue(browser.moveRow(try tab(browser, "w1"), toRowOf: try tab(browser, "w3").id, forward: true))
        XCTAssertEqual(saved(browser), ["A", "w2 Work", "w3 Work", "w1 Work", "B", "d1 Docs", "d2 Docs"], "w1 past w2 and w3")
        XCTAssertEqual(browser.heldRows(ofGroup: work).map(\.title), ["w2"])
        let w2 = try XCTUnwrap(heldPin(browser, "w2"))
        XCTAssertTrue(browser.moveRow(try tab(browser, "w3"), toRowOf: browser.pinTabID(w2), forward: false))
        XCTAssertEqual(saved(browser), ["A", "w3 Work", "w2 Work", "w1 Work", "B", "d1 Docs", "d2 Docs"], "w3 up to w2's place")
        XCTAssertEqual(browser.placesInRow.count, 7)
    }

    /// A row from outside put in before a tab of a folder half held goes
    /// in right before it, carried in the column or moved by an extension.
    func testARowPutInBeforeATabOfAFolderHalfHeldGoesThere() throws {
        let browser = makeBrowser()
        let work = try halfHeld(browser)
        XCTAssertTrue(browser.move(try tab(browser, "B"), to: ColumnPlace(area: .kept, group: work, index: 0)))
        XCTAssertEqual(saved(browser), ["A", "B Work", "w1 Work", "w2 Work", "w3 Work", "d1 Docs", "d2 Docs"], "before w1")
        XCTAssertTrue(browser.move(try tab(browser, "A"), to: ColumnPlace(area: .kept, group: work, index: 2)))
        XCTAssertEqual(saved(browser), ["B Work", "w1 Work", "w2 Work", "A Work", "w3 Work", "d1 Docs", "d2 Docs"], "before w3")
        XCTAssertTrue(browser.moveRow(try tab(browser, "d1"), toRowOf: try tab(browser, "w3").id, forward: false))
        XCTAssertEqual(saved(browser), ["B Work", "w1 Work", "w2 Work", "A Work", "d1 Work", "w3 Work", "d2 Docs"],
                       "an extension's: right before w3")
        XCTAssertEqual(browser.heldRows(ofGroup: work).map(\.title), ["B", "w2", "A", "d1"],
                       "the rows put in, holding nothing their pins don't, held as data with w2")
    }

    /// A tab of a folder half held taken out of it, carried or moved by an
    /// extension, leaves the rest of the folder as it was.
    func testARowTakenOutOfAFolderHalfHeldLeavesItAsItWas() throws {
        let browser = makeBrowser()
        let work = try halfHeld(browser)
        // The top level: A, Work, B, Docs; after B.
        XCTAssertTrue(browser.move(try tab(browser, "w1"), to: ColumnPlace(area: .kept, index: 3)))
        XCTAssertEqual(saved(browser), ["A", "w2 Work", "w3 Work", "B", "w1", "d1 Docs", "d2 Docs"])
        XCTAssertTrue(browser.moveRow(try tab(browser, "w3"), toRowOf: try tab(browser, "A").id, forward: false))
        XCTAssertEqual(saved(browser), ["w3", "A", "w2 Work", "B", "w1", "d1 Docs", "d2 Docs"])
        XCTAssertEqual(browser.heldRows(ofGroup: work).map(\.title), ["w2"])
    }

    // MARK: - as they were while tabs

    /// The row of a folded folder looked at last is still the one ⌘1–9, the
    /// address field and the folder's card go by, held or not, across a
    /// relaunch too.
    func testTheRowLookedAtLastIsKeptWhileHeld() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        let w1 = try XCTUnwrap(heldPin(browser, "w1")), w3 = try XCTUnwrap(heldPin(browser, "w3"))
        let a = try XCTUnwrap(browser.tabs.first { $0.title == "A" })
        // w3 gone to and put down, then w1 earlier: w3 is the last looked at.
        try go(to: w1, in: browser, then: a)
        try go(to: w3, in: browser, then: a)
        XCTAssertEqual(rows(browser), ["A", "B", "d1", "d2"], "both held again")
        XCTAssertNotNil(browser.lookedAt(heldPin: w3))

        let at = try XCTUnwrap(browser.tabShortcutTargets.firstIndex { $0.id == kept.work })
        browser.select(index: at)
        XCTAssertEqual(browser.active?.pinID, w3, "⌘N goes to the row looked at last, not the first")
        browser.select(a)
        browser.closeTab(try XCTUnwrap(browser.tabs.first { $0.pinID == w3 }))

        let open = browser.openPages(matching: "")
        XCTAssertEqual(open.compactMap { $0.tab.flatMap(browser.heldPin(tab:)) }, [w3, w1],
                       "with nothing typed, the held rows looked at, the last first")

        // Written with the session, and read back by a window opened anew.
        browser.writeSession(now: true)
        let again = makeBrowser()
        XCTAssertEqual(rows(again), ["A", "B", "d1", "d2"])
        let target = try XCTUnwrap(again.tabShortcutTargets.firstIndex { $0.id == kept.work })
        again.select(index: target)
        XCTAssertEqual(again.active?.pinID, w3)
    }

    /// A page handed over by another device, or a link with Settings'
    /// "go to the tab that has it", goes to a held row of that page, made a
    /// tab, as it went to the row's tab, rather than opening a second.
    func testAPageFromElsewhereGoesToItsHeldRow() throws {
        let browser = makeBrowser()
        _ = try keep(browser)
        let w2 = try XCTUnwrap(heldPin(browser, "w2"))
        let url = try XCTUnwrap(URL(string: "https://w2.example/"))
        XCTAssertTrue(browser.openHere.contains(History.identity(for: url)), "open here, as its tab was")
        let count = browser.tabs.count
        // As Handoff hands it over (Links.continuing).
        let offer = Continuity.offer(url, title: "w2", info: nil)
        XCTAssertTrue(browser.open(offer) === browser)
        XCTAssertEqual(browser.active?.pinID, w2)
        XCTAssertEqual(browser.tabs.count, count + 1, "its tab made, and no other")
    }

    /// A tab held on to as its folder folded is its row's tab again when
    /// gone to, made under the same id; one not in the row at all is passed
    /// by.
    func testSelectingATabNoLongerInTheRow() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        browser.setGroupFolded(kept.work, false)
        let stale = try XCTUnwrap(browser.tabs.first { $0.title == "w2" })
        browser.setGroupFolded(kept.work, true)
        XCTAssertFalse(browser.tabs.contains { $0 === stale })
        browser.select(stale)
        let made = try XCTUnwrap(browser.active)
        XCTAssertFalse(made === stale)
        XCTAssertEqual(made.id, stale.id, "the same tab, by its id")
        XCTAssertEqual(made.pinID, stale.pinID)

        let a = try XCTUnwrap(browser.tabs.first { $0.title == "A" })
        browser.select(a)
        let stranger = Eden.Tab()
        stranger.restore(url: try XCTUnwrap(URL(string: "https://stranger.example/")), title: "Stranger")
        browser.select(stranger)
        XCTAssertEqual(browser.activeID, a.id, "a tab of no row isn't put in front")
    }

    /// A row in hand isn't let go to data while it is carried, though
    /// another window folds its folder meanwhile: the carry can still put
    /// it back where it was.
    func testACarriedRowIsKeptThroughAFold() throws {
        let first = makeBrowser()
        let kept = try keep(first)
        first.setGroupFolded(kept.work, false)
        let second = makeBrowser()
        let carried = try XCTUnwrap(first.tabs.first { $0.title == "w2" })
        let ticket = UUID()
        var ended = false
        CarryGuard.open(ticket, tab: carried.id, end: { ended = true })
        defer { CarryGuard.close(ticket) }
        second.setGroupFolded(kept.work, true)
        XCTAssertEqual(rows(first), ["A", "w2", "B", "d1", "d2"], "the others go to data, the one in hand stays")
        XCTAssertTrue(first.tabs.contains { $0 === carried })
        XCTAssertFalse(ended)
        CarryGuard.close(ticket)
        first.pinsChanged(in: first.spaceID)
        XCTAssertEqual(rows(first), ["A", "B", "d1", "d2"], "put down, it goes too")
    }

    /// Two windows on one space each offer a held row by the id its tab will
    /// have in that window, so the one it is taken from is the one it opens
    /// in.
    func testEachWindowOffersAHeldRowAsItsOwn() throws {
        let older = makeBrowser()
        _ = try keep(older)
        let front = makeBrowser()
        let mine = try XCTUnwrap(front.openPages(matching: "w2").first?.tab)
        let theirs = try XCTUnwrap(older.openPages(matching: "w2").first?.tab)
        XCTAssertNotEqual(mine, theirs)
        XCTAssertTrue(front.hasTab(mine))
        XCTAssertFalse(older.hasTab(mine))
        XCTAssertNotNil(front.openTab(mine))
        XCTAssertEqual(rows(front), ["A", "w2", "B", "d1", "d2"])
        XCTAssertEqual(rows(older), ["A", "B", "d1", "d2"], "the other window holds it still")
    }

    /// Extensions see a held row as a tab at rest at its page, in its place,
    /// under the id its tab has before and after the fold.
    func testAHeldRowKeepsItsPlaceAndIdInTheRow() throws {
        let browser = makeBrowser()
        let kept = try keep(browser)
        func described() -> [String] {
            browser.placesInRow.map { place in
                switch place {
                case .tab(let tab): tab.title
                case .held(let pin, _): "held " + (Pins.def(pin)?.title ?? "")
                }
            }
        }
        XCTAssertEqual(described().filter { !$0.isEmpty }, ["A", "held w1", "held w2", "held w3", "B", "d1", "d2"])
        let held = browser.placesInRow.map(\.id)
        browser.setGroupFolded(kept.work, false)
        XCTAssertEqual(browser.placesInRow.map(\.id), held, "made tabs under the ids they were held by")
        browser.setGroupFolded(kept.work, true)
        XCTAssertEqual(browser.placesInRow.map(\.id), held, "and held again by them")
    }

    /// A pinned row moved, as chrome.tabs.move asks, to a held row's place
    /// lands there, in its folder, before it moving up the row and after it
    /// moving down, and the folder's rows go back to data.
    func testARowMovedToAHeldRowsPlaceGoesThere() throws {
        let browser = makeBrowser()
        _ = try keep(browser)
        let w2 = try XCTUnwrap(heldPin(browser, "w2")), w3 = try XCTUnwrap(heldPin(browser, "w3"))
        let b = try XCTUnwrap(browser.tabs.first { $0.title == "B" })
        XCTAssertTrue(browser.moveRow(b, toRowOf: browser.pinTabID(w2), forward: false))
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "B Work", "w2 Work", "w3 Work", "d1 Docs", "d2 Docs"])
        XCTAssertEqual(rows(browser), ["A", "d1", "d2"], "the folder's rows, B among them now, data again")
        let a = try XCTUnwrap(browser.tabs.first { $0.title == "A" })
        XCTAssertTrue(browser.moveRow(a, toRowOf: browser.pinTabID(w3), forward: true))
        XCTAssertEqual(saved(browser), ["w1 Work", "B Work", "w2 Work", "w3 Work", "A Work", "d1 Docs", "d2 Docs"])
        let d1 = try XCTUnwrap(browser.tabs.first { $0.title == "d1" })
        XCTAssertFalse(browser.moveRow(d1, toRowOf: UUID(), forward: true), "nowhere to go")
    }

    /// What an extension is told of the row, by the shim's own calls: held
    /// rows in their places, by the ids their tabs have, at their pages,
    /// each place read once a query; and a row moved to a held row's place
    /// goes there.
    func testAnExtensionReadsAndMovesAmongHeldRows() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("extensions need macOS 15.4") }
        let browser = makeBrowser()
        Browsers.register(browser)
        defer { Browsers.discard(browser) }
        _ = try keep(browser)
        let (folder, context) = try await extensionContext()
        defer { try? FileManager.default.removeItem(at: folder) }
        let owner = Extensions.shared
        let rows = owner.visibleRows(of: browser, for: context)
        XCTAssertEqual(rows.map(\.id), browser.placesInRow.map(\.id))
        XCTAssertEqual(rows.map { $0.indexInWindow(for: context) }, Array(rows.indices))
        let w2 = try XCTUnwrap(heldPin(browser, "w2"))
        let at = try XCTUnwrap(rows.firstIndex { $0.id == browser.pinTabID(w2) })
        XCTAssertNil(rows[at].tab, "held, it has no tab")

        let described = try await ExtensionShims.answer(["api": "tabs.describe", "args": [Array(rows.indices)]],
                                                        from: context, owner: owner) as? [String: Any]
        let urls = (described?["value"] as? [Any])?.compactMap { ($0 as? [String: Any])?["url"] as? String } ?? []
        XCTAssertEqual(urls.filter { $0.hasPrefix("https://w") }, ["https://w1.example/", "https://w2.example/", "https://w3.example/"])

        let b = try XCTUnwrap(rows.firstIndex { $0.tab?.title == "B" })
        let moved = try await ExtensionShims.answer(["api": "tabs.move", "args": [b, at]], from: context, owner: owner) as? [String: Any]
        XCTAssertNil(moved?["error"], "\(String(describing: moved))")
        XCTAssertEqual(saved(browser), ["A", "w1 Work", "B Work", "w2 Work", "w3 Work", "d1 Docs", "d2 Docs"])
    }

    /// An extension acting on a held row taken out of the pins meanwhile,
    /// elsewhere, is told there is no such tab, rather than nothing done
    /// and said to be.
    func testAnExtensionActingOnARowGoneIsToldSo() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("extensions need macOS 15.4") }
        let browser = makeBrowser()
        Browsers.register(browser)
        defer { Browsers.discard(browser) }
        _ = try keep(browser)
        let (folder, context) = try await extensionContext()
        defer { try? FileManager.default.removeItem(at: folder) }
        let w2 = try XCTUnwrap(heldPin(browser, "w2"))
        let row = try XCTUnwrap(Extensions.shared.visibleRows(of: browser, for: context).first { $0.id == browser.pinTabID(w2) })
        browser.pinShelf.remove(w2)
        do {
            try await row.activate(for: context)
            XCTFail("activated a row that is gone")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No tab with that id.")
        }
        do {
            try await row.reload(fromOrigin: false, for: context)
            XCTFail("reloaded a row that is gone")
        } catch {}
    }

    /// An adapter is right as soon as its row is made a tab or let go,
    /// not when the row is next followed: a held row unpinned by one call
    /// is found by the next as the tab it is now, unpinned, and a row made
    /// a tab and unpinned in the column reads so at once.
    func testAnExtensionsRowIsRightAtOnceWhateverChangesIt() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("extensions need macOS 15.4") }
        let browser = makeBrowser()
        Browsers.register(browser)
        defer { Browsers.discard(browser) }
        _ = try keep(browser)
        let (folder, context) = try await extensionContext()
        defer { try? FileManager.default.removeItem(at: folder) }
        func row(_ title: String) throws -> ExtensionTab {
            let pin = try XCTUnwrap(heldPin(browser, title), title)
            return try XCTUnwrap(Extensions.shared.visibleRows(of: browser, for: context).first { $0.id == browser.pinTabID(pin) })
        }
        let w1 = try row("w1")
        XCTAssertEqual(Extensions.shared.heldShown[w1.id]?.address, "https://w1.example/",
                       "what it shows kept from the first, so its first change is told")
        try await w1.setPinned(false, for: context)
        XCTAssertFalse(w1.isPinned(for: context), "unpinned, at once")
        let url = try XCTUnwrap(URL(string: "https://w1-next.example/"))
        try await w1.loadURL(url, for: context)
        XCTAssertEqual(browser.tabs.first { $0.id == w1.id }?.pin, nil, "the same tab, a pin no more")

        let w2 = try row("w2")
        let pin = try XCTUnwrap(heldPin(browser, "w2"))
        let tab = try XCTUnwrap(browser.showHeld(pin))
        browser.unpin(tab)
        XCTAssertFalse(w2.isPinned(for: context), "made a tab and unpinned in the column, read so at once")
        XCTAssertFalse(w2.isHeld)

        // Folded again, a tab holding nothing is held again, at once too.
        let w3 = try row("w3")
        let made = try XCTUnwrap(w3.actingTab())
        XCTAssertFalse(w3.isHeld)
        XCTAssertTrue(made.holdsNothing)
        browser.pinsChanged(in: browser.spaceID)
        XCTAssertTrue(w3.isHeld, "let go to data, held at once")
    }

    /// chrome.tabs.group with a held row among the tabs fails whole, as it
    /// does with that row's tab, a pin: none of them grouped.
    func testGroupingAHeldRowFailsAsItsTabWould() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("extensions need macOS 15.4") }
        let browser = makeBrowser(groups: true)
        Browsers.register(browser)
        defer { Browsers.discard(browser) }
        _ = try keep(browser)
        let url = try XCTUnwrap(URL(string: "https://loose.example/"))
        let loose = browser.open(url, foreground: false, atEnd: true)
        loose.restore(url: url, title: "loose")
        let (folder, context) = try await extensionContext()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rows = Extensions.shared.visibleRows(of: browser, for: context)
        let w2 = try XCTUnwrap(heldPin(browser, "w2"))
        let held = try XCTUnwrap(rows.firstIndex { $0.id == browser.pinTabID(w2) })
        let open = try XCTUnwrap(rows.firstIndex { $0.tab === loose })
        let reply = try await ExtensionShims.answer(["api": "tabs.group", "args": [[open, held], -1]], from: context, owner: Extensions.shared)
            as? [String: Any]
        XCTAssertNotNil(reply?["error"], "\(String(describing: reply))")
        XCTAssertNil(loose.groupID, "the loose tab left out of any group too")
        XCTAssertTrue(browser.tabGroups.isEmpty)
        XCTAssertTrue(browser.holds(pin: w2), "and the row held still")
    }

    func testFolderTakenAwayOrCarriedBelowTheLineMakesItsRowsTabs() throws {
        let browser = makeBrowser(groups: true)
        let kept = try keep(browser)
        browser.ungroupKept(kept.work)
        XCTAssertEqual(rows(browser), ["A", "w1", "w2", "w3", "B", "d1", "d2"])
        XCTAssertEqual(saved(browser), ["A", "w1", "w2", "w3", "B", "d1 Docs", "d2 Docs"], "out of it, where it stood")

        browser.setGroupFolded(kept.docs, true)
        XCTAssertEqual(rows(browser), ["A", "w1", "w2", "w3", "B"])
        XCTAssertTrue(browser.takes(group: kept.docs, at: ColumnPlace(area: .open)))
        XCTAssertTrue(browser.move(group: kept.docs, to: ColumnPlace(area: .open)))
        XCTAssertEqual(browser.tabs(in: kept.docs).map(\.title), ["d1", "d2"], "its rows open tabs in an open group")
        XCTAssertFalse(saved(browser).contains { $0.hasPrefix("d") })
    }

    // MARK: - working it out

    /// A row's tabs found for its pins as reconcilePins always looked for
    /// them, each way indexed once: by id, a tab whose pin merged into this
    /// one by its page, one from before ids by letter and page, then by
    /// place; none taken twice, and those left over left.
    func testPinnedTabsAreFoundEachWayOnce() throws {
        func tab(_ pin: UUID?, letter: String, home: String) throws -> Eden.Tab {
            let tab = Eden.Tab()
            tab.pinID = pin
            tab.pin = letter
            tab.home = try XCTUnwrap(URL(string: home))
            return tab
        }
        let p1 = UUID(), p2 = UUID(), p3 = UUID(), p4 = UUID(), gone = UUID()
        let byID = try tab(p1, letter: "A", home: "https://a.example/")
        let merged = try tab(gone, letter: "B", home: "https://b.example/")
        let lettered = try tab(nil, letter: "C", home: "https://c.example/")
        let placed = try tab(nil, letter: "D", home: "https://d.example/")
        let spare = try tab(UUID(), letter: "E", home: "https://e.example/")
        func def(_ id: UUID, _ letter: String, _ home: String) -> PinDef {
            PinDef(id: id, letter: letter, home: home, title: letter, name: nil)
        }
        var found = PinnedTabs([placed, lettered, merged, byID, spare], live: [p1, p2, p3, p4, spare.pinID ?? UUID()])
        XCTAssertTrue(found.take(for: def(p1, "A", "https://a.example/"), home: URL(string: "https://a.example/")) === byID)
        XCTAssertTrue(found.take(for: def(p2, "B", "https://b.example"), home: URL(string: "https://b.example")) === merged,
                      "the same page, its trailing slash aside")
        XCTAssertTrue(found.take(for: def(p3, "C", "https://c.example/"), home: URL(string: "https://c.example/")) === lettered)
        XCTAssertTrue(found.take(for: def(p4, "Z", "https://z.example/"), home: URL(string: "https://z.example/")) === placed)
        XCTAssertNil(found.take(for: def(UUID(), "Y", "https://y.example/"), home: URL(string: "https://y.example/")))
        XCTAssertEqual(found.left.map(\.id), [spare.id])
    }

    func testHeldGroupsStandAfterTheRowBeforeThem() {
        let work = TabGroup(id: UUID(), name: "Work", collapsed: true)
        let docs = TabGroup(id: UUID(), name: "Docs", collapsed: true)
        let open = TabGroup(id: UUID(), name: "Open", collapsed: false)
        let a = def("A"), w1 = def("w1", work.id), w2 = def("w2", work.id), d1 = def("d1", docs.id)
        let o1 = def("o1", open.id), b = def("B")
        let rows = [a, w1, w2, d1, o1, b]
        let held = HeldPins.hold(rows, groups: [work, docs, open]) { $0.group != work.id && $0.group != docs.id }
        XCTAssertEqual(held, [
            HeldGroup(id: work.id, rows: [w1.id, w2.id], held: [w1.id, w2.id], stands: .after(a.id)),
            HeldGroup(id: docs.id, rows: [d1.id], held: [d1.id], stands: .after(a.id)),
        ])
        // Shown, they are drawn where they stood; written, their rows are
        // back where they were.
        let shown = [a, o1, b]
        let items = HeldPins.items(shown, pin: \.id, group: \.group, groups: [work, docs, open], held: held)
        XCTAssertEqual(items.map { $0.group?.name ?? $0.tabs.first?.title ?? "" }, ["A", "Work", "Docs", "Open", "B"])
        XCTAssertEqual(HeldPins.merged(shown, held: held, stored: rows, groups: [work, docs, open]).pins.map(\.title),
                       rows.map(\.title))

        // One row of a held folder shown: it stands where its tab does,
        // in its place among the rows held.
        let partly = HeldPins.hold(rows, groups: [work, docs, open]) { $0.id != w1.id && $0.group != docs.id }
        XCTAssertEqual(partly.first, HeldGroup(id: work.id, rows: [w1.id, w2.id], held: [w1.id], stands: nil))
        XCTAssertEqual(HeldPins.merged([a, w2, o1, b], held: partly, stored: rows, groups: [work, docs, open]).pins.map(\.title),
                       rows.map(\.title))
    }

    func testAHeldGroupWhoseRowIsGoneStandsAfterTheOneBeforeIt() {
        let work = TabGroup(id: UUID(), name: "Work", collapsed: true)
        let a = def("A"), b = def("B"), w1 = def("w1", work.id), c = def("C")
        let stored = [a, b, w1, c]
        let held = [HeldGroup(id: work.id, rows: [w1.id], held: [w1.id], stands: .after(b.id))]
        let resolved = HeldPins.resolved(held, present: [a.id, c.id], folders: [:], groups: [work]) { stored }
        XCTAssertEqual(resolved.first?.stands, .after(a.id))
        XCTAssertEqual(HeldPins.resolved(held, present: [c.id], folders: [:], groups: [work]) { stored }.first?.stands, .first)
        // Its group gone meanwhile: its rows stay, where it stood.
        XCTAssertEqual(HeldPins.merged([a, c], held: held, stored: stored, groups: []).pins.map(\.title), ["A", "w1", "C"])
        // Taken out elsewhere: gone.
        XCTAssertEqual(HeldPins.merged([a, b, c], held: held, stored: [a, b, c], groups: [work]).pins.map(\.title), ["A", "B", "C"])
    }

    // MARK: - the pieces

    /// An extension's context, as Eden installs one, with the tabs and
    /// tab groups permissions.
    @available(macOS 15.4, *)
    private func extensionContext() async throws -> (URL, WKWebExtensionContext) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("held-pins-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Held rows", "version": "1",
                                       "permissions": ["tabs", "tabGroups"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.uniqueIdentifier = "held-pins-\(UUID().uuidString)"
        context.setPermissionStatus(.grantedExplicitly, for: .tabs)
        return (folder, context)
    }

    /// The pin of a held row by its title.
    private func heldPin(_ browser: Browser, _ title: String) -> UUID? {
        browser.heldRows.first { $0.title == title }?.id
    }

    /// A held row gone to, then put down out of sight from `back`.
    private func go(to pin: UUID, in browser: Browser, then back: Eden.Tab) throws {
        let tab = try XCTUnwrap(browser.showHeld(pin))
        browser.select(tab)
        browser.select(back)
        browser.closeTab(tab)
    }

    private func def(_ title: String, _ group: UUID? = nil) -> PinDef {
        PinDef(id: UUID(), letter: String(title.prefix(1)).uppercased(), home: "https://\(title.lowercased()).example/",
               title: title, name: nil, listed: true, group: group)
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

    private func makeBrowser(groups: Bool = false) -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        if restorePreferences == nil {
            let previous = (prefs.usesTabGroups, prefs.sharesPins)
            restorePreferences = { (prefs.usesTabGroups, prefs.sharesPins) = previous }
        }
        prefs.usesTabGroups = groups
        prefs.sharesPins = false
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browsers.append(browser)
        return browser
    }
}
