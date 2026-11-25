import AppKit
import EdenCore
import SwiftUI
import XCTest
@testable import Eden

/// One set of tab actions (#41): the tab's menu, its hover card and the menu
/// bar act through the same functions, never go to the tab they act on,
/// act on every picked tab when the one asked of is among them, and ⌘W and
/// Escape agree on what is in front.
@MainActor
final class TabActionsTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "tab-actions-\(getpid())", 1)
        super.setUp()
    }

    // MARK: - not going to the tab

    /// A pin put down from its menu while you read another page leaves you
    /// on that page; put down in front, you land off it as before.
    func testPuttingDownAPinNotInFrontKeepsYouWhereYouWere() {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.pin(tabs[0])
        browser.select(tabs[2])
        browser.close(tabs[0])
        XCTAssertEqual(browser.activeID, tabs[2].id, "stayed where it was")
        XCTAssertNotNil(tabs[0].pin, "put down, not taken out")
        XCTAssertTrue(tabs[0].asleep)

        browser.select(tabs[0])
        browser.close(tabs[0])
        XCTAssertNotEqual(browser.activeID, tabs[0].id, "the pin in front is left")
        XCTAssertNil(browser.active?.pin)
    }

    /// Copy Address, Copy as Markdown Link, Copy Clean Link and Duplicate
    /// from a tab's menu act on that tab where it stands: the tab you are on
    /// stays in front, and the one asked of isn't woken.
    func testCopyingAndDuplicatingFromTheMenuDontGoToTheTab() throws {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.select(tabs[0])

        browser.copyAddresses(of: browser.acting(on: tabs[2]))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "https://three.example/")
        XCTAssertEqual(browser.announcement, "Address copied")
        XCTAssertEqual(browser.activeID, tabs[0].id)

        browser.copyMarkdownLinks(of: [tabs[2]])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "[three](https://three.example/)")
        XCTAssertEqual(browser.announcement, "Link copied")

        tabs[3].restore(url: try XCTUnwrap(URL(string: "https://four.example/?utm_source=mail")), title: "four")
        browser.copyCleanLinks(of: [tabs[3]])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "https://four.example/")
        XCTAssertEqual(browser.announcement, "Link copied")
        XCTAssertEqual(browser.activeID, tabs[0].id)
        XCTAssertNil(tabs[3].built, "not woken")

        let count = browser.tabs.count
        browser.duplicate([tabs[2]])
        XCTAssertEqual(browser.tabs.count, count + 1)
        XCTAssertNotEqual(browser.activeID, tabs[2].id, "the copy comes forward, not the tab it copies")
        XCTAssertEqual(browser.active?.address, tabs[2].address)
    }

    // MARK: - picked tabs

    /// Right-clicked among tabs picked with ⌘-click, every action acts on
    /// all of them; right-clicked on one not picked, on it alone.
    func testActionsApplyToEveryPickedTab() {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.select(tabs[0])
        browser.extendTabSelection(to: tabs[1], modifiers: .command)
        browser.extendTabSelection(to: tabs[2], modifiers: .command)
        XCTAssertEqual(browser.acting(on: tabs[1]).map(\.id), tabs.prefix(3).map(\.id))
        XCTAssertEqual(browser.acting(on: tabs[3]).map(\.id), [tabs[3].id], "one not picked: it alone")
        XCTAssertEqual(browser.frontTabs.map(\.id), tabs.prefix(3).map(\.id), "the menu bar's, with the tab in front")

        browser.copyAddresses(of: browser.acting(on: tabs[2]))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string),
                       "https://one.example/\nhttps://two.example/\nhttps://three.example/")
        XCTAssertEqual(browser.announcement, "3 addresses copied")
        browser.copyMarkdownLinks(of: browser.acting(on: tabs[2]))
        XCTAssertEqual(browser.announcement, "3 links copied")

        // Mute goes one way for all of them, as the menu said.
        tabs[1].toggleMute()
        browser.toggleMute(tabs[0])
        XCTAssertTrue(tabs.prefix(3).allSatisfy(\.muted), "muted, the one muted already too")
        XCTAssertFalse(tabs[3].muted)
        browser.toggleMute(tabs[2])
        XCTAssertFalse(tabs.prefix(3).contains(where: \.muted))

        let count = browser.tabs.count
        browser.duplicate(browser.acting(on: tabs[1]))
        XCTAssertEqual(browser.tabs.count, count + 3)
        XCTAssertEqual(browser.activeID, tabs[0].id, "several copies open behind")

        browser.pin(browser.acting(on: tabs[1]), listed: true)
        XCTAssertTrue(tabs.prefix(3).allSatisfy { $0.pin != nil && $0.listed })
        XCTAssertNil(tabs[3].pin)
        browser.unpin(tabs.prefix(3).map { $0 })
        XCTAssertTrue(tabs.allSatisfy { $0.pin == nil })
    }

    /// Close says what it does: a tab is closed, a pin put down, a tab in a
    /// group put away, and several of one kind say how many.
    func testCloseSaysWhatItDoes() {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.prefs.usesTabGroups = true
        XCTAssertEqual(TabMenu.closing([tabs[3]], in: browser), "Close Tab")
        browser.pin(tabs[0])
        browser.pin(tabs[1])
        XCTAssertEqual(TabMenu.closing([tabs[0]], in: browser), "Put Down")
        XCTAssertEqual(TabMenu.closing([tabs[0], tabs[1]], in: browser), "Put Down 2 Pins")
        let group = browser.addTabGroup(containing: tabs[2])
        browser.move(tabs[3], toGroup: group)
        // Asleep, a grouped tab has nothing to put away: it goes.
        XCTAssertEqual(TabMenu.closing([tabs[2]], in: browser), "Close Tab")
        browser.select(tabs[2])
        XCTAssertEqual(TabMenu.closing([tabs[2]], in: browser), "Put Away")
        // One put away and one, asleep, closed: Close, which is what both do.
        XCTAssertTrue(tabs[3].asleep)
        XCTAssertEqual(TabMenu.closing([tabs[2], tabs[3]], in: browser), "Close 2 Tabs")
        XCTAssertEqual(TabMenu.closing([tabs[0], tabs[2]], in: browser), "Close 2 Tabs")
    }

    // MARK: - ⇧⌘M

    /// ⇧⌘M mutes the tab in front and unmutes it again, the tabs picked
    /// with it too; it used to pause the page and say "Paused".
    func testShiftCommandMMutesAndUnmutes() throws {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.select(tabs[1])
        let command = try XCTUnwrap(Command.named("tabs.mute"))
        XCTAssertEqual(command.title, "Mute Tab")
        XCTAssertEqual(command.defaultKey, KeyCombo("m", shift: true))
        command.run(browser)
        XCTAssertTrue(tabs[1].muted)
        XCTAssertNil(browser.announcement)
        command.run(browser)
        XCTAssertFalse(tabs[1].muted)

        browser.extendTabSelection(to: tabs[2], modifiers: .command)
        browser.toggleMute()
        XCTAssertTrue(tabs[1].muted && tabs[2].muted)
        XCTAssertFalse(tabs[0].muted)
    }

    // MARK: - Close Other Tabs

    /// Close Other Tabs keeps pins and grouped tabs, as Clear does, and one
    /// ⇧⌘T brings back every tab it closed.
    func testCloseOtherTabsKeepsPinsAndGroupsAndComesBackTogether() {
        let browser = makeBrowser(count: 6)
        let tabs = browser.tabs
        browser.prefs.usesTabGroups = true
        browser.pin(tabs[0])
        let group = browser.addTabGroup(containing: tabs[1])
        browser.select(tabs[4])
        XCTAssertEqual(browser.othersToClose(but: tabs[3]).map(\.id), [tabs[2].id, tabs[4].id, tabs[5].id])

        browser.closeOthers(but: tabs[3])
        XCTAssertEqual(Set(browser.tabs.map(\.id)), Set([tabs[0].id, tabs[1].id, tabs[3].id]))
        XCTAssertNotNil(tabs[0].pin, "the pin stays")
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [tabs[1].id], "the group stays")
        XCTAssertEqual(browser.activeID, tabs[3].id, "off the page that went, onto the one kept")
        XCTAssertEqual(browser.recentlyClosed.count, 1, "one close")

        browser.reopen()
        XCTAssertEqual(Set(browser.tabs.compactMap(\.address)), Set(tabs.compactMap(\.address)), "all back at once")
        XCTAssertTrue(browser.ghosts.isEmpty)
    }

    /// Kept on a tab you aren't on, the page you are on stays in front
    /// when it isn't one that goes.
    func testCloseOtherTabsLeavesYouOnAPageThatStays() {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.pin(tabs[0])
        browser.select(tabs[0])
        browser.closeOthers(but: tabs[2])
        XCTAssertEqual(browser.activeID, tabs[0].id)
        XCTAssertEqual(Set(browser.tabs.map(\.id)), Set([tabs[0].id, tabs[2].id]))
    }

    // MARK: - ⌘W and Escape

    /// ⌘W puts away Hide Elements, Capture and the list of what is hidden
    /// here before it closes the page under them, as Escape does.
    func testCommandWClosesThePanelsBeforeTheTab() {
        let browser = makeBrowser()
        let count = browser.tabs.count
        browser.toggleHiding()
        XCTAssertTrue(browser.veiling)
        browser.closeFront()
        XCTAssertFalse(browser.veiling)
        XCTAssertEqual(browser.tabs.count, count)

        browser.snapping = true
        browser.closeFront()
        XCTAssertFalse(browser.snapping)
        XCTAssertEqual(browser.tabs.count, count)

        browser.reviewing = true
        browser.closeFront()
        XCTAssertFalse(browser.reviewing)
        XCTAssertEqual(browser.tabs.count, count)

        browser.closeFront()
        XCTAssertEqual(browser.tabs.count, count - 1, "then the tab")
    }

    /// Escape, with nothing else up, lets go of the tabs picked with ⌘-click,
    /// which ⌘W would otherwise close; with none picked it is the page's.
    func testEscapeLetsGoOfThePickedTabs() async throws {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.select(tabs[0])
        let (take, window) = try await keys(of: browser)

        browser.extendTabSelection(to: tabs[2], modifiers: .command)
        XCTAssertEqual(browser.visibleSelectedTabCount, 2)
        XCTAssertNil(take(try escape(in: window)), "taken")
        XCTAssertTrue(browser.selectedTabIDs.isEmpty)
        let again = try escape(in: window)
        XCTAssertTrue(take(again) === again, "nothing picked: the page's")
        XCTAssertEqual(browser.tabs.count, 4)
    }

    /// Escape on a folder's or a group's name being typed leaves the name
    /// as it was before it closes what is open behind it: taken by Find,
    /// the field lost its focus and kept what was typed.
    func testEscapeLeavesAGroupsNameBeforeFind() async throws {
        let browser = makeBrowser()
        browser.prefs.usesTabGroups = true
        browser.select(browser.tabs[0])
        let (take, window) = try await keys(of: browser)
        let id = browser.addTabGroup(containing: browser.tabs[1])
        browser.finding = true
        try await Task.sleep(for: .milliseconds(300))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "The heading's field must have the keys")
        editor.insertText("Reading", replacementRange: editor.selectedRange())

        XCTAssertNil(take(try escape(in: window)), "taken")
        XCTAssertNil(browser.editingGroupID)
        XCTAssertTrue(browser.finding, "Find stays, for the next Escape")
        // The field goes, and ends its edit as it does.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(browser.tabGroups.first { $0.id == id }?.name, "Group 1")
    }

    /// A window for the browser, and what its keys go through first
    /// (ContentView's key monitor), with the address field put away.
    private func keys(of browser: Browser) async throws -> (take: (NSEvent) -> NSEvent?, window: NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(browser: browser))
        window.orderBack(nil)
        addTeardownBlock { @MainActor in
            ContentView.forget(browser)
            window.contentView = nil
            window.close()
        }
        var hook: ((NSEvent) -> NSEvent?)?
        for _ in 0..<50 {
            hook = ContentView.keyHooks[ObjectIdentifier(browser)]
            if hook != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let take = try XCTUnwrap(hook)
        browser.editing = false
        return (take, window)
    }

    private func escape(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    // MARK: - Send to

    /// Send to asks the device to open each tab, as a drop on its group
    /// does, and keeps them here; whether or not the device has tabs.
    func testSendToAsksTheDeviceForEachTab() throws {
        let browser = makeBrowser()
        let tabs = browser.tabs
        pretend([DeviceTabs(device: "pad", name: "iPad", kind: .ipad, tabs: [], at: 0)])
        let pad = try XCTUnwrap(Sync.shared.elsewhere.first { $0.device == "pad" })
        browser.send([tabs[1], tabs[2]], to: pad)
        let now = try XCTUnwrap(Sync.shared.elsewhere.first { $0.device == "pad" })
        XCTAssertEqual(Set(now.tabs.map(\.url)), ["https://two.example/", "https://three.example/"])
        XCTAssertEqual(browser.announcement, "Sent to iPad")
        XCTAssertEqual(browser.tabs.count, 4, "kept here")
    }

    /// What a drop on a device's group refuses, Send to refuses the same,
    /// in the same words: a page open there already, a pin at its home, a
    /// private tab.
    func testSendToRefusesAsTheDropDoes() throws {
        let browser = makeBrowser()
        let tabs = browser.tabs
        pretend([DeviceTabs(device: "phone", name: "iPhone", kind: .iphone,
                            tabs: [DeviceTabs.Page(url: "https://two.example/", title: "two", space: nil)], at: 0)])
        let phone = try XCTUnwrap(Sync.shared.elsewhere.first { $0.device == "phone" })

        browser.send([tabs[1]], to: phone)
        XCTAssertEqual(browser.announcement, "Already open on iPhone")

        browser.pin(tabs[0])
        browser.send([tabs[0]], to: phone)
        XCTAssertEqual(browser.announcement, "iPhone has this pin already")

        browser.newShyTab()
        let shy = try XCTUnwrap(browser.active)
        XCTAssertTrue(shy.shy)
        XCTAssertEqual(Sync.shared.refusal(sending: shy, from: browser.spaceID, to: phone), "Private tabs stay on this Mac")

        browser.send([tabs[1], tabs[2]], to: phone)
        XCTAssertEqual(browser.announcement, "Sent 1 of 2 to iPhone")
        let now = try XCTUnwrap(Sync.shared.elsewhere.first { $0.device == "phone" })
        XCTAssertEqual(now.tabs.filter { $0.url == "https://two.example/" }.count, 1, "never twice")
        XCTAssertTrue(now.tabs.contains { $0.url == "https://three.example/" })
    }

    /// Dropped on a device's group, what goes is said by the rows coming
    /// into that group, so nothing else says it; what is turned down still
    /// is, as from a menu.
    func testSendLetGoOnAGroupSaysOnlyWhatWasTurnedDown() throws {
        let browser = makeBrowser()
        let tabs = browser.tabs
        pretend([DeviceTabs(device: "phone", name: "iPhone", kind: .iphone,
                            tabs: [DeviceTabs.Page(url: "https://two.example/", title: "two", space: nil)], at: 0)])
        let phone = try XCTUnwrap(Sync.shared.elsewhere.first { $0.device == "phone" })
        browser.send([tabs[2]], to: phone, dropped: true)
        XCTAssertNil(browser.announcement, "sent, unsaid")
        XCTAssertTrue(try XCTUnwrap(Sync.shared.elsewhere.first { $0.device == "phone" }).tabs
            .contains { $0.url == "https://three.example/" })
        browser.send([tabs[1], tabs[3]], to: phone, dropped: true)
        XCTAssertEqual(browser.announcement, "Already open on iPhone", "why one didn't go")
    }

    // MARK: - to another space

    /// Move to Space, then New Space: a page that has to be asked whether
    /// anything is typed in it, and a sleeping tab that needn't be, both go
    /// before the new space comes to the front. The sleeping one used to go
    /// at once and take you there, and the page, asked a moment later,
    /// found its space gone and stayed behind.
    func testMovingToANewSpaceTakesEveryPickedTab() async throws {
        let browser = makeBrowser()
        let tabs = browser.tabs
        let prefs = browser.prefs
        let before = (prefs.usesSpaces, browser.spaces)
        addTeardownBlock { @MainActor in
            prefs.usesSpaces = before.0
            browser.spaces = before.1
            Spaces.write(before.1, profile: browser.profileID)
        }
        prefs.usesSpaces = true
        let home = browser.spaceID
        browser.afterSpaceCreated = { _ in }
        browser.addSpace(named: "Elsewhere", sharesSignIns: false)
        let away = try XCTUnwrap(browser.spaces.last?.id)
        XCTAssertEqual(browser.spaceID, home)
        browser.select(tabs[1])
        XCTAssertNotNil(tabs[1].built, "a page to ask")
        XCTAssertNil(tabs[2].built, "asleep, nothing to ask")
        XCTAssertFalse(tabs[1].store === Spaces.store(for: away), "other sign-ins: asked")
        browser.move([tabs[1], tabs[2]], toSpace: away) { browser.switchSpace(to: away) }
        let deadline = Date().addingTimeInterval(5)
        while browser.spaceID != away, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(browser.spaceID, away)
        XCTAssertTrue(browser.tabs.contains { $0 === tabs[1] }, "the page went")
        XCTAssertTrue(browser.tabs.contains { $0 === tabs[2] }, "the sleeping tab went")
        browser.switchSpace(to: home)
    }

    /// A pin every space shows, picked with a tab moved to another space,
    /// stays: it is in every space already. Taken along, the shared pins
    /// were written without it, and every space closed its copy.
    func testMovingToASpaceLeavesThePinsEverySpaceShows() throws {
        // A window of its own, not the shared one makeBrowser empties with
        // closeAll: a window closed so writes no session, and its pins get
        // no ids to be shared by.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let before = (prefs.usesSpaces, prefs.sharesPins, prefs.newTabPlace, browser.spaces)
        prefs.newTabPlace = .next
        for word in ["one", "two", "three"] {
            if browser.tabs.last?.isBlank != true { browser.newTab() }
            if let url = URL(string: "https://\(word).example/") { browser.tabs.last?.restore(url: url, title: word) }
        }
        let tabs = browser.tabs
        addTeardownBlock { @MainActor in
            for tab in tabs where tab.everywhere { browser.keepHere(tab) }
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
            prefs.usesSpaces = before.0
            prefs.sharesPins = before.1
            prefs.newTabPlace = before.2
            browser.spaces = before.3
            Spaces.write(before.3, profile: browser.profileID)
            CleanWorld.reset()
        }
        prefs.usesSpaces = true
        prefs.sharesPins = true
        for tab in tabs[0...1] {
            browser.pin(tab)
            browser.shareEverywhere(tab)
        }
        browser.afterSpaceCreated = { _ in }
        browser.addSpace(named: "Elsewhere")
        let away = try XCTUnwrap(browser.spaces.last?.id)
        let shared = Set(tabs[0...1].compactMap(\.pinID))
        XCTAssertEqual(shared.count, 2)
        XCTAssertTrue(Set(Pins.shared(browser.profileID).map(\.id)).isSuperset(of: shared))
        browser.select(tabs[2])
        browser.extendTabSelection(to: tabs[0], modifiers: [.command])
        let picked = browser.acting(on: tabs[2])
        XCTAssertEqual(Set(picked.map(\.id)), [tabs[0].id, tabs[2].id])
        XCTAssertEqual(browser.movableToSpace(picked).map(\.id), [tabs[2].id], "the shared pin left out")
        XCTAssertTrue(browser.movableToSpace([tabs[0], tabs[1]]).isEmpty, "nothing to move: the menu is off")

        browser.move(picked, toSpace: away)
        XCTAssertFalse(browser.tabs.contains { $0 === tabs[2] }, "the tab went")
        XCTAssertTrue(browser.tabs.contains { $0 === tabs[0] }, "the shared pin stayed")
        XCTAssertTrue(tabs[0].everywhere)
        XCTAssertTrue(Set(Pins.shared(browser.profileID).map(\.id)).isSuperset(of: shared), "both still every space's")
    }

    // MARK: - the menu bar's ⌘D and the card

    /// ⌘D takes the tab in front and those picked with it, as the rest of
    /// the menu bar does: all pinned as rows while any isn't a pin, else
    /// all unpinned.
    func testCommandDTakesThePickedTabs() {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.select(tabs[1])
        browser.extendTabSelection(to: tabs[2], modifiers: [.command])
        browser.togglePinRow()
        XCTAssertTrue([tabs[1], tabs[2]].allSatisfy { $0.pin != nil && $0.listed }, "both pinned as rows")
        browser.togglePinRow()
        XCTAssertTrue([tabs[1], tabs[2]].allSatisfy { $0.pin == nil }, "both unpinned")
        browser.pin(tabs[1], listed: true)
        browser.togglePinRow()
        XCTAssertTrue([tabs[1], tabs[2]].allSatisfy { $0.pin != nil }, "one not a pin: both pinned")
    }

    /// The card's copy and mute are the menu's, on its one tab: copied
    /// with no toast (its tick says so), and only its tab muted.
    func testTheCardCopiesAndMutesItsTabAlone() {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.select(tabs[0])
        browser.extendTabSelection(to: tabs[1], modifiers: [.command])
        browser.copyAddresses(of: [tabs[1]], quietly: true)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "https://two.example/")
        XCTAssertNil(browser.announcement, "no toast")
        browser.mute([tabs[1]], true)
        XCTAssertTrue(tabs[1].muted)
        XCTAssertFalse(tabs[0].muted, "picked, but not the card's")
        browser.mute([tabs[1]], false)
        XCTAssertFalse(tabs[1].muted)
    }

    // MARK: - to another window

    /// Move to Window, as a drag out of the window: the tabs in their order,
    /// the first in front there, and only that one woken.
    func testMoveToWindowWakesOnlyTheOneInFront() {
        let browser = makeBrowser(count: 6)
        let tabs = browser.tabs
        // Landing on the neighbour, the rule this reads from: going back
        // to the tab before is NothingInFrontTests'.
        let goesBack = browser.prefs.closeGoesBack
        browser.prefs.closeGoesBack = false
        addTeardownBlock { @MainActor in browser.prefs.closeGoesBack = goesBack }
        let other = Browser(record: WindowRecord(space: browser.spaceID))
        addTeardownBlock { @MainActor in other.closeAll() }
        browser.select(tabs[0])
        XCTAssertNil(tabs[1].built)
        XCTAssertNil(tabs[3].built)
        browser.move([tabs[1], tabs[3]], toWindow: other)
        XCTAssertEqual(other.tabs.filter { $0 === tabs[1] || $0 === tabs[3] }.map(\.id), [tabs[1], tabs[3]].map(\.id))
        XCTAssertEqual(other.activeID, tabs[1].id)
        XCTAssertNil(tabs[3].built, "not woken")
        XCTAssertFalse(browser.tabs.contains { $0 === tabs[1] || $0 === tabs[3] })

        // The tab in front among them, a sleeping one beside it: this
        // window goes to one that stays, never to the sleeping one on the
        // way out.
        XCTAssertEqual(browser.activeID, tabs[0].id)
        XCTAssertNil(tabs[2].built)
        browser.move([tabs[0], tabs[2]], toWindow: other)
        XCTAssertNil(tabs[2].built, "not woken on the way out")
        XCTAssertEqual(other.activeID, tabs[0].id)
        XCTAssertFalse(browser.tabs.contains { $0 === tabs[0] || $0 === tabs[2] })
        XCTAssertEqual(browser.activeID, tabs[4].id, "here, the next that stayed in front")

        // Every tab going, none to hand over to: none woken on the way out.
        browser.select(tabs[4])
        XCTAssertNil(tabs[5].built)
        browser.move([tabs[4], tabs[5]], toWindow: other)
        XCTAssertNil(tabs[5].built, "not woken with nothing left to go to")
        XCTAssertEqual(other.activeID, tabs[4].id)
    }

    // MARK: - a square's name

    /// Rename on a square changes its letter, the only name it shows: the
    /// field in a row is never drawn on a square, so it did nothing.
    func testRenamingASquareChangesItsLetter() {
        let browser = makeBrowser()
        let tab = browser.tabs[1]
        browser.pin(tab)
        browser.beginTabRename(tab)
        XCTAssertEqual(browser.editingPin, tab.id)
        XCTAssertNil(browser.editingTab)
        browser.editingPin = nil
        browser.setListed(tab, true)
        browser.beginTabRename(tab)
        XCTAssertEqual(browser.editingTab, tab.id, "a row is named in its own field")
        browser.cancelTabEdit()
    }

    /// A name typed in a row is the tab's; Escape leaves the one it had,
    /// and an empty one gives the page its own title back.
    func testNamingARowKeepsReturnsAndClears() {
        let browser = makeBrowser()
        let tab = browser.tabs[1]
        browser.beginTabRename(tab)
        XCTAssertEqual(browser.tabDraft, "two", "the name it wears, to type over")
        browser.tabDraft = "Reading"
        browser.commitTabEdit()
        XCTAssertEqual(tab.label, "Reading")
        XCTAssertNil(browser.editingTab)

        browser.beginTabRename(tab)
        browser.tabDraft = "Something else"
        browser.cancelTabEdit()
        XCTAssertEqual(tab.label, "Reading", "Escape keeps the name it had")

        browser.beginTabRename(tab)
        browser.tabDraft = "  "
        browser.commitTabEdit()
        XCTAssertNil(tab.name)
        XCTAssertEqual(tab.label, "two", "the page's own title, back")
    }

    // MARK: - the address bar

    /// A click on the column's address bar raises ⌘L's field over the bar,
    /// the whole address in it; a click again, or Escape, puts it away and
    /// lets go of the bar. ⌘L's own stays in the middle of the page.
    func testTheBarRaisesTheFieldOverItself() {
        let browser = makeBrowser()
        browser.select(browser.tabs[2])
        let bar = CGRect(x: 10, y: 52, width: 212, height: Metrics.bar)
        browser.editFromBar(at: bar)
        XCTAssertTrue(browser.editing)
        XCTAssertEqual(browser.fieldAnchor, bar)
        XCTAssertEqual(browser.typed, "https://three.example/", "the whole address, to type over")

        browser.editFromBar(at: bar)
        XCTAssertFalse(browser.editing, "a click again puts it away")
        XCTAssertNil(browser.fieldAnchor)

        browser.editFromBar(at: bar)
        browser.dismiss()
        XCTAssertFalse(browser.editing)
        XCTAssertNil(browser.fieldAnchor, "Escape lets go of the bar")

        browser.edit()
        XCTAssertTrue(browser.editing)
        XCTAssertNil(browser.fieldAnchor, "⌘L's field is the page's, not the bar's")
        browser.dismiss()

        browser.editFromBar(at: bar)
        browser.launch()
        XCTAssertTrue(browser.launching)
        XCTAssertNil(browser.fieldAnchor, "⌘T's field is the page's too")
        browser.dismiss()
    }

    /// With nothing in front, the bar raises ⌘T's field over itself: no
    /// tab is made until Return opens one.
    func testTheBarWithNothingInFrontRaisesTheNewTabField() {
        let browser = makeBrowser(count: 1)
        browser.closeAll()
        XCTAssertNil(browser.active)
        let bar = CGRect(x: 10, y: 52, width: 212, height: Metrics.bar)
        browser.editFromBar(at: bar)
        XCTAssertTrue(browser.launching)
        XCTAssertEqual(browser.fieldAnchor, bar)
        browser.dismiss()
        XCTAssertNil(browser.fieldAnchor)
    }

    // MARK: - the menu bar's keys

    /// ⌥⌘T and ⌃⌘N are menu lines' keys now, which the window's own key
    /// handling leaves ⌥ and ⌃ to; Clear Tabs is listed with no key; and a
    /// group's menu shows the keys as they stand, moved ones too.
    func testMenuLinesHaveTheirKeys() throws {
        ShortcutStore.shared.resetAll()
        addTeardownBlock { @MainActor in ShortcutStore.shared.resetAll() }
        let inGroup = try XCTUnwrap(Command.named("tabs.newTabInGroup"))
        XCTAssertEqual(inGroup.defaultKey, KeyCombo("t", option: true))
        XCTAssertEqual(try XCTUnwrap(Command.named("tabs.newGroup")).defaultKey, KeyCombo("n", control: true))
        XCTAssertNil(try XCTUnwrap(Command.named("tabs.clear")).defaultKey)
        XCTAssertEqual(try XCTUnwrap(Command.named("tabs.rename")).title, "Rename Tab…")
        XCTAssertEqual(try XCTUnwrap(Command.named("tabs.separateSplit")).title, "Separate Pages")
        for number in 1...9 {
            XCTAssertEqual(ShortcutStore.shared.key(for: "spaces.\(number)"),
                           KeyCombo(String(number), command: false, control: true))
        }

        let browser = makeBrowser()
        browser.prefs.usesTabGroups = true
        let id = browser.addTabGroup(containing: browser.tabs[0])
        let group = try XCTUnwrap(browser.tabGroups.first { $0.id == id })
        func line(_ title: String) throws -> NSMenuItem {
            try XCTUnwrap(GroupMenu.make(for: group, in: browser).items.first { $0.title == title })
        }
        XCTAssertEqual(try line("New Tab in Group").keyEquivalent, "t")
        XCTAssertEqual(try line("New Tab in Group").keyEquivalentModifierMask, [.option, .command])
        XCTAssertEqual(try line("New Group").keyEquivalent, "n")
        XCTAssertEqual(try line("New Group").keyEquivalentModifierMask, [.control, .command])

        ShortcutStore.shared.assign(KeyCombo("g", shift: true, option: true), to: "tabs.newTabInGroup")
        ShortcutStore.shared.clear("tabs.newGroup")
        XCTAssertEqual(try line("New Tab in Group").keyEquivalent, "g")
        XCTAssertEqual(try line("New Tab in Group").keyEquivalentModifierMask, [.shift, .option, .command])
        XCTAssertEqual(try line("New Group").keyEquivalent, "", "no key, none shown")
    }

    /// The space icon's menu shows each space's key as it stands, as the
    /// menu bar's Spaces menu does: ⌃1 for the first, or what it was moved
    /// to, or none.
    func testTheSpaceMenuShowsTheKeysAsTheyStand() throws {
        ShortcutStore.shared.resetAll()
        addTeardownBlock { @MainActor in ShortcutStore.shared.resetAll() }
        let browser = makeBrowser()
        let name = try XCTUnwrap(browser.spaces.first?.name)
        func first() throws -> NSMenuItem {
            try XCTUnwrap(SpaceMenu.menu(for: browser).items.first { $0.title == name })
        }
        XCTAssertEqual(try first().keyEquivalent, "1")
        XCTAssertEqual(try first().keyEquivalentModifierMask, [.control])
        ShortcutStore.shared.assign(KeyCombo("1", option: true), to: "spaces.1")
        XCTAssertEqual(try first().keyEquivalentModifierMask, [.option, .command])
        ShortcutStore.shared.clear("spaces.1")
        XCTAssertEqual(try first().keyEquivalent, "", "no key, none shown")
    }

    /// Clear Tabs in the menu bar is on only while there are tabs in no
    /// group to clear.
    func testClearTabsIsOnlyOnWithTabsToClear() {
        let browser = makeBrowser()
        XCTAssertTrue(browser.canClearTabs)
        browser.clearTabs()
        XCTAssertFalse(browser.canClearTabs, "Clear leaves nothing, and no tab of its own")
    }

    // MARK: - helpers

    private func makeBrowser(count: Int = 4) -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        // One session serves every suite in the process, so a Browser opens
        // with whatever tabs the last test left.
        browser.closeAll()
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView, prefs.newTabPlace)
        addTeardownBlock { @MainActor in
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
            prefs.usesTabGroups = saved.0
            prefs.splitView = saved.1
            prefs.newTabPlace = saved.2
            CleanWorld.reset()
        }
        prefs.usesTabGroups = false
        prefs.splitView = false
        // Each new tab after the last, so they stand in the order made.
        prefs.newTabPlace = .next
        let words = ["one", "two", "three", "four", "five", "six"]
        for word in words.prefix(count) {
            if browser.tabs.last?.isBlank != true { browser.newTab() }
            if let url = URL(string: "https://\(word).example/") { browser.tabs.last?.restore(url: url, title: word) }
        }
        return browser
    }

    /// Other devices as sync would have them, put back after the test.
    private func pretend(_ devices: [DeviceTabs]) {
        let wasOn = Sync.shared.on
        addTeardownBlock { @MainActor in Sync.shared.pretend([], on: wasOn) }
        Sync.shared.pretend(devices, on: true)
    }
}
