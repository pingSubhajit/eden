import EdenCore
import AppKit
import XCTest
@testable import Eden

final class FuzzyTests: XCTestCase {
    private func nearly(_ typed: String, _ text: String) -> Bool {
        Fuzzy.nearly(Array(typed.utf8), in: text.lowercased())
    }

    func testASlipFindsTheWordItMeant() {
        XCTAssertTrue(nearly("githb", "GitHub"), "a letter left out")
        XCTAssertTrue(nearly("gihtub", "github.com"), "two letters swapped")
        XCTAssertTrue(nearly("youtbe", "YouTube"))
        XCTAssertTrue(nearly("wikipeida", "wikipedia.org"))
        XCTAssertTrue(nearly("igthub", "github"), "the first two swapped")
        XCTAssertTrue(nearly("documantation", "Swift Documentation"), "two slips in a long word")
    }

    func testTooFarOrTooShortFindsNothing() {
        XCTAssertFalse(nearly("gti", "git"), "under four letters, no slips")
        XCTAssertFalse(nearly("xithub", "github"), "the first letter has to be right")
        XCTAssertFalse(nearly("gthbb", "github"))
        XCTAssertFalse(nearly("hello", "world wide web"))
    }

    func testLettersInOrderAbbreviate() {
        XCTAssertTrue(Fuzzy.abbreviates("dwn", "downloads"))
        XCTAssertFalse(Fuzzy.abbreviates("wnd", "downloads"))
        XCTAssertFalse(Fuzzy.abbreviates("dnw", "downloads"))
    }
}

@MainActor
final class AddressCommandTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "address-commands-\(getpid())", 1)
        super.setUp()
    }

    func testPartOfANameIsOfferedButNeverTakesReturn() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let saved = browser.prefs.commandBar
        defer { browser.prefs.commandBar = saved }
        browser.prefs.commandBar = true

        XCTAssertEqual(AddressCommand.matching("downloads", in: browser), .downloads)
        XCTAssertNil(AddressCommand.near("downloads", in: browser), "a whole name is the command itself")
        for typed in ["down", "dwn", "Downl", "downlaods", "dowloads"] {
            XCTAssertEqual(AddressCommand.near(typed, in: browser), .downloads, typed)
        }
        XCTAssertEqual(AddressCommand.near("priv", in: browser), .newPrivateTab)
        XCTAssertEqual(AddressCommand.near("setings", in: browser), .settings)
        XCTAssertNil(AddressCommand.near("do", in: browser), "two letters are any search")
        XCTAssertNil(AddressCommand.near("weather", in: browser))

        let exact = browser.placeOffers(for: "downloads").offers
        XCTAssertEqual(exact.first?.command, .downloads, "a whole name still runs on Return")

        let part = browser.placeOffers(for: "dwn").offers
        XCTAssertEqual(part.last?.command, .downloads, "part of a name is offered, last")
        XCTAssertFalse(part.first?.kind.isCommand ?? true, "and Return still searches")

        browser.prefs.commandBar = false
        XCTAssertFalse(browser.placeOffers(for: "dwn").offers.contains { $0.kind.isCommand }, "off means off")
    }

    func testMenuCommandsAndSettingsPagesAreOfferedUnderTheRest() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.commandBar, prefs.splitView, prefs.ai)
        defer { (prefs.commandBar, prefs.splitView, prefs.ai) = saved }
        prefs.commandBar = true

        // By the words of the name, in any order, from their start.
        XCTAssertEqual(AddressCommand.listed("hide el", in: browser).first, .menu("view.hide"))
        XCTAssertEqual(AddressCommand.listed("page fin", in: browser).first, .menu("edit.find"))
        XCTAssertEqual(AddressCommand.listed("priv tab", in: browser).first, .menu("file.newPrivateTab"))
        XCTAssertEqual(AddressCommand.listed("appear", in: browser).first, .page(.appearance))
        XCTAssertEqual(AddressCommand.listed("privacy", in: browser).first, .page(.privacy))
        XCTAssertTrue(AddressCommand.listed("zoom", in: browser).starts(with: [.menu("view.zoomIn"), .menu("view.zoomOut")]))
        XCTAssertEqual(AddressCommand.menu("view.hide").title, "Hide Elements…")
        XCTAssertEqual(AddressCommand.menu("view.hide").key, ShortcutStore.shared.key(for: "view.hide")?.display)
        XCTAssertEqual(AddressCommand.page(.privacy).title, "Privacy Settings")

        // Never an address, nor two letters, nor what a word above already is.
        XCTAssertTrue(AddressCommand.listed("reload.com", in: browser).isEmpty)
        XCTAssertTrue(AddressCommand.listed("zo", in: browser).isEmpty)
        XCTAssertFalse(AddressCommand.listed("downloads", in: browser).contains(.menu("history.downloads")))
        XCTAssertFalse(AddressCommand.listed("address", in: browser).contains(.menu("file.openAddress")), "the field is open")

        // Hidden where the menu hides it: a feature off, no page, no pair.
        prefs.splitView = false
        XCTAssertFalse(AddressCommand.listed("split", in: browser).contains(.menu("tabs.split")))
        prefs.splitView = true
        XCTAssertTrue(AddressCommand.listed("split", in: browser).contains(.menu("tabs.split")))
        XCTAssertFalse(AddressCommand.listed("swap pages", in: browser).contains(.menu("tabs.swapSplit")), "no pair on screen")
        prefs.ai = false
        XCTAssertTrue(AddressCommand.listed("summarize", in: browser).isEmpty)
        let captures = prefs.capturesPages
        prefs.capturesPages = false
        XCTAssertFalse(AddressCommand.listed("capture", in: browser).contains(.menu("view.capture")), "Capture pages off")
        prefs.capturesPages = true
        XCTAssertTrue(AddressCommand.listed("capture", in: browser).contains(.menu("view.capture")))
        prefs.capturesPages = captures
        XCTAssertNotEqual(browser.active?.isWeb, true)
        XCTAssertTrue(AddressCommand.listed("reader", in: browser).isEmpty, "no page to read")

        // Under the search, so Return still searches; the menu's action runs.
        let offers = browser.placeOffers(for: "find on page").offers
        XCTAssertFalse(offers.first?.kind.isCommand ?? true)
        XCTAssertEqual(offers.last?.command, .menu("edit.find"))
        // Find needs a page; Hide Sidebar does not.
        let folded = browser.folded
        AddressCommand.menu("view.fold").run(on: browser)
        XCTAssertNotEqual(browser.folded, folded, "the menu's own action")
        AddressCommand.menu("view.fold").run(on: browser)

        prefs.commandBar = false
        XCTAssertFalse(browser.placeOffers(for: "find on page").offers.contains { $0.kind.isCommand }, "off means off")
    }

    /// A suggestion carries a command by an identifier of its own
    /// (Suggestion.Command, in EdenCore): every command comes back as itself.
    func testEveryCommandSurvivesASuggestion() {
        let commands = AddressCommand.allCases + [.menu("tabs.pinRow"), .menu("view.fold")]
            + SettingsPanel.Page.allCases.map(AddressCommand.page)
        for command in commands {
            XCTAssertEqual(AddressCommand(command.suggested), command, "\(command)")
            XCTAssertEqual(Suggestion.command(command).command, command, "\(command)")
        }
        XCTAssertNil(AddressCommand(Suggestion.Command("page:nowhere")))
        XCTAssertNil(AddressCommand(Suggestion.Command("unknown")))
        let visited = Suggestion(key: "example.com", title: "", url: URL(string: "https://example.com")!, kind: .visited)
        XCTAssertNil(visited.command)
    }
}
