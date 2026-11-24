import EdenCore
import AppKit
import SwiftUI
import XCTest
@testable import Eden

/// Kept groups in a real window's model (Column.swift): made, filled,
/// folded, coloured, deleted from their menu, the row's order kept as drawn,
/// pin-folders.json taken in once, the column drawn off screen reading the
/// same lines back, and tabs and groups carried across the line both ways.
/// The column is hosted in a window that is never ordered in, as the
/// bench's `column` draws it.
@MainActor
final class PinFolderColumnTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?
    /// The tabs makeBrowser made, in order: a session left by the test
    /// before may have brought others back first.
    private var made: [Eden.Tab] = []

    override class func setUp() {
        setenv("EDEN_PROBE", "pin-folders-\(getpid())", 1)
        super.setUp()
    }

    /// From a space as a new install has it, whatever the suites before
    /// left in this process's world (CleanWorld).
    override func setUp() async throws {
        try await super.setUp()
        CleanWorld.reset()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("pin-folders-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.subhajit.eden.beta.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil }
        for browser in browsers {
            Pins.setGroups(browser.spaceID, [], from: nil)
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            for group in browser.tabGroups { browser.removeTabGroup(group.id) }
            browser.closeAll()
            CleanWorld.reset(space: browser.spaceID)
        }
        made.removeAll()
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(200))
        try await super.tearDown()
    }

    func testKeptGroupsKeepTheRowInTheOrderDrawn() throws {
        let browser = makeBrowser()
        let (one, two, three, four) = try pinned(browser)

        let work = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: two, rename: false))
        XCTAssertTrue(browser.drawsKeptGroups)
        XCTAssertEqual(browser.area(ofGroup: work), .kept)
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 1 two", "pin 0 one", "pin 0 three", "pin 0 four"])
        XCTAssertEqual(browser.listedPins.map(\.title), ["two", "one", "three", "four"], "saved order = drawn order")

        // Another group goes after it, one level, as under the line.
        let docs = try XCTUnwrap(browser.newKeptGroup(named: "Docs", rename: false))
        browser.move(four, to: ColumnPlace(area: .kept, group: docs))
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 1 two", "folder 0 Docs", "pin 1 four", "pin 0 one", "pin 0 three"])
        XCTAssertEqual(browser.listedPins.map(\.title), ["two", "four", "one", "three"])
        // pins.json has it too, in the same order, each with its group.
        let saved = Pins.defs(browser.spaceID).filter { $0.listed == true }
        XCTAssertEqual(saved.map(\.title), ["two", "four", "one", "three"])
        XCTAssertEqual(saved.map(\.group), [work, docs, nil, nil])

        // Let go beside a row: in its group, before it.
        XCTAssertTrue(browser.move(three, to: ColumnPlace(area: .kept, group: work, index: 0)))
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 1 three", "pin 1 two", "folder 0 Docs", "pin 1 four", "pin 0 one"])

        browser.setGroupFolded(work, true)
        XCTAssertEqual(described(browser), ["folder 0 Work", "folder 0 Docs", "pin 1 four", "pin 0 one"])
        // Folded, the row in front still shows, as a folded group's tab does.
        // Its rows are data while it is folded (HeldPins.swift): the one gone
        // to is made a tab again.
        let shown = try XCTUnwrap(two.pinID.flatMap(browser.showHeld))
        browser.select(shown)
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 1 two", "folder 0 Docs", "pin 1 four", "pin 0 one"])
        browser.setGroupFolded(work, false)
        let twoAgain = try XCTUnwrap(browser.listedPins.first { $0.title == "two" })

        // Separate Tabs (Delete Folder): its rows stay pinned, where it stood.
        browser.removeTabGroup(docs)
        XCTAssertNil(four.keptGroupID)
        XCTAssertNotNil(four.pin)
        XCTAssertEqual(browser.keptGroups.map(\.id), [work])
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 1 three", "pin 1 two", "pin 0 four", "pin 0 one"])

        // A square is in no group.
        browser.setListed(twoAgain, false)
        XCTAssertNil(twoAgain.keptGroupID)
        _ = one
    }

    /// An empty kept group has no row to stand by: it stands after the
    /// group before it, or first, wherever it is put.
    func testAnEmptyKeptGroupStandsAfterTheGroupBeforeIt() throws {
        let browser = makeBrowser()
        let (_, _, three, _) = try pinned(browser)
        let work = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: three, rename: false))
        let empty = try XCTUnwrap(browser.newKeptGroup(named: "Empty", rename: false))
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 1 three", "folder 0 Empty", "pin 0 one", "pin 0 two", "pin 0 four"])
        // Work carried down among the rows; the empty one, before it now, first.
        XCTAssertTrue(browser.move(group: work, to: ColumnPlace(area: .kept, index: 3)))
        XCTAssertEqual(described(browser), ["folder 0 Empty", "pin 0 one", "pin 0 two", "folder 0 Work", "pin 1 three", "pin 0 four"])
        XCTAssertEqual(browser.keptGroups.map(\.name), ["Empty", "Work"], "the groups' own order follows what is drawn")
        // The empty one carried to the end: after Work, the group before it.
        XCTAssertTrue(browser.move(group: empty, to: ColumnPlace(area: .kept)))
        XCTAssertEqual(described(browser), ["pin 0 one", "pin 0 two", "folder 0 Work", "pin 1 three", "folder 0 Empty", "pin 0 four"])
        XCTAssertEqual(browser.keptGroups.map(\.name), ["Work", "Empty"])
    }

    func testAKeptGroupsColourAndIconAreKeptForEveryWindow() throws {
        let browser = makeBrowser()
        let (_, two, _, _) = try pinned(browser)
        let work = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: two, rename: false))
        XCTAssertEqual(browser.keptGroups.first?.colour, .stone, "neutral until one is chosen")
        XCTAssertNil(browser.keptGroups.first?.icon, "the folder that opens with it")
        browser.setColour(.madder, ofGroup: work)
        browser.setIcon(.symbol("leaf.fill"), ofGroup: work)
        XCTAssertEqual(Pins.groups(browser.spaceID).first { $0.id == work }?.colour, .madder)
        XCTAssertEqual(Pins.groups(browser.spaceID).first { $0.id == work }?.icon, .symbol("leaf.fill"))
        // Written with the pins, to kept-groups.json, where every window of
        // the space reads it.
        Disk.drain()
        let file = try Data(contentsOf: Store.file(KeptGroupsFile.name))
        let read = try XCTUnwrap(KeptGroupsFile.decode(file)?.bySpace[browser.spaceID]?.first { $0.id == work })
        XCTAssertEqual(read.colour, .madder)
        XCTAssertEqual(read.icon, .symbol("leaf.fill"))
        browser.setIcon(nil, ofGroup: work)
        XCTAssertNil(browser.keptGroups.first?.icon, "back to the folder")
    }

    /// What a kept group's menu offers, and what its rows do.
    func testTheKeptGroupsMenu() throws {
        let browser = makeBrowser()
        let (_, two, three, _) = try pinned(browser)
        let work = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: two, rename: false))
        browser.move(three, to: ColumnPlace(area: .kept, group: work))
        func menu() throws -> NSMenu {
            GroupMenu.make(for: try XCTUnwrap(browser.keptGroups.first { $0.id == work }), in: browser)
        }
        func pick(_ title: String) throws {
            let menu = try menu()
            let index = menu.indexOfItem(withTitle: title)
            XCTAssertGreaterThanOrEqual(index, 0, "\(title) in \(menu.items.map(\.title))")
            guard index >= 0 else { return }
            menu.performActionForItem(at: index)
        }
        let titles = try menu().items.filter { $0.view == nil && !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, ["Rename…", "Add Icon…", "New Folder", "Collapse Folder", "Copy All Links", "Delete Folder"])
        XCTAssertNotNil(try menu().items.first?.view, "the colours in a row at its top")

        try pick("Rename…")
        XCTAssertEqual(browser.editingGroupID, work)
        browser.editingGroupID = nil
        try pick("Add Icon…")
        XCTAssertEqual(browser.iconGroupID, work)
        browser.iconGroupID = nil
        browser.setIcon(.emoji("📚"), ofGroup: work)
        XCTAssertTrue(try menu().items.contains { $0.title == "Change Icon…" })

        try pick("Collapse Folder")
        XCTAssertEqual(browser.keptGroups.first { $0.id == work }?.collapsed, true)
        try pick("Expand Folder")
        XCTAssertEqual(browser.keptGroups.first { $0.id == work }?.collapsed, false)
        // Folded, its rows were data (HeldPins.swift): unfolded, they are
        // tabs made anew.
        let unfolded = [try XCTUnwrap(browser.listedPins.first { $0.title == "two" }),
                        try XCTUnwrap(browser.listedPins.first { $0.title == "three" })]

        try pick("Copy All Links")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "https://two.example/\nhttps://three.example/")

        try pick("New Folder")
        XCTAssertEqual(browser.keptGroups.count, 2)
        let made = try XCTUnwrap(browser.keptGroups.last)
        XCTAssertEqual(made.name, "New Folder")
        XCTAssertEqual(browser.editingGroupID, made.id, "its name arrives selected, as a new group's")
        browser.editingGroupID = nil

        try pick("Delete Folder")
        XCTAssertEqual(browser.keptGroups.map(\.id), [made.id])
        XCTAssertEqual(unfolded.map(\.keptGroupID), [nil, nil])
        XCTAssertEqual(unfolded.map { $0.pin != nil }, [true, true], "its pins stay pinned")
    }

    // MARK: - pin-folders.json, taken in once

    /// The folders of before come over whole — the group of each the folder
    /// of its id, so every row stays in it, its name, fold, colour and icon
    /// with it; folders inside folders flattened, and the moves the old file
    /// was waiting on made — and the old file goes only once the new one is
    /// on disk. A write that didn't land leaves it, and the next read takes
    /// it in again; once in, a pin-folders.json found later is passed by.
    func testPinFoldersComeOverOnceOnlyAfterTheNewFileLanded() throws {
        let browser = makeBrowser()
        let space = UUID()
        defer { Pins.forget(space) }
        let work = UUID(), docs = UUID(), home = UUID(), gone = UUID()
        let a = PinDef(id: UUID(), letter: "A", home: "https://a.example/", title: "a", listed: true, group: docs)
        let b = PinDef(id: UUID(), letter: "B", home: "https://b.example/", title: "b", listed: true, group: home)
        let c = PinDef(id: UUID(), letter: "C", home: "https://c.example/", title: "c", listed: true, group: gone)
        let d = PinDef(id: UUID(), letter: "D", home: "https://d.example/", title: "d", listed: true, group: work)
        Pins.set(space, [a, b, c, d], from: browser)
        Disk.drain()
        let newFile = Store.file(KeptGroupsFile.name), oldFile = Store.file(LegacyPinFolders.name)
        // The old file as it would be: every space's groups now, and this
        // space's as an Eden from before left them, nested, with a move it
        // was still waiting on (from a folder already gone into Work).
        func legacy(_ extra: [[String: Any]]) throws -> Data {
            let now = try XCTUnwrap(KeptGroupsFile.encode(KeptGroupsFile.Read(bySpace: Pins.groupsBySpace.filter { $0.key != space })))
            var top = try XCTUnwrap(JSONSerialization.jsonObject(with: now) as? [String: Any])
            top[space.uuidString] = extra
            top[KeptGroupsFile.movedKey] = [space.uuidString: [gone.uuidString: work.uuidString]]
            return try JSONSerialization.data(withJSONObject: top)
        }
        let folders: [[String: Any]] = [
            ["id": work.uuidString, "name": "Work", "collapsed": true, "colour": "madder", "icon": "emoji:📚"],
            ["id": docs.uuidString, "name": "Docs", "parent": work.uuidString, "collapsed": false],
            ["id": home.uuidString, "name": "Home", "icon": "symbol:house.fill"],
        ]
        let files = FileManager.default
        try? files.removeItem(at: newFile)
        try legacy(folders).write(to: oldFile)
        // Somewhere the new file can't be written: a folder in its place.
        try files.createDirectory(at: newFile, withIntermediateDirectories: true)

        Pins.readGroups()
        let expected = [TabGroup(id: work, name: "Work", collapsed: true, colour: .madder, icon: .emoji("📚")),
                        TabGroup(id: home, name: "Home", collapsed: false, colour: .stone, icon: .symbol("house.fill"))]
        XCTAssertEqual(Pins.groups(space), expected, "every field, one level deep")
        XCTAssertEqual(Pins.defs(space).map(\.group), [work, home, work, work], "every row in the group it was in, or the one it went into")
        Disk.drain()
        XCTAssertTrue(files.fileExists(atPath: oldFile.path), "kept while the new file isn't on disk")
        XCTAssertEqual(Pins.moved[space], [docs: work, gone: work], "the moves wait for the new file too")

        // The next read, the new file can be written: taken in again, and
        // the old file goes.
        try files.removeItem(at: newFile)
        Pins.readGroups()
        Disk.drain()
        XCTAssertEqual(Pins.groups(space), expected)
        XCTAssertNil(Pins.moved[space], "the rows are on disk in their groups")
        XCTAssertFalse(files.fileExists(atPath: oldFile.path), "gone once the new file landed")
        let written = try XCTUnwrap(KeptGroupsFile.decode(try Data(contentsOf: newFile)))
        XCTAssertEqual(written.bySpace[space], expected)
        XCTAssertTrue(written.moved.isEmpty)
        let pins = try PinsFile.decode(try Data(contentsOf: Store.file("pins.json")))
        XCTAssertEqual(pins.bySpace[space]?.map(\.group), [work, home, work, work])

        // Once only: an old file found again (an older Eden run since) is
        // passed by, and goes.
        try legacy([["id": UUID().uuidString, "name": "Stale"]]).write(to: oldFile)
        Pins.readGroups()
        Disk.drain()
        XCTAssertEqual(Pins.groups(space), expected)
        XCTAssertFalse(files.fileExists(atPath: oldFile.path))
    }

    func testTheColumnDrawsTheKeptGroups() async throws {
        let browser = makeBrowser()
        let (_, two, three, _) = try pinned(browser)
        let work = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: two, rename: false))
        let inner = try XCTUnwrap(browser.newKeptGroup(named: "Inner", rename: false))
        browser.move(three, to: ColumnPlace(area: .kept, group: inner))
        browser.setGroupFolded(inner, true)
        SideBar.drawnPinLines = []
        let width = Double(browser.prefs.columnWidth)
        let host = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs).frame(width: width, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let drawn = SideBar.drawnPinLines.map { "\($0[0]) \($0[1]) \($0[2])" }
        XCTAssertEqual(drawn, ["folder 0 Work", "pin 1 two", "folder 0 Inner", "pin 0 one", "pin 0 four"])
        XCTAssertFalse(window.isVisible, "never ordered in")
        _ = work
    }

    // MARK: - across the line

    /// An open tab carried above the line is pinned as a row where it is
    /// let go: at the top level, or into a kept group, at an index there.
    /// Asleep, it stays asleep.
    func testATabCarriedAboveTheLineIsPinnedWhereItIsLetGo() throws {
        let browser = makeBrowser(groups: true)
        let (one, two, three, four) = try tabs(browser)
        browser.pin(one, listed: true)
        browser.pin(two, listed: true)
        let work = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: two, rename: false))
        let asleep = [three, four].map(\.asleep)

        XCTAssertTrue(browser.move(three, to: ColumnPlace(area: .kept, index: 1)))
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 1 two", "pin 0 three", "pin 0 one"])
        XCTAssertTrue(browser.move(four, to: ColumnPlace(area: .kept, group: work, index: 0)))
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 1 four", "pin 1 two", "pin 0 three", "pin 0 one"])
        XCTAssertEqual([three, four].map { $0.pin != nil && $0.listed }, [true, true])
        XCTAssertEqual([three, four].map(\.asleep), asleep, "nothing woken")
        let saved = Pins.defs(browser.spaceID).filter { $0.listed == true }
        XCTAssertEqual(saved.map(\.title), ["four", "two", "three", "one"])
        XCTAssertEqual(saved.map(\.group), [work, work, nil, nil])

        // Within the area, the same: out of the group, to the end.
        XCTAssertTrue(browser.move(four, to: ColumnPlace(area: .kept)))
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 1 two", "pin 0 three", "pin 0 one", "pin 0 four"])
        // Into a group that isn't there: nothing.
        XCTAssertFalse(browser.move(four, to: ColumnPlace(area: .kept, group: UUID())))
    }

    /// A row carried below the line is unpinned where it is let go: at the
    /// top level of the tabs, or into an open group, at an index there.
    func testARowCarriedBelowTheLineIsUnpinnedWhereItIsLetGo() throws {
        let browser = makeBrowser(groups: true, words: ["one", "two", "three", "four", "five", "six"])
        let five = made[4], six = made[5]
        let (one, two, three, _) = try tabs(browser)
        for tab in [one, two, three] { browser.pin(tab, listed: true) }
        let work = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: two, rename: false))
        let open = browser.addTabGroup(containing: five)
        browser.editingGroupID = nil
        XCTAssertEqual(opened(browser), ["four", "group [five]", "six"])

        XCTAssertTrue(browser.move(two, to: ColumnPlace(area: .open, group: open, index: 0)))
        XCTAssertEqual(opened(browser), ["four", "group [two five]", "six"])
        XCTAssertNil(two.pin)
        XCTAssertNil(two.keptGroupID)
        XCTAssertEqual(two.groupID, open)
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 0 one", "pin 0 three"], "its kept group stays, empty")

        XCTAssertTrue(browser.move(three, to: ColumnPlace(area: .open, index: 2)))
        XCTAssertEqual(opened(browser), ["four", "group [two five]", "three", "six"])
        XCTAssertNil(three.pin)
        XCTAssertFalse(Pins.defs(browser.spaceID).contains { $0.title == "three" || $0.title == "two" })
        _ = (work, six)
    }

    /// An open group carried above the line becomes a kept group, the same
    /// group, every tab of it pinned as a row in it, in order; carried back
    /// below, it is an open group again, its rows unpinned into it in order,
    /// nothing asleep woken.
    func testAGroupCarriedAcrossTheLineAndBack() throws {
        let browser = makeBrowser(groups: true, words: ["one", "two", "three", "four", "five", "six"])
        let five = made[4], six = made[5]
        let (one, _, _, _) = try tabs(browser)
        browser.pin(one, listed: true)
        let id = browser.addTabGroup(containing: five)
        browser.move(six, toGroup: id)
        browser.renameTabGroup(id, to: "Reading")
        browser.setColour(.madder, ofGroup: id)
        browser.setGroupFolded(id, true)
        browser.editingGroupID = nil
        let group = try XCTUnwrap(browser.tabGroups.first { $0.id == id })
        let asleep = [five, six].map(\.asleep)
        XCTAssertEqual(browser.area(ofGroup: id), .open)

        XCTAssertTrue(browser.move(group: id, to: ColumnPlace(area: .kept, index: 0)))
        XCTAssertEqual(browser.area(ofGroup: id), .kept)
        XCTAssertFalse(browser.tabGroups.contains { $0.id == id })
        XCTAssertEqual(browser.keptGroups, [group], "the same group: its name, colour and fold")
        XCTAssertEqual(browser.keptItems().map(item), ["group Reading [five six]", "tab one"])
        XCTAssertEqual([five, six].map { $0.pin != nil && $0.listed }, [true, true])
        XCTAssertEqual([five, six].map(\.groupID), [nil, nil])
        XCTAssertEqual([five, six].map(\.asleep), asleep, "nothing woken")
        XCTAssertEqual(Pins.groups(browser.spaceID), [group])
        let saved = Pins.defs(browser.spaceID).filter { $0.listed == true }
        XCTAssertEqual(saved.map(\.title), ["five", "six", "one"])
        XCTAssertEqual(saved.map(\.group), [id, id, nil])

        XCTAssertTrue(browser.move(group: id, to: ColumnPlace(area: .open, index: 1)))
        XCTAssertEqual(browser.area(ofGroup: id), .open)
        XCTAssertEqual(browser.tabGroups, [group])
        XCTAssertTrue(browser.keptGroups.isEmpty)
        XCTAssertEqual(browser.sideItems.prefix(3).map(item), ["tab two", "group Reading [five six]", "tab three"])
        XCTAssertEqual([five, six].map(\.pin), [nil, nil])
        XCTAssertEqual([five, six].map(\.groupID), [id, id])
        XCTAssertEqual([five, six].map(\.asleep), asleep, "nothing woken")
        XCTAssertFalse(Pins.defs(browser.spaceID).contains { $0.title == "five" || $0.title == "six" })
        XCTAssertTrue(Pins.groups(browser.spaceID).isEmpty)
    }

    /// Fold All Groups folds and unfolds the kept groups with the open
    /// ones, and ⌘1–⌘9 count a folded group once in either area, down the
    /// column as it is drawn: the kept area, then the open one.
    func testFoldAllGroupsAndTheNumbersCoverBothAreas() throws {
        let browser = makeBrowser(groups: true, words: ["one", "two", "three", "four", "five"])
        let (one, two, three, four) = try tabs(browser)
        let five = made[4]
        browser.pin(one, listed: true)
        browser.pin(two, listed: true)
        let work = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: one, rename: false))
        XCTAssertTrue(browser.move(two, to: ColumnPlace(area: .kept, group: work)))
        let open = browser.addTabGroup(containing: three)
        browser.move(four, toGroup: open)
        browser.editingGroupID = nil
        browser.select(five)
        XCTAssertTrue(browser.hasColumnGroups)
        XCTAssertTrue(browser.canFoldAllGroups)
        XCTAssertFalse(browser.canUnfoldAllGroups)
        XCTAssertEqual(browser.tabShortcutTargets.map(\.id), [one, two, three, four, five].map(\.id))

        browser.foldAllGroups(true)
        XCTAssertEqual(browser.keptGroups.map(\.collapsed), [true], "the kept group folded too")
        XCTAssertEqual(browser.tabGroups.map(\.collapsed), [true])
        XCTAssertEqual(Pins.groups(browser.spaceID).map(\.collapsed), [true], "for every window of the space")
        XCTAssertFalse(browser.canFoldAllGroups)
        XCTAssertTrue(browser.canUnfoldAllGroups)
        XCTAssertEqual(browser.tabShortcutTargets.map(\.id), [work, open, five.id], "a folded group is one place, in either area")
        XCTAssertEqual(browser.shownTabs.map(\.id), [five.id], "nothing folded away is cycled through")

        browser.foldAllGroups(false)
        XCTAssertEqual(browser.keptGroups.map(\.collapsed), [false])
        XCTAssertEqual(browser.tabGroups.map(\.collapsed), [false])
    }

    /// A row every space shows keeps the head of the kept area: carried, it
    /// moves only among those rows, never into a group, and nothing of this
    /// space's goes before them.
    func testARowEverySpaceShowsMovesOnlyAmongItsOwn() throws {
        let browser = makeBrowser()
        browser.prefs.usesSpaces = true
        browser.prefs.sharesPins = true
        let (one, two, three, _) = try pinned(browser)
        browser.shareEverywhere(one)
        browser.shareEverywhere(two)
        let work = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: three, rename: false))
        XCTAssertEqual(browser.keptItems().prefix(2).map(\.id), [.tab(one.id), .tab(two.id)])
        XCTAssertTrue(browser.move(two, to: ColumnPlace(area: .kept, index: 0)))
        XCTAssertEqual(browser.keptItems().prefix(2).map(\.id), [.tab(two.id), .tab(one.id)], "among its own kind")
        XCTAssertFalse(browser.move(one, to: ColumnPlace(area: .kept, group: work)), "never into a group")
        XCTAssertTrue(browser.move(three, to: ColumnPlace(area: .kept, index: 0)))
        XCTAssertEqual(browser.listedPins.map(\.id).firstIndex(of: three.id), 2, "after the head")
        for tab in [one, two] { browser.keepHere(tab) }
    }

    /// A square every space shows carried into the kept rows is a row every
    /// space shows, among those at the head, however far down it is let go;
    /// carried back onto the squares, a square every space shows again.
    func testASharedPinGoesBetweenTheSquaresAndTheRowsStayingShared() throws {
        let browser = makeBrowser()
        browser.prefs.usesSpaces = true
        browser.prefs.sharesPins = true
        let (one, two, three, _) = try tabs(browser)
        browser.pin(one)
        browser.shareEverywhere(one)
        browser.pin(two, listed: true)
        browser.shareEverywhere(two)
        browser.pin(three, listed: true)
        XCTAssertTrue(browser.takes(one, at: ColumnPlace(area: .kept)))
        XCTAssertTrue(browser.move(one, to: ColumnPlace(area: .kept, index: 5)))
        XCTAssertTrue(one.listed, "a row")
        XCTAssertTrue(one.everywhere, "still every space's")
        XCTAssertEqual(browser.keptItems().map(\.id), [.tab(two.id), .tab(one.id), .tab(three.id)], "at the head, no lower")
        XCTAssertTrue(browser.move(one, to: ColumnPlace(area: .kept, index: 0)))
        XCTAssertEqual(browser.keptItems().map(\.id), [.tab(one.id), .tab(two.id), .tab(three.id)])
        XCTAssertTrue(browser.square(one, at: 3))
        XCTAssertFalse(one.listed, "a square again")
        XCTAssertTrue(one.everywhere)
        XCTAssertEqual(browser.squarePins.map(\.id), [one.id])
        XCTAssertEqual(browser.keptItems().map(\.id), [.tab(two.id), .tab(three.id)])
        for tab in [one, two] { browser.keepHere(tab) }
    }

    /// What can't go across: a group into a group, an empty kept group
    /// below the line (an open group lasts as long as its tabs), a group
    /// holding a private tab above it.
    func testWhatCantGoAcrossTheLine() throws {
        let browser = makeBrowser(groups: true)
        let (one, two, _, _) = try tabs(browser)
        browser.pin(one, listed: true)
        let kept = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: one, rename: false))
        let empty = try XCTUnwrap(browser.newKeptGroup(named: "Empty", rename: false))
        let open = browser.addTabGroup(containing: two)
        browser.editingGroupID = nil
        XCTAssertFalse(browser.move(group: open, to: ColumnPlace(area: .kept, group: kept)))
        XCTAssertFalse(browser.move(group: empty, to: ColumnPlace(area: .open)))
        XCTAssertEqual(browser.area(ofGroup: empty), .kept)
        XCTAssertEqual(browser.area(ofGroup: open), .open)
        XCTAssertNil(browser.area(ofGroup: UUID()))
    }

    // MARK: - helpers

    /// A pinned row put down, taken out by its ×, comes back with ⇧⌘T a
    /// pin: its letter, its id and its page, at its place in its folder,
    /// asleep, and you left where you were.
    func testAPinTakenOutComesBackAPinWhereItWas() throws {
        let browser = makeBrowser()
        let (_, two, three, _) = try pinned(browser)
        let work = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: two, rename: false))
        browser.move(three, to: ColumnPlace(area: .kept, group: work))
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 1 two", "pin 1 three", "pin 0 one", "pin 0 four"])
        let front = browser.activeID
        let (letter, id, home) = (two.pin, two.pinID, two.home)
        browser.close(two)
        XCTAssertTrue(two.asleep, "put down first")
        Pins.retitle(try XCTUnwrap(id), "Inbox", from: browser)

        browser.deletePin(two)
        XCTAssertFalse(browser.tabs.contains { $0.id == two.id }, "out of the window")
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 1 three", "pin 0 one", "pin 0 four"])
        XCTAssertFalse(Pins.defs(browser.spaceID).contains { $0.id == id }, "and out of the pins")

        browser.reopen()
        let back = try XCTUnwrap(browser.tabs.first { $0.pinID == id })
        XCTAssertEqual(described(browser), ["folder 0 Work", "pin 1 two", "pin 1 three", "pin 0 one", "pin 0 four"],
                       "at its place, in its folder")
        XCTAssertEqual(back.pin, letter)
        XCTAssertEqual(back.home, home)
        XCTAssertTrue(back.listed)
        XCTAssertTrue(back.asleep, "asleep, as it was")
        XCTAssertEqual(browser.activeID, front, "you stay where you were")
        XCTAssertTrue(Pins.defs(browser.spaceID).contains { $0.id == id && $0.group == work }, "kept with the pins again")
        XCTAssertEqual(back.homeTitle, "Inbox", "with the title kept for it")
    }

    /// One of the pins every space shows comes back to its place among
    /// them, not after them.
    func testASharedPinTakenOutComesBackToItsPlace() throws {
        let browser = makeBrowser()
        browser.prefs.usesSpaces = true
        browser.prefs.sharesPins = true
        let (one, two, three, _) = try pinned(browser)
        for tab in [one, two, three] { browser.shareEverywhere(tab) }
        let shared = { Pins.shared(browser.profileID).map(\.title) }
        XCTAssertEqual(shared(), ["one", "two", "three"])
        browser.close(one)
        browser.deletePin(one)
        XCTAssertEqual(shared(), ["two", "three"])
        browser.reopen()
        XCTAssertEqual(shared(), ["one", "two", "three"], "first again, in every space")
        XCTAssertEqual(browser.listedPins.map(\.title), ["one", "two", "three", "four"])
        for tab in browser.tabs where tab.everywhere { browser.keepHere(tab) }
    }

    /// Delete in a pin's menu, on the pin you're on: back in front.
    func testAPinDeletedAwakeComesBackInFront() throws {
        let browser = makeBrowser()
        let (one, _, _, _) = try pinned(browser)
        browser.select(one)
        let id = one.pinID
        browser.deletePin(one)
        XCTAssertNotEqual(browser.activeID, one.id)
        browser.reopen()
        let back = try XCTUnwrap(browser.tabs.first { $0.pinID == id })
        XCTAssertEqual(browser.listedPins.map(\.title), ["one", "two", "three", "four"])
        XCTAssertEqual(browser.activeID, back.id)
    }

    private func described(_ browser: Browser) -> [String] {
        browser.keptLines().map { line in
            switch line {
            case .heading(let group): "folder 0 \(group.name)"
            case .tab(let tab, let group): "pin \(group == nil ? 0 : 1) \(tab.title)"
            }
        }
    }

    /// The open area, a line an item.
    private func opened(_ browser: Browser) -> [String] {
        browser.sideItems.compactMap { item in
            switch item {
            case .tab(let tab): tab.isBlank ? nil : tab.title
            case .group(_, let tabs): "group [\(tabs.map(\.title).joined(separator: " "))]"
            }
        }
    }

    private func item(_ item: SideItem) -> String {
        switch item {
        case .tab(let tab): "tab \(tab.title)"
        case .group(let group, let tabs): "group \(group.name) [\(tabs.map(\.title).joined(separator: " "))]"
        }
    }

    /// The first four tabs made, open.
    private func tabs(_ browser: Browser) throws -> (Eden.Tab, Eden.Tab, Eden.Tab, Eden.Tab) {
        XCTAssertGreaterThanOrEqual(made.count, 4)
        guard made.count >= 4 else { throw XCTSkip("no tabs") }
        return (made[0], made[1], made[2], made[3])
    }

    /// Four tabs pinned as rows, in order, and a tab in front after them.
    private func pinned(_ browser: Browser) throws -> (Eden.Tab, Eden.Tab, Eden.Tab, Eden.Tab) {
        let tabs = made
        XCTAssertEqual(tabs.count, 4)
        for tab in tabs { browser.pin(tab, listed: true) }
        browser.newTab()
        XCTAssertEqual(browser.listedPins.map(\.title), ["one", "two", "three", "four"])
        return (tabs[0], tabs[1], tabs[2], tabs[3])
    }

    private func makeBrowser(groups: Bool = false, words: [String] = ["one", "two", "three", "four"]) -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.usesTabGroups, prefs.splitView,
                        prefs.usesSpaces, prefs.sharesPins, prefs.newTabPlace)
        restorePreferences = {
            (prefs.usesTabGroups, prefs.splitView,
             prefs.usesSpaces, prefs.sharesPins, prefs.newTabPlace) = previous
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.usesTabGroups = groups
        browser.prefs.splitView = false
        browser.prefs.sharesPins = false
        // Each new tab after the last, so they stand in the order made.
        browser.prefs.newTabPlace = .next
        for word in words {
            if browser.tabs.last?.isBlank != true { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(word).example/")!, title: word)
            if let last = browser.tabs.last { made.append(last) }
        }
        return browser
    }
}
