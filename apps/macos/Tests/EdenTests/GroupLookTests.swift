import AppKit
import EdenCore
import XCTest
@testable import Eden

/// A tab group's colour and icon (GroupLook.swift): kept with the session,
/// read back by an Eden from before as it always was, and what its menu
/// does — a new tab in it, a new group, duplicating it, copying its links.
@MainActor
final class GroupLookTests: XCTestCase {
    private var browser: Browser!

    override class func setUp() {
        setenv("EDEN_PROBE", "group-look-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.prefs.usesTabGroups = true
        browser.closeAll()
    }

    override func tearDown() {
        browser.closeAll()
        browser = nil
    }

    private func tab(_ url: String) -> Eden.Tab {
        let tab = Eden.Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.setAddressOptimistically(URL(string: url)!)
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        return tab
    }

    func testAGroupFromBeforeReadsNeutralAndWithoutAnIcon() throws {
        let old = #"{"id":"8C1F2C5E-0B0B-4C33-9E59-2F2B8D3B1A10","name":"Work","collapsed":true}"#
        let group = try JSONDecoder().decode(TabGroup.self, from: Data(old.utf8))
        XCTAssertEqual(group.colour, .stone)
        XCTAssertNil(group.icon)
        XCTAssertTrue(group.collapsed)
        // Written back unchanged: no colour or icon keys an older Eden would meet.
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(group)) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["id", "name", "collapsed"])
    }

    func testAColourAndAnIconGoAndComeBackTheSame() throws {
        var group = TabGroup(id: UUID(), name: "Gardens", collapsed: false, colour: .madder, icon: .emoji("🏛️"))
        XCTAssertEqual(try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(group)), group)
        group.icon = .symbol("leaf.fill")
        XCTAssertEqual(try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(group)), group)
    }

    func testAColourOrIconANewerEdenAddedReadsAsNone() throws {
        let newer = #"{"id":"8C1F2C5E-0B0B-4C33-9E59-2F2B8D3B1A10","name":"Work","collapsed":false,"colour":"teal","icon":"sticker:🦊"}"#
        let group = try JSONDecoder().decode(TabGroup.self, from: Data(newer.utf8))
        XCTAssertEqual(group.colour, .stone)
        XCTAssertNil(group.icon)
    }

    func testTheMenuSetsAColourAndAnIcon() throws {
        let a = tab("https://a.example/")
        let id = browser.addTabGroup(containing: a)
        XCTAssertEqual(browser.tabGroups.first?.name, "Group 1", "numbered, its name being typed")
        XCTAssertEqual(browser.editingGroupID, id)
        XCTAssertEqual(browser.tabGroups.first?.colour, .stone, "neutral until one is chosen")
        browser.setColour(.sage, ofGroup: id)
        browser.setIcon(.symbol("leaf.fill"), ofGroup: id)
        XCTAssertEqual(browser.tabGroups.first?.colour, .sage)
        XCTAssertEqual(browser.tabGroups.first?.icon, .symbol("leaf.fill"))
        browser.setIcon(nil, ofGroup: id)
        XCTAssertNil(browser.tabGroups.first?.icon, "back to its first tab's site icon")
    }

    func testANewTabInTheGroupOfTheTabInFront() throws {
        let a = tab("https://a.example/")
        let id = browser.addTabGroup(containing: a)
        browser.select(a)
        let before = browser.tabs.count
        browser.newTab(inGroup: nil)
        XCTAssertEqual(browser.tabs.count, before + 1)
        XCTAssertEqual(browser.active.flatMap { browser.group(of: $0) }, id)
    }

    func testDuplicateKeepsTheLookAndOpensEachPageAgain() throws {
        let a = tab("https://a.example/"), b = tab("https://b.example/")
        let id = browser.addTabGroup(containing: a)
        browser.move(b, toGroup: id)
        browser.renameTabGroup(id, to: "Reading")
        browser.setColour(.ochre, ofGroup: id)
        browser.setIcon(.emoji("📚"), ofGroup: id)
        browser.duplicateTabGroup(id)
        XCTAssertEqual(browser.tabGroups.count, 2)
        let copy = try XCTUnwrap(browser.tabGroups.last)
        XCTAssertNotEqual(copy.id, id)
        XCTAssertEqual(copy.name, "Reading")
        XCTAssertEqual(copy.colour, .ochre)
        XCTAssertEqual(copy.icon, .emoji("📚"))
        XCTAssertEqual(browser.tabs(in: copy.id).compactMap { $0.address?.absoluteString },
                       ["https://a.example/", "https://b.example/"])
    }

    func testDuplicateLeavesEdensOwnPagesWithTheOriginal() throws {
        let a = tab("https://a.example/"), settings = tab(InternalPage(.settings).url.absoluteString)
        let id = browser.addTabGroup(containing: a)
        browser.move(settings, toGroup: id)
        browser.duplicateTabGroup(id)
        let copy = try XCTUnwrap(browser.tabGroups.last)
        XCTAssertEqual(browser.tabs(in: id).map(\.id), [a.id, settings.id], "the original keeps its tabs")
        XCTAssertEqual(browser.tabs(in: copy.id).compactMap { $0.address?.absoluteString }, ["https://a.example/"])
    }

    func testDuplicateMakesOrdinaryTabsWithAPrivateTabInFront() throws {
        let a = tab("https://a.example/")
        let id = browser.addTabGroup(containing: a)
        let shy = Eden.Tab(shy: true, configuration: Web.configuration(shy: true, store: nil))
        browser.prepare(shy)
        browser.insert(shy, at: browser.tabs.count)
        browser.activeID = shy.id
        browser.duplicateTabGroup(id)
        let copy = try XCTUnwrap(browser.tabGroups.last)
        let copies = browser.tabs(in: copy.id)
        XCTAssertEqual(copies.count, 1)
        XCTAssertFalse(copies[0].shy)
        XCTAssertNotEqual(copies[0].id, a.id)
    }

    func testCopyAllLinksPutsEachTabsAddressOnALine() throws {
        let a = tab("https://a.example/"), b = tab("https://b.example/")
        let id = browser.addTabGroup(containing: a)
        browser.move(b, toGroup: id)
        browser.copyLinks(of: id)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "https://a.example/\nhttps://b.example/")
    }
}
