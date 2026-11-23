import AppKit
import EdenCore
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
        XCTAssertEqual(Tab.live.allObjects.filter { $0.pinID.map(browser.holds(pin:)) == true }.count, 0,
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
        let pin = try XCTUnwrap(offer.tab)
        XCTAssertTrue(browser.holds(pin: pin))
        XCTAssertTrue(browser.openPages(matching: "").allSatisfy { !browser.holds(pin: $0.tab ?? UUID()) },
                      "nothing typed, only what is open")

        browser.take(offer)
        let tab = try XCTUnwrap(browser.active)
        XCTAssertEqual(tab.pinID, pin)
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

    /// A row from outside put in before a tab of a folder half held goes
    /// in right before it.
    func testARowPutInBeforeATabOfAFolderHalfHeldGoesThere() throws {
        let browser = makeBrowser()
        let work = try halfHeld(browser)
        XCTAssertTrue(browser.move(try tab(browser, "B"), to: ColumnPlace(area: .kept, group: work, index: 0)))
        XCTAssertEqual(saved(browser), ["A", "B Work", "w1 Work", "w2 Work", "w3 Work", "d1 Docs", "d2 Docs"], "before w1")
        XCTAssertTrue(browser.move(try tab(browser, "A"), to: ColumnPlace(area: .kept, group: work, index: 2)))
        XCTAssertEqual(saved(browser), ["B Work", "w1 Work", "w2 Work", "A Work", "w3 Work", "d1 Docs", "d2 Docs"], "before w3")
        XCTAssertTrue(browser.heldRows(ofGroup: work).contains { $0.title == "w2" }, "w2 still held")
    }

    /// A tab of a folder half held taken out of it leaves the rest of the
    /// folder where it was.
    func testARowTakenOutOfAFolderHalfHeldLeavesItAsItWas() throws {
        let browser = makeBrowser()
        let work = try halfHeld(browser)
        // The top level: A, Work, B, Docs; after B.
        XCTAssertTrue(browser.move(try tab(browser, "w1"), to: ColumnPlace(area: .kept, index: 3)))
        XCTAssertEqual(saved(browser), ["A", "w2 Work", "w3 Work", "B", "w1", "d1 Docs", "d2 Docs"])
        XCTAssertTrue(browser.move(try tab(browser, "w3"), to: ColumnPlace(area: .kept, index: 0)))
        XCTAssertEqual(saved(browser), ["w3", "A", "w2 Work", "B", "w1", "d1 Docs", "d2 Docs"], "Work where it stood")
        XCTAssertEqual(browser.heldRows(ofGroup: work).map(\.title), ["w2"])
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
