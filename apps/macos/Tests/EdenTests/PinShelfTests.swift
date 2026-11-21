import AppKit
import EdenCore
import XCTest
@testable import Eden

/// A space's kept area, its pinned rows and kept groups, as a tree of
/// bookmarks (PinShelf): what chrome.bookmarks reads and changes, what
/// bookmarks come in as, and the bookmarks you had, brought into pins once
/// (#6), at the top level, their folders as kept groups, one level deep as
/// every group is. Each test works in a space of its own, no window shows,
/// so only pins.json and kept-groups.json are touched.
@MainActor
final class PinShelfTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "pin-shelf-\(getpid())", 1)
        super.setUp()
    }

    private var browser: Browser?
    private var spaces: [UUID] = []

    override func tearDown() async throws {
        for space in spaces { Pins.forget(space) }
        spaces.removeAll()
        browser?.closeAll()
        browser = nil
        // The saved window and anything else left for the suite after
        // (CleanWorld).
        CleanWorld.reset()
        try await super.tearDown()
    }

    // MARK: - reading

    func testTreeIsTheKeptAreaAsDrawnWithoutSquares() throws {
        let (shelf, ids) = try made()
        XCTAssertEqual(describe(shelf.roots), [
            "Named a https://a.example/", "Work/", "  b https://b.example/", "Inner/", "  c https://c.example/",
            "d https://d.example/",
        ], "each group where its first row stands, with its rows; a row whose group is gone at the top; no square")
        let work = try XCTUnwrap(shelf.roots.dropFirst().first)
        XCTAssertEqual(work.id, ids.work, "a folder is its kept group")
        XCTAssertEqual(shelf.roots.last?.id, ids.d, "a row is its PinDef")
        XCTAssertEqual(shelf.roots[0].title, "Named a", "a row reads as the name it was given")
        XCTAssertEqual(shelf.parent(of: ids.c), ids.inner)
        XCTAssertNil(shelf.parent(of: ids.inner), "every folder is at the top")
        XCTAssertNil(shelf.parent(of: ids.a))
        XCTAssertNil(shelf.parent(of: ids.square), "a square isn't in the tree")
    }

    // MARK: - changing

    func testInsert() throws {
        let (shelf, ids) = try made()
        // An index at the top is the place itself, rows and groups alike.
        let site = try XCTUnwrap(shelf.insert(.site("New", try XCTUnwrap(URL(string: "https://www.new.example/x"))),
                                              into: nil, at: 2))
        XCTAssertEqual(shelf.roots.map(\.title), ["Named a", "Work", "New", "Inner", "d"])
        let def = try XCTUnwrap(Pins.defs(shelf.space).first { $0.id == site.id })
        XCTAssertEqual(def.listed, true)
        XCTAssertEqual(def.letter, "N")
        XCTAssertEqual(def.home, "https://www.new.example/x")
        XCTAssertNil(def.group)
        // Into a folder, at its end; into one that isn't there, at the top.
        shelf.insert(.site("In work", try XCTUnwrap(URL(string: "https://w.example/"))), into: ids.work)
        XCTAssertEqual(shelf.roots[1].children?.map(\.title), ["b", "In work"])
        shelf.insert(.site("Lost", try XCTUnwrap(URL(string: "https://lost.example/"))), into: UUID())
        XCTAssertEqual(shelf.roots.last?.title, "Lost")
        // A folder, before the others; never inside another.
        let folder = try XCTUnwrap(shelf.insert(.folder("Top", []), into: nil, at: 0))
        XCTAssertEqual(shelf.roots.first?.id, folder.id)
        XCTAssertNil(shelf.insert(.folder("Inside", []), into: ids.work), "one level, as tab groups")
        XCTAssertFalse(Pins.groups(shelf.space).contains { $0.name == "Inside" })
        XCTAssertNotNil(shelf.insert(.folder("", []), into: nil), "a folder always has a name")
        // Empty, it stands after the group before it.
        XCTAssertEqual(shelf.roots.last { $0.isFolder }?.title, "New Folder")
        // One holding folders: their pages in it, in order.
        let nested = try XCTUnwrap(shelf.insert(.folder("Nested", [
            .site("x", try XCTUnwrap(URL(string: "https://x.example/"))),
            .folder("Deeper", [.site("y", try XCTUnwrap(URL(string: "https://y.example/")))]),
            .site("z", try XCTUnwrap(URL(string: "https://z.example/"))),
        ]), into: nil))
        XCTAssertEqual(nested.children?.map(\.title), ["x", "y", "z"])
        XCTAssertEqual(shelf.roots.last?.id, nested.id, "where it was put, at the end, its rows with it")
        XCTAssertFalse(Pins.groups(shelf.space).contains { $0.name == "Deeper" })
        // Only a page can be pinned.
        XCTAssertNil(shelf.insert(Bookmark(title: "Script", url: "javascript:alert(1)", children: nil), into: nil))
        XCTAssertTrue(Pins.defs(shelf.space).contains { $0.id == ids.square }, "the square is kept")
    }

    func testUpdate() throws {
        let (shelf, ids) = try made()
        shelf.update(ids.b, title: "Bee", url: "https://bee.example/")
        let b = try XCTUnwrap(Pins.defs(shelf.space).first { $0.id == ids.b })
        XCTAssertEqual(b.name, "Bee")
        XCTAssertEqual(b.home, "https://bee.example/")
        shelf.update(ids.b, title: "", url: nil)
        XCTAssertNil(Pins.defs(shelf.space).first { $0.id == ids.b }?.name, "emptied: the page's own title")
        shelf.update(ids.b, title: nil, url: "javascript:void(0)")
        XCTAssertEqual(Pins.defs(shelf.space).first { $0.id == ids.b }?.home, "https://bee.example/", "never a script")
        shelf.update(ids.work, title: "Job", url: "https://ignored.example/")
        XCTAssertEqual(Pins.groups(shelf.space).first { $0.id == ids.work }?.name, "Job")
        shelf.update(ids.work, title: "  ", url: nil)
        XCTAssertEqual(Pins.groups(shelf.space).first { $0.id == ids.work }?.name, "Job", "a folder keeps its name")
    }

    func testMove() throws {
        let (shelf, ids) = try made()
        // d up between a and Work.
        XCTAssertTrue(shelf.move(ids.d, into: nil, at: 1))
        XCTAssertEqual(shelf.roots.map(\.title), ["Named a", "d", "Work", "Inner"])
        // Just below itself, counted before the move: where it was.
        shelf.move(ids.d, into: nil, at: 2)
        XCTAssertEqual(shelf.roots.map(\.title), ["Named a", "d", "Work", "Inner"])
        // A folder among the rows, at its place.
        XCTAssertTrue(shelf.move(ids.inner, into: nil, at: 0))
        XCTAssertEqual(shelf.roots.map(\.title), ["Inner", "Named a", "d", "Work"])
        // Into a folder, first among its rows.
        shelf.move(ids.a, into: ids.inner, at: 0)
        XCTAssertEqual(Pins.defs(shelf.space).first { $0.id == ids.a }?.group, ids.inner)
        XCTAssertEqual(shelf.roots[0].children?.map(\.title), ["Named a", "c"])
        // Out to the top, at its end.
        shelf.move(ids.c, into: nil)
        XCTAssertEqual(shelf.roots.last?.title, "c")
        XCTAssertNil(Pins.defs(shelf.space).first { $0.id == ids.c }?.group)
        // A folder never into a folder, itself included: refused, as
        // chrome.bookmarks is told.
        XCTAssertFalse(shelf.move(ids.work, into: ids.inner))
        XCTAssertFalse(shelf.move(ids.work, into: ids.work))
        XCTAssertEqual(shelf.roots.filter(\.isFolder).map(\.id), [ids.inner, ids.work])
        // Along the top, past the other.
        XCTAssertTrue(shelf.move(ids.work, into: nil, at: 0))
        XCTAssertEqual(shelf.roots.filter(\.isFolder).map(\.id), [ids.work, ids.inner])
        // Into something that isn't a folder: nothing.
        shelf.move(ids.d, into: ids.c)
        XCTAssertNil(shelf.parent(of: ids.d))
    }

    func testRemove() throws {
        let (shelf, ids) = try made()
        shelf.remove(ids.work)
        XCTAssertEqual(shelf.roots.map(\.title), ["Named a", "Inner", "d"])
        XCTAssertFalse(Pins.defs(shelf.space).contains { $0.id == ids.b }, "its rows went with it")
        XCTAssertTrue(Pins.defs(shelf.space).contains { $0.id == ids.c }, "another folder's stayed")
        shelf.remove(ids.a)
        XCTAssertEqual(shelf.roots.map(\.title), ["Inner", "d"])
        shelf.remove(ids.square)
        XCTAssertTrue(Pins.defs(shelf.space).contains { $0.id == ids.square }, "a square isn't the tree's to remove")
    }

    /// A space keeps one pin of a page: a page pinned here comes back as
    /// its row, moved only when a folder is asked for, never a second.
    func testInsertingAPagePinnedAlreadyGivesItsRow() throws {
        let (shelf, ids) = try made()
        let count = Pins.defs(shelf.space).count
        let again = shelf.insert(.site("A again", try XCTUnwrap(URL(string: "https://a.example"))), into: nil, at: 0)
        XCTAssertEqual(again?.id, ids.a)
        XCTAssertEqual(Pins.defs(shelf.space).count, count, "no second pin")
        XCTAssertNil(shelf.parent(of: ids.a), "left where it was")
        let moved = shelf.insert(.site("A", try XCTUnwrap(URL(string: "https://a.example/"))), into: ids.work)
        XCTAssertEqual(moved?.id, ids.a)
        XCTAssertEqual(shelf.parent(of: ids.a), ids.work, "a folder asked for: moved there")
        XCTAssertNil(shelf.insert(.site("Square", try XCTUnwrap(URL(string: "https://square.example/"))), into: nil),
                     "a square's page is pinned already, not as a row")
        XCTAssertEqual(Pins.defs(shelf.space).count, count)
    }

    func testReplaceTakesOutAPinMadeSharedSince() throws {
        let (shelf, _) = try made()
        let browser = try XCTUnwrap(self.browser)
        let before = Pins.shared(browser.profileID)
        defer { Pins.setShared(before, from: browser) }
        let taken = shelf.take([.site("Shared later", try XCTUnwrap(URL(string: "https://shared-later.example/")))], into: "Chrome")
        let row = try XCTUnwrap(Pins.defs(shelf.space).first { taken.ids.contains($0.id) })
        // Made a pin every space shows, as Pin › In Every Space does.
        Pins.set(shelf.space, Pins.defs(shelf.space).filter { $0.id != row.id }, from: browser)
        Pins.setShared(before + [row], from: browser)
        XCTAssertEqual(PinShelf.withdraw(taken.ids, via: browser).rows, 1)
        XCTAssertFalse(Pins.shared(browser.profileID).contains { $0.id == row.id })
    }

    // MARK: - bookmarks brought in

    func testTakePutsEveryPageInOneFolderInOrderAndSkipsWhatIsPinned() throws {
        let (shelf, _) = try made()
        func site(_ title: String, _ url: String) throws -> Bookmark { .site(title, try XCTUnwrap(URL(string: url))) }
        let tree: [Bookmark] = [
            try site("Loose", "https://loose.example/"),
            try site("Pinned already", "https://a.example/deeper/page"),
            try site("Twice", "https://twice.example/"),
            .folder("One", [
                try site("Twice again", "https://twice.example"),
                .folder("Two", [
                    .folder("Three", [try site("Three down", "https://three.example/")]),
                    try site("Two down", "https://two.example/"),
                ]),
                .folder("Empty", []),
                .folder("Nothing new", [try site("B again", "https://b.example/")]),
            ]),
            Bookmark(title: "Bookmarklet", url: "javascript:void(0)", children: nil),
        ]
        let taken = shelf.take(tree, into: "Chrome")
        XCTAssertEqual(taken.added, 5)
        XCTAssertEqual(taken.already, 2, "a page pinned here, or twice in what came")
        XCTAssertEqual(describe(shelf.roots.filter { $0.title == "Chrome" }), [
            "Chrome/", "  Loose https://loose.example/", "  Pinned already https://a.example/deeper/page",
            "  Twice https://twice.example/", "  Three down https://three.example/", "  Two down https://two.example/",
        ], "every page in the one folder, in the order it came; a page under a pin of its site comes")
        let folders = Pins.groups(shelf.space)
        XCTAssertFalse(folders.contains { ["One", "Two", "Three", "Empty", "Nothing new"].contains($0.name) }, "no folder inside")
        let rows = Pins.defs(shelf.space).filter { ["Loose", "Pinned already", "Twice", "Three down", "Two down"].contains($0.name ?? "") }
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(Set(taken.ids), Set(rows.map(\.id) + folders.filter { $0.name == "Chrome" }.map(\.id)),
                       "every row made and its folder, and only those")
        // Again: nothing twice, the same folder gone into.
        let again = shelf.take(tree, into: "chrome")
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.already, 7)
        XCTAssertEqual(shelf.roots.filter { $0.title.lowercased() == "chrome" }.count, 1)

        // Taken back out, but a folder you put a row of your own in stays.
        let chrome = try XCTUnwrap(folders.first { $0.name == "Chrome" })
        let mine = try XCTUnwrap(shelf.insert(try site("Mine", "https://mine.example/"), into: chrome.id))
        let browser = try XCTUnwrap(self.browser)
        XCTAssertEqual(PinShelf.withdraw(taken.ids, via: browser).rows, 5)
        XCTAssertTrue(Pins.groups(shelf.space).contains { $0.id == chrome.id }, "it holds Mine")
        XCTAssertEqual(shelf.roots.first { $0.id == chrome.id }?.children?.map(\.id), [mine.id])
    }

    func testTheSharedPinsCountAsPinned() throws {
        let (shelf, _) = try made()
        let browser = try XCTUnwrap(self.browser)
        let before = Pins.shared(browser.profileID)
        defer { Pins.setShared(before, from: browser) }
        Pins.setShared(before + [PinDef(id: UUID(), letter: "S", home: "https://shared.example/", title: "Shared")], from: browser)
        let taken = shelf.take([.site("Shared page", try XCTUnwrap(URL(string: "https://shared.example")))], into: "Safari")
        XCTAssertEqual(taken.added, 0)
        XCTAssertEqual(taken.already, 1)
        XCTAssertFalse(shelf.roots.contains { $0.title == "Safari" }, "nothing in it: no folder")
    }

    /// A site pinned at its root doesn't cover its other pages: a
    /// bookmark of one comes as a pin of its own, as sync keeps it
    /// (PinDef.page, SyncItems.onePerPage); only the same page doesn't.
    func testARootPinDoesNotCoverTheSitesOtherPages() throws {
        let (shelf, _) = try made()
        let browser = try XCTUnwrap(self.browser)
        Pins.set(shelf.space, Pins.defs(shelf.space) + [PinDef(id: UUID(), letter: "E", home: "https://example.com/", title: "Example")],
                 from: browser)
        let taken = shelf.take([.site("Article", try XCTUnwrap(URL(string: "https://example.com/article"))),
                                .site("Home", try XCTUnwrap(URL(string: "https://example.com")))], into: "Firefox")
        XCTAssertEqual(taken.added, 1)
        XCTAssertEqual(taken.already, 1, "the root page itself is pinned")
        XCTAssertTrue(Pins.defs(shelf.space).contains { $0.home == "https://example.com/article" })
    }

    /// An import's record is kept by the browser's name: Replace in another
    /// profile never takes this profile's pins out.
    func testReplaceInAnotherProfileLeavesThisOnesPins() throws {
        let (shelf, _) = try made()
        let browser = try XCTUnwrap(self.browser)
        let taken = shelf.take([.site("Here", try XCTUnwrap(URL(string: "https://here-only.example/")))], into: "Chrome")
        XCTAssertEqual(taken.added, 1)
        let other = Profiles.shared.add(named: "Elsewhere \(UUID().uuidString.prefix(6))")
        let elsewhere = Browser(record: WindowRecord(space: other.home))
        defer {
            elsewhere.closeAll()
            Profiles.shared.delete(other.id)
        }
        XCTAssertEqual(elsewhere.profileID, other.id)
        // Replace in the other profile first: nothing of this one's goes,
        // and every id stays to be taken out where it is.
        let there = PinShelf.withdraw(taken.ids, via: elsewhere)
        XCTAssertEqual(there.rows, 0)
        XCTAssertEqual(Set(there.left), Set(taken.ids), "the row and its folder, still pinned in this profile")
        XCTAssertTrue(Pins.defs(shelf.space).contains { $0.home == "https://here-only.example/" }, "untouched")
        // Then in this profile: they go, and nothing is left to record.
        let here = PinShelf.withdraw(there.left, via: browser)
        XCTAssertEqual(here.rows, 1, "Replace in its own profile still takes it out")
        XCTAssertTrue(here.left.isEmpty)
        XCTAssertFalse(Pins.defs(shelf.space).contains { $0.home == "https://here-only.example/" })
    }

    /// A space keeps one pin of a page: a row's address changed to another
    /// pin's is refused, and the row is left as it was.
    func testUpdatingToAnotherPinsPageIsRefused() throws {
        let (shelf, ids) = try made()
        let browser = try XCTUnwrap(self.browser)
        let before = Pins.shared(browser.profileID)
        defer { Pins.setShared(before, from: browser) }
        Pins.setShared(before + [PinDef(id: UUID(), letter: "S", home: "https://every-space.example/", title: "Shared")], from: browser)
        let row = { Pins.defs(shelf.space).first { $0.id == ids.b } }
        let was = try XCTUnwrap(row())
        for taken in ["https://a.example", "https://square.example/", "https://every-space.example/"] {
            XCTAssertFalse(shelf.update(ids.b, title: "Renamed", url: taken), taken)
            XCTAssertEqual(row(), was, "left as it was: \(taken)")
        }
        XCTAssertTrue(shelf.update(ids.b, title: nil, url: "https://b.example/other"))
        XCTAssertEqual(row()?.home, "https://b.example/other")
    }

    // MARK: - the bookmarks you had

    func testBookmarksComeOverAsTheyArriveAndOnlyOnce() throws {
        try withHome { browser, list, home in
            // Nothing yet: nothing brought, nothing remembered.
            PinShelf.bringBookmarks(into: browser)
            XCTAssertNil(Store.settings.object(forKey: PinShelf.broughtIDsKey(browser.profileID)))

            Pins.set(home, Pins.defs(home) + [PinDef(id: UUID(), letter: "P", home: "https://pinned.example/", title: "Pinned")],
                     from: browser)
            let top = try site("Top", "https://top.example/")
            let article = try site("Article", "https://article.example/")
            let deep = try site("Four down", "https://four.example/")
            let reading = Bookmark.folder("Reading", [article, .folder("Two", [.folder("Three", [deep])])])
            let tree: [Bookmark] = [
                top,
                try site("Already a pin", "https://pinned.example/"),
                reading,
                .folder("Empty", []),
            ]
            list.adopt(tree)
            PinShelf.bringBookmarks(into: browser)
            let shelf = PinShelf(browser, space: home)
            XCTAssertEqual(describe(shelf.roots), [
                "Top https://top.example/",
                "Reading/", "  Article https://article.example/", "  Four down https://four.example/",
            ], "in the order of the list: a bookmark at the top a row at the top, a folder a kept group, its folders' pages in it in order; no Bookmarks folder")
            XCTAssertFalse(Pins.groups(home).contains { ["Bookmarks", "Two", "Three", "Empty"].contains($0.name) },
                           "no group for them all, none inside, none left empty")
            XCTAssertEqual(Pins.groups(home).first { $0.name == "Reading" }?.id, reading.id,
                           "a folder keeps its bookmark's id, as another Mac's will")
            XCTAssertNotNil(Pins.defs(home).first { $0.id == deep.id }, "a row keeps its bookmark's id, as another Mac's will")
            XCTAssertEqual(list.roots, tree, "the list is left as it is")

            // Sync brings two more, one at the top and one in Reading, which
            // has been renamed here: they come over, and only they.
            shelf.update(reading.id, title: "Read later", url: nil)
            let later = try site("Later", "https://later.example/")
            let filed = try site("Filed later", "https://filed-later.example/")
            var more = tree
            more[2].children = [article, filed]
            more.append(later)
            list.adopt(more)
            PinShelf.bringBookmarks(into: browser)
            XCTAssertEqual(describe(shelf.roots), [
                "Top https://top.example/",
                "Read later/", "  Article https://article.example/", "  Four down https://four.example/",
                "  Filed later https://filed-later.example/",
                "Later https://later.example/",
            ], "into the group it made, by its id; the new one at the top after what is there")

            // Unpinned, it never comes back; gone from the list, its pin stays.
            shelf.remove(top.id)
            list.adopt([later, .folder("Reading", [])])
            PinShelf.bringBookmarks(into: browser)
            XCTAssertFalse(Pins.defs(home).contains { $0.id == top.id })
            list.adopt(more)
            PinShelf.bringBookmarks(into: browser)
            XCTAssertFalse(Pins.defs(home).contains { $0.id == top.id }, "an unpinned bookmark stays unpinned")
            XCTAssertTrue(Pins.defs(home).contains { $0.id == article.id }, "one gone from the list stays pinned")
        }
    }

    /// Brought over all at once before: everything in the list then counts
    /// as brought, and the old key goes.
    func testTheOldKeyCountsWhatWasThereAsBrought() throws {
        try withHome { browser, list, home in
            let old = try site("Old", "https://old-bookmark.example/")
            list.adopt([.folder("Folder", [old])])
            Store.settings.set(true, forKey: PinShelf.broughtKey(browser.profileID))
            let pins = Pins.defs(home)
            PinShelf.bringBookmarks(into: browser)
            XCTAssertEqual(Pins.defs(home), pins, "nothing brought twice")
            XCTAssertNil(Store.settings.object(forKey: PinShelf.broughtKey(browser.profileID)))
            XCTAssertEqual(Store.settings.stringArray(forKey: PinShelf.broughtIDsKey(browser.profileID)), [old.id.uuidString])
            let new = try site("New", "https://new-bookmark.example/")
            list.adopt([.folder("Folder", [old]), new])
            PinShelf.bringBookmarks(into: browser)
            XCTAssertTrue(Pins.defs(home).contains { $0.id == new.id })
            XCTAssertFalse(Pins.defs(home).contains { $0.home == "https://old-bookmark.example/" })
        }
    }

    /// Another Mac brought them first, and its pins came by sync without
    /// their folders, which don't sync: the same pins get theirs back here,
    /// the folder their bookmark is in.
    func testPinsThatCameFirstGetTheirFoldersBack() throws {
        try withHome { browser, list, home in
            let filed = try site("Filed", "https://filed-elsewhere.example/")
            let reading = Bookmark.folder("Reading", [filed])
            Pins.set(home, Pins.defs(home) + [PinDef(id: filed.id, letter: "F", home: "https://filed-elsewhere.example/",
                                                     title: "Filed", listed: true, group: UUID())], from: browser)
            list.adopt([reading])
            PinShelf.bringBookmarks(into: browser)
            let pin = try XCTUnwrap(Pins.defs(home).first { $0.id == filed.id })
            XCTAssertEqual(pin.group, reading.id, "into the group its bookmark is in, made with that folder's id")
            XCTAssertEqual(Pins.groups(home).first { $0.id == reading.id }?.name, "Reading")
            XCTAssertEqual(Pins.defs(home).filter { $0.home == "https://filed-elsewhere.example/" }.count, 1, "no second pin")
        }
    }

    /// Your bookmarks came into a folder named Bookmarks before they came to
    /// the top of the rows (#6): that folder goes, once, its rows to the top
    /// where they stand, a row of your own put in it since too. A folder of
    /// that name the bringing didn't make, holding none of its rows, stays.
    func testTheBookmarksFolderOfBeforeGoesOnce() throws {
        try withHome { browser, list, home in
            let profile = browser.profileID
            let brought = try site("Brought", "https://brought-before.example/")
            list.adopt([brought])
            Store.settings.set([brought.id.uuidString], forKey: PinShelf.broughtIDsKey(profile))
            let made = UUID(), mine = UUID(), own = UUID(), kept = UUID()
            Pins.setGroups(home, Pins.groups(home) + [TabGroup(id: made, name: "Bookmarks", collapsed: false)], from: browser)
            Pins.set(home, Pins.defs(home) + [
                PinDef(id: brought.id, letter: "B", home: "https://brought-before.example/", title: "Brought",
                       name: "Brought", listed: true, group: made),
                PinDef(id: mine, letter: "M", home: "https://mine-since.example/", title: "Mine", listed: true, group: made),
            ], from: browser)
            PinShelf.bringBookmarks(into: browser)
            XCTAssertFalse(Pins.groups(home).contains { $0.id == made }, "the folder the bringing made is gone")
            XCTAssertNil(Pins.defs(home).first { $0.id == brought.id }?.group, "its row at the top")
            XCTAssertNil(Pins.defs(home).first { $0.id == mine }?.group, "and the one of yours put in it")
            XCTAssertEqual(Store.settings.bool(forKey: PinShelf.unfolderedKey(profile)), true)

            // Once: a Bookmarks folder made since stays, whatever it holds.
            Pins.setGroups(home, Pins.groups(home) + [TabGroup(id: own, name: "Bookmarks", collapsed: false)], from: browser)
            PinShelf(browser, space: home).move(brought.id, into: own)
            PinShelf.bringBookmarks(into: browser)
            XCTAssertTrue(Pins.groups(home).contains { $0.id == own })
            XCTAssertEqual(Pins.defs(home).first { $0.id == brought.id }?.group, own)

            // Not once yet, but a folder of that name holding nothing brought: it stays.
            Store.settings.removeObject(forKey: PinShelf.unfolderedKey(profile))
            PinShelf(browser, space: home).move(brought.id, into: nil)
            Pins.setGroups(home, Pins.groups(home) + [TabGroup(id: kept, name: "Bookmarks", collapsed: false)], from: browser)
            Pins.set(home, Pins.defs(home) + [PinDef(id: UUID(), letter: "K", home: "https://kept-own.example/", title: "Kept",
                                                     listed: true, group: kept)], from: browser)
            PinShelf.bringBookmarks(into: browser)
            XCTAssertTrue(Pins.groups(home).contains { $0.id == kept }, "not the one the bringing made")
            XCTAssertTrue(Pins.groups(home).contains { $0.id == own })
        }
    }

    func testAnImportsFolderIsNamedForWhereItCameFrom() {
        XCTAssertEqual(PinShelf.folderName(import: "Chrome"), "Chrome Bookmarks")
        XCTAssertEqual(PinShelf.folderName(import: "Safari"), "Safari Bookmarks")
        XCTAssertEqual(PinShelf.folderName(import: "Reading list"), "Reading list Bookmarks")
        XCTAssertEqual(PinShelf.folderName(import: "bookmarks_11_21_26"), "bookmarks_11_21_26", "a file's name that says so already")
        XCTAssertEqual(PinShelf.folderName(import: "  "), "Bookmarks")
    }

    /// The bookmarks page left with bookmarks (#6): a tab a session kept
    /// on it is not brought back as a page that can't load.
    func testATabLeftOnTheBookmarksPageIsNotBroughtBack() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        XCTAssertTrue(InternalPage.retired(try XCTUnwrap(URL(string: "eden://bookmarks"))))
        XCTAssertFalse(InternalPage.retired(try XCTUnwrap(URL(string: "eden://settings"))))
        var record = WindowRecord()
        record.rows[Space.firstID.uuidString] = Session.Shape(tabs: [
            Session.Entry(url: "eden://bookmarks", title: "Bookmarks"),
            Session.Entry(url: "https://kept-tab.example/", title: "Kept"),
        ], active: 0)
        let restored = Browser(record: record)
        defer { restored.closeAll() }
        XCTAssertFalse(restored.tabs.contains { $0.address.map(InternalPage.retired) == true || $0.title == "Bookmarks" })
        XCTAssertTrue(restored.tabs.contains { $0.address?.absoluteString == "https://kept-tab.example/" })
    }

    // MARK: - helpers

    /// A run whose writes don't land records nothing — neither the old
    /// Bookmarks folder taken away nor the bookmarks brought — and the next
    /// run, the files writable again, completes it: on disk, recorded, and
    /// nothing twice.
    func testNothingIsRecordedUntilThePinsAreOnDisk() throws {
        try withHome { browser, list, home in
            let profile = browser.profileID
            let files = FileManager.default
            let pinsFile = Store.file("pins.json"), groupsFile = Store.file(KeptGroupsFile.name)
            let before = try site("Before", "https://before-unfoldered.example/")
            Store.settings.set([before.id.uuidString], forKey: PinShelf.broughtIDsKey(profile))
            let made = UUID()
            Pins.setGroups(home, Pins.groups(home) + [TabGroup(id: made, name: "Bookmarks", collapsed: false)], from: browser)
            Pins.set(home, Pins.defs(home) + [PinDef(id: before.id, letter: "B", home: "https://before-unfoldered.example/",
                                                     title: "Before", listed: true, group: made)], from: browser)
            let top = try site("Top", "https://top-unwritten.example/")
            let filed = try site("Filed", "https://filed-unwritten.example/")
            let reading = Bookmark.folder("Reading", [filed])
            list.adopt([before, top, reading])
            Disk.drain()

            // Neither file can be written: a folder in the place of each.
            for file in [pinsFile, groupsFile] {
                try? files.removeItem(at: file)
                try files.createDirectory(at: file, withIntermediateDirectories: true)
            }
            PinShelf.bringBookmarks(into: browser)
            XCTAssertFalse(Store.settings.bool(forKey: PinShelf.unfolderedKey(profile)), "the old folder's going not recorded")
            XCTAssertEqual(Store.settings.stringArray(forKey: PinShelf.broughtIDsKey(profile)), [before.id.uuidString],
                           "nor what was brought")
            XCTAssertFalse(Pins.groups(home).contains { $0.id == made }, "done here all the same")
            XCTAssertTrue(Pins.defs(home).contains { $0.id == top.id })

            // The next run, they can be: it completes, adding nothing twice.
            for file in [pinsFile, groupsFile] { try files.removeItem(at: file) }
            PinShelf.bringBookmarks(into: browser)
            XCTAssertTrue(Store.settings.bool(forKey: PinShelf.unfolderedKey(profile)))
            XCTAssertEqual(Set(Store.settings.stringArray(forKey: PinShelf.broughtIDsKey(profile)) ?? []),
                           Set([before, top, filed].map(\.id.uuidString)))
            for id in [before.id, top.id, filed.id] {
                XCTAssertEqual(Pins.defs(home).filter { $0.id == id }.count, 1, "nothing twice")
            }
            XCTAssertEqual(Pins.groups(home).filter { $0.id == reading.id }.count, 1)
            let written = try PinsFile.decode(try Data(contentsOf: pinsFile)).bySpace[home] ?? []
            XCTAssertNil(written.first { $0.id == before.id }?.group, "on disk at the top, out of the old folder")
            XCTAssertNotNil(written.first { $0.id == top.id })
            XCTAssertEqual(written.first { $0.id == filed.id }?.group, reading.id)
            let groups = try XCTUnwrap(KeptGroupsFile.decode(try Data(contentsOf: groupsFile))).bySpace[home] ?? []
            XCTAssertFalse(groups.contains { $0.id == made }, "the old folder gone from disk")
            XCTAssertTrue(groups.contains { $0.id == reading.id })
        }
    }

    private func site(_ title: String, _ url: String) throws -> Bookmark { .site(title, try XCTUnwrap(URL(string: url))) }

    /// The Personal profile's home space and bookmarks, put back as they
    /// were afterwards, with nothing remembered as brought.
    private func withHome(_ body: @MainActor (Browser, Bookmarks, UUID) throws -> Void) throws {
        let browser = try makeBrowser()
        let profile = browser.profileID
        XCTAssertEqual(profile, Profile.personalID)
        let home = Space.firstID
        let list = Profiles.bookmarks(profile)
        let keys = [PinShelf.broughtKey(profile), PinShelf.broughtIDsKey(profile), PinShelf.unfolderedKey(profile)]
        let saved = (defs: Pins.defs(home), groups: Pins.groups(home), roots: list.roots,
                     keys: keys.map { Store.settings.object(forKey: $0) })
        defer {
            Pins.setGroups(home, saved.groups, from: browser)
            Pins.set(home, saved.defs, from: browser)
            list.adopt(saved.roots)
            for (key, value) in zip(keys, saved.keys) { Store.settings.set(value, forKey: key) }
        }
        keys.forEach(Store.settings.removeObject(forKey:))
        list.adopt([])
        try body(browser, list, home)
    }

    private func makeBrowser() throws -> Browser {
        if let browser { return browser }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let made = Browser(record: WindowRecord())
        browser = made
        return made
    }

    private struct IDs {
        let square, a, b, c, d: UUID
        let work, inner: UUID
    }

    /// A space no window shows, with a square, the kept groups Work and
    /// Inner, and rows a at the top, b in Work, c in Inner and d in a group
    /// that is gone.
    private func made() throws -> (PinShelf, IDs) {
        let browser = try makeBrowser()
        let space = UUID()
        spaces.append(space)
        let ids = IDs(square: UUID(), a: UUID(), b: UUID(), c: UUID(), d: UUID(), work: UUID(), inner: UUID())
        Pins.setGroups(space, [TabGroup(id: ids.work, name: "Work", collapsed: false),
                               TabGroup(id: ids.inner, name: "Inner", collapsed: false)], from: browser)
        Pins.set(space, [
            PinDef(id: ids.square, letter: "S", home: "https://square.example/", title: "square"),
            PinDef(id: ids.a, letter: "A", home: "https://a.example/", title: "a", name: "Named a", listed: true),
            PinDef(id: ids.b, letter: "B", home: "https://b.example/", title: "b", listed: true, group: ids.work),
            PinDef(id: ids.c, letter: "C", home: "https://c.example/", title: "c", listed: true, group: ids.inner),
            PinDef(id: ids.d, letter: "D", home: "https://d.example/", title: "d", listed: true, group: UUID()),
        ], from: browser)
        return (PinShelf(browser, space: space), ids)
    }

    /// The tree as indented lines: a folder with a slash, a row with its
    /// title and address.
    private func describe(_ nodes: [Bookmark], depth: Int = 0) -> [String] {
        nodes.flatMap { node -> [String] in
            let indent = String(repeating: "  ", count: depth)
            if node.isFolder { return ["\(indent)\(node.title)/"] + describe(node.children ?? [], depth: depth + 1) }
            return ["\(indent)\(node.title) \(node.url ?? "")"]
        }
    }
}
