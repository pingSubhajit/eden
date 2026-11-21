import AppKit
import XCTest
@testable import Eden
import EdenCore

/// What ⌘T's field offers besides places and searches (FieldOffers.swift),
/// after Zen's: open tabs, the groups and spaces typed, the copied link, and
/// the column's New tab row lit while the field is up.
@MainActor
final class FieldOffersTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "field-offers-\(getpid())", 1)
        super.setUp()
    }

    private var browsers: [Browser] = []

    override func tearDown() async throws {
        browsers.forEach { $0.closeAll() }
        browsers = []
        // Its pins, folders and groups out of the world the next suite
        // shares, the saved window with them (CleanWorld).
        CleanWorld.reset()
        try await super.tearDown()
    }

    private func browser() -> Browser {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browser.newsShowing = false
        // The window comes back as the last test's left it: from nothing.
        for tab in browser.tabs where !tab.isBlank { browser.close(tab) }
        browsers.append(browser)
        return browser
    }

    /// A tab at `address`, in front, loaded no further than its address.
    @discardableResult
    private func page(_ browser: Browser, _ address: String, title: String) throws -> Tab {
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        tab.restore(url: try XCTUnwrap(URL(string: address)), title: title)
        browser.activeID = tab.id
        return tab
    }

    /// Open tabs come before anything else on the empty field, most recent
    /// first and never the one in front; they come after the row Return
    /// takes once something is typed.
    func testOpenTabsOnTheEmptyFieldAndAfterTheFirstRow() throws {
        let browser = browser()
        try page(browser, "https://alpha.example/", title: "Otters at Alpha")
        try page(browser, "https://bravo.example/", title: "Bravo")
        browser.launch()
        XCTAssertTrue(browser.launching)
        let open = browser.offers.filter { $0.kind == .open }
        XCTAssertEqual(open.map(\.url.host), ["alpha.example"], "Bravo is in front, and not offered")

        browser.typed = "otters"
        XCTAssertNotEqual(browser.offers.first?.kind, .open, "the row Return takes stays first")
        XCTAssertEqual(browser.offers.dropFirst().first?.url.host, "alpha.example")
        XCTAssertEqual(browser.context(for: try XCTUnwrap(browser.offers.dropFirst().first)), .init())
    }

    /// Pins are where pages are kept (#6), and the field finds them as the
    /// open tabs they are: one asleep, in a folded kept group, as well.
    func testAPinnedRowAsleepInAFoldedFolderIsOffered() throws {
        let browser = browser()
        let kept = try page(browser, "https://kept-row.example/notes", title: "Kept notes")
        browser.pin(kept, listed: true)
        let folder = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: kept, rename: false))
        browser.setGroupFolded(folder, true)
        defer {
            browser.unpin(kept)
            browser.removeTabGroup(folder)
        }
        try page(browser, "https://front.example/", title: "Front")
        XCTAssertTrue(kept.asleep)
        XCTAssertFalse(browser.keptLines().contains { if case .tab(let tab, _) = $0 { tab === kept } else { false } },
                       "not drawn while its group is folded")
        browser.launch()
        browser.typed = "kept notes"
        XCTAssertTrue(browser.offers.contains { $0.kind == .open && $0.tab == kept.id }, "offered as the tab it is")
    }

    /// A tab in a group wears its group's name; a group's own row is Open
    /// with that name, never first and only once two letters are typed, and
    /// taking it goes to the group's tab.
    func testGroupRowsAndLabels() throws {
        let browser = browser()
        let wereOn = browser.prefs.usesTabGroups
        defer { browser.prefs.usesTabGroups = wereOn }
        browser.prefs.usesTabGroups = true
        let grouped = try page(browser, "https://alpha.example/", title: "Alpha")
        let group = browser.addTabGroup(containing: grouped)
        browser.renameTabGroup(group, to: "Reading list")
        try page(browser, "https://bravo.example/", title: "Bravo")
        browser.launch()

        let alpha = try XCTUnwrap(browser.offers.first { $0.tab == grouped.id })
        XCTAssertEqual(browser.context(for: alpha).badge, "Reading list")

        browser.typed = "r"
        XCTAssertFalse(browser.offers.contains { $0.command == .group(group) }, "one letter is too few")
        browser.typed = "readi"
        let index = try XCTUnwrap(browser.offers.firstIndex { $0.command == .group(group) })
        XCTAssertGreaterThan(index, 0, "a command on top is what Return does: never this one")
        XCTAssertEqual(browser.context(for: browser.offers[index]).name, "Open")

        browser.take(browser.offers[index])
        XCTAssertEqual(browser.activeID, grouped.id)
        XCTAssertFalse(browser.editing)
    }

    /// Return on the empty field runs nothing unpicked, though the copied
    /// link leads its list.
    func testReturnOnTheEmptyFieldLeavesTheCopiedLinkAlone() throws {
        let browser = browser()
        try page(browser, "https://alpha.example/", title: "Alpha")
        browser.copiedLink = CopiedLink(change: Clipboard.board.changeCount,
                                        url: URL(string: "https://copied.example/"), seen: Date())
        browser.launch()
        XCTAssertEqual(browser.offers.first?.command, .copiedLink(change: Clipboard.board.changeCount))
        XCTAssertEqual(browser.context(for: try XCTUnwrap(browser.offers.first)).action, "Visit from clipboard")

        let refused = browser.refusals
        browser.submit()
        XCTAssertNil(browser.copiedLinkTaken, "the link wasn't visited")
        XCTAssertEqual(browser.refusals, refused + 1, "Return on nothing says so")
    }

    /// An old copy is offered no more, nor the page in front.
    func testACopiedLinkGoesStale() throws {
        let browser = browser()
        try page(browser, "https://alpha.example/", title: "Alpha")
        let change = Clipboard.board.changeCount
        browser.copiedLink = CopiedLink(change: change, url: URL(string: "https://copied.example/"),
                                        seen: Date().addingTimeInterval(-(Browser.copiedLinkLife + 1)))
        browser.launch()
        XCTAssertFalse(browser.offers.contains { $0.command == .copiedLink(change: change) })
        browser.dismiss()

        browser.copiedLink = CopiedLink(change: change, url: URL(string: "https://alpha.example/"), seen: Date())
        browser.launch()
        XCTAssertFalse(browser.offers.contains { $0.command == .copiedLink(change: change) },
                       "the page in front, copied from it")
    }

    /// A row offered for one copy never opens another: copied again since,
    /// it is refused, and nothing is read or marked as visited.
    func testACopyMadeSinceIsNeverOpenedInItsPlace() throws {
        let browser = browser()
        try page(browser, "https://alpha.example/", title: "Alpha")
        let since = Clipboard.board.changeCount
        XCTAssertNil(browser.copiedLinkURL(since - 1))
        XCTAssertNil(browser.copiedLinkTaken)
    }

    /// The clipboard is a link only when it is one address and nothing else.
    func testOnlyALinkAloneIsALink() {
        let board = NSPasteboard(name: NSPasteboard.Name("eden.tests.field-offers.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        func link(_ text: String) -> URL? {
            board.clearContents()
            board.setString(text, forType: .string)
            return Clipboard.link(in: board)
        }
        XCTAssertEqual(link("  https://example.com/a?b=c \n")?.absoluteString, "https://example.com/a?b=c")
        XCTAssertEqual(link("example.com")?.host, "example.com")
        XCTAssertNil(link("read https://example.com later"))
        XCTAssertNil(link("otters"))
        XCTAssertNil(link("file:///etc/hosts"))
    }

    /// ⌘L lists what ⌘T lists, as Zen's do, under the page's own address
    /// left as it was; only where Return goes differs. Return on that
    /// address leaves the copied link alone, which heads the list.
    func testCommandLListsWhatCommandTLists() throws {
        let browser = browser()
        try page(browser, "https://alpha.example/", title: "Alpha")
        let bravo = try page(browser, "https://bravo.example/", title: "Bravo")
        browser.copiedLink = CopiedLink(change: Clipboard.board.changeCount,
                                        url: URL(string: "https://copied.example/"), seen: Date())
        browser.launch()
        let fromT = browser.offers.map(\.id)
        browser.dismiss()

        browser.edit()
        XCTAssertEqual(browser.fieldMode, .thisTab)
        XCTAssertTrue(browser.typed.hasPrefix("https://bravo.example"), "the page's address, to type over")
        XCTAssertEqual(browser.offers.map(\.id), fromT)

        browser.submit()
        XCTAssertNil(browser.copiedLinkTaken, "the copied link wasn't visited")
        XCTAssertEqual(browser.activeID, bravo.id)
        XCTAssertEqual(browser.active?.address?.host, "bravo.example")

        browser.edit()
        browser.typed = "alph"
        XCTAssertNotEqual(browser.offers.map(\.id), fromT, "typed over, it lists for what was typed")
    }

    /// While ⌘T's field is up, the column marks no tab as the one you're
    /// on: its New tab row is lit instead.
    func testNoTabLiveWhileTheFieldIsUp() throws {
        let browser = browser()
        let tab = try page(browser, "https://alpha.example/", title: "Alpha")
        XCTAssertEqual(browser.liveID, tab.id)
        browser.launch()
        XCTAssertNil(browser.liveID)
        browser.dismiss()
        XCTAssertEqual(browser.liveID, tab.id)
    }
}
