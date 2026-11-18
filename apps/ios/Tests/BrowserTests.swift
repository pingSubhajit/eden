import EdenCore
import Foundation
import Testing
import WebKit
@testable import Eden

/// The browser's tabs, what is written between launches, and where typed
/// text goes. Runs in a test world of its own (EDEN_PROBE in the scheme), so
/// no page is loaded and nothing of the app's own is touched.
@MainActor
struct BrowserTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("eden-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func browser(session: URL? = nil, settings: Settings? = nil) -> Browser {
        Browser(history: History(file: "history-\(UUID().uuidString).json", read: { _ in nil }),
                bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks-\(UUID().uuidString).json")),
                settings: settings ?? Settings(store: freshDefaults()),
                sessionFile: session)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "eden-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let a = URL(string: "https://a.example/")!
    private let b = URL(string: "https://b.example/")!
    private let c = URL(string: "https://c.example/")!

    @Test func aFirstLaunchHasOneEmptyTabInFront() {
        let browser = browser()
        #expect(browser.tabs.count == 1)
        #expect(browser.active?.url == nil)
        #expect(browser.active?.isPrivate == false)
    }

    @Test func aNewTabGoesAfterItsOpenerAndInFront() {
        let browser = browser()
        let first = browser.tabs[0]
        let last = browser.newTab(url: a)
        let beside = browser.newTab(url: b, select: false, after: first)
        #expect(browser.tabs.map(\.id) == [first.id, beside.id, last.id])
        #expect(browser.activeID == last.id, "a tab opened behind leaves the one in front")
    }

    @Test func closingTheTabInFrontPicksTheNextOfItsKind() {
        let browser = browser()
        let first = browser.tabs[0]
        let second = browser.newTab(url: a)
        let hidden = browser.newTab(url: b, private: true)
        let third = browser.newTab(url: c)
        browser.select(second)
        browser.close(second)
        #expect(browser.activeID == third.id, "the next ordinary tab, not the private one between")
        browser.close(third)
        #expect(browser.activeID == first.id, "with none after it, the one before")
        browser.select(hidden)
        browser.close(hidden)
        #expect(browser.activeID == first.id)
    }

    @Test func closingTheLastTabLeavesAnEmptyOne() {
        let browser = browser()
        browser.close(browser.tabs[0])
        #expect(browser.tabs.count == 1)
        #expect(browser.active?.url == nil)
    }

    @Test func typedTextGoesToAnAddressOrASearch() throws {
        let browser = browser()
        let tab = try #require(browser.active)
        #expect(browser.go("example.com", in: tab))
        #expect(tab.url?.absoluteString == "https://example.com")
        #expect(browser.go("eden browser", in: tab))
        #expect(tab.url?.host() == "www.google.com")
        #expect(!browser.go("   ", in: tab), "nothing typed goes nowhere")
    }

    @Test func theEngineChosenIsTheOneSearched() throws {
        let settings = Settings(store: freshDefaults())
        settings.engine = .duckduckgo
        let browser = browser(settings: settings)
        #expect(browser.destination(for: "eden browser")?.host() == "duckduckgo.com")
    }

    @Test func aPagesWindowOpensBesideItWithItsPrivacy() throws {
        let browser = browser()
        let opener = browser.newTab(url: a, private: true)
        let other = browser.newTab(url: b, private: true)
        let opened = try #require(browser.adopt(configuration: Tab.configuration(private: true),
                                                request: URLRequest(url: c), from: opener))
        #expect(opened.isPrivate)
        #expect(opened.url == c)
        #expect(browser.activeID == opened.id)
        let at = try #require(browser.tabs.firstIndex(of: opener))
        #expect(browser.tabs.firstIndex(of: opened) == at + 1)
        #expect(browser.tabs.last?.id == other.id)
    }

    @Test func theSessionKeepsOrdinaryTabsAndNeverPrivateOnes() {
        let browser = browser()
        browser.tabs[0].load(a)
        browser.newTab(url: b)
        browser.newTab(url: c, private: true)
        let session = browser.session
        #expect(session.tabs.map(\.url) == [a.absoluteString, b.absoluteString])
        #expect(session.active == nil, "the private tab in front is in no session")
        browser.select(browser.tabs[1])
        #expect(browser.session.active == 1)
    }

    @Test func theSessionComesBackAtTheNextLaunch() {
        let file = folder.appendingPathComponent("tabs.json")
        let first = browser(session: file)
        first.tabs[0].load(a)
        first.newTab(url: b)
        first.newTab(url: c, private: true)
        first.select(first.tabs[0])
        Disk.drain()
        let second = browser(session: file)
        #expect(second.tabs.map(\.url) == [a, b])
        #expect(second.tabs.allSatisfy { !$0.isPrivate })
        #expect(second.activeID == second.tabs[0].id)
    }

    @Test func withAPrivateTabInFrontTheLastTabComesBackInFront() {
        let file = folder.appendingPathComponent("tabs.json")
        let first = browser(session: file)
        first.tabs[0].load(a)
        first.newTab(url: b)
        first.newTab(url: c, private: true)
        #expect(first.session.active == nil, "a private tab is in no session")
        Disk.drain()
        let second = browser(session: file)
        #expect(second.tabs.map(\.url) == [a, b])
        #expect(second.activeID == second.tabs.last?.id, "never none in front")
    }

    /// Nothing in Browser makes a tab's page: only showing it does
    /// (PageView), which waits for a test's fresh start to finish clearing.
    @Test func goingSomewhereMakesNoPageUntilItIsShown() throws {
        let browser = browser()
        let tab = try #require(browser.active)
        #expect(browser.go("example.com", in: tab))
        browser.newTab(url: URL(string: "https://example.org/")!)
        #expect(browser.tabs.allSatisfy { !$0.isBuilt })
        #expect(tab.isPending)
    }

    @Test func aRestoredTabLoadsWhenShownAndAPopUpNever() {
        let browser = browser()
        let restored = Tab(isPrivate: false)
        restored.restore(url: a, title: "A")
        #expect(restored.isPending, "a restored tab loads its address once shown")
        let opener = browser.newTab(url: b)
        let popUp = browser.adopt(configuration: Tab.configuration(private: false), request: URLRequest(url: c), from: opener)
        #expect(popUp?.url == c, "a pop-up shows the address it was opened at")
        #expect(popUp?.isPending == false, "WebKit loads a pop-up's request itself; it isn't loaded again")
        let later = Tab(isPrivate: false)
        later.load(c)
        #expect(later.isPending, "an address asked for before the page is made waits for it")
    }

    /// A test run's ordinary tabs keep their cookies in the test world's own
    /// store, never in the one whoever browses on this device uses.
    @Test func aTestRunNeverUsesTheDefaultWebsiteStore() {
        #expect(Store.testing, "the scheme runs these tests in a test world")
        let store = Tab.configuration(private: false).websiteDataStore
        #expect(store !== WKWebsiteDataStore.default())
        #expect(store.isPersistent)
        #expect(store.identifier == Store.probeStore(1))
        #expect(!Tab.configuration(private: true).websiteDataStore.isPersistent)
    }

    @Test func aBrokenSessionIsSetAsideNotReadOrLost() throws {
        let file = folder.appendingPathComponent("tabs.json")
        try Data("not json".utf8).write(to: file)
        let browser = browser(session: file)
        #expect(browser.tabs.count == 1)
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(aside.contains { $0.hasPrefix("tabs.unreadable-") })
    }
}

/// Hidden elements on iPhone and iPad (Hiding.swift): a private tab puts
/// back what is kept, and its own changes — shared with the windows it opens
/// — last as long as it, never kept, merged with what is kept by selector.
@MainActor
struct HidingTests {
    private let site = "example.com"
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hiding-\(UUID().uuidString)")

    private func browser() -> (Browser, Curtain) {
        let curtain = Curtain(file: folder.appendingPathComponent("hidden.json"))
        curtain.hide("#kept", label: "Kept", note: "", on: site)
        let name = "eden-tests-\(UUID().uuidString)"
        let browser = Browser(history: History(file: "history-\(UUID().uuidString).json", read: { _ in nil }),
                              bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json")),
                              settings: Settings(store: UserDefaults(suiteName: name)!), curtain: curtain,
                              sessionFile: nil)
        return (browser, curtain)
    }

    private func choice(_ selector: String) -> VeilMessage.Choice {
        VeilMessage.Choice(selector: selector, label: selector, note: "")
    }

    @Test func aPrivateTabsOwnHidingIsItsAloneAndNeverKept() throws {
        let (browser, curtain) = browser()
        let shy = browser.newTab(private: true)
        let plain = browser.newTab()
        browser.hide(choice("#mine"), on: site, in: shy)
        browser.hide(choice("#elsewhere"), on: "other.example", in: shy)
        #expect(browser.veils(on: site, in: shy.privateHiding).map(\.selector) == ["#kept", "#mine"], "only this site's")
        #expect(browser.veils(on: site, in: plain.privateHiding).map(\.selector) == ["#kept"], "never another tab's")

        browser.restore(try #require(curtain.veils(on: site).first), on: site, in: shy)
        #expect(browser.veils(on: site, in: shy.privateHiding).map(\.selector) == ["#mine"])
        browser.restoreAll(on: site, in: shy)
        #expect(browser.veils(on: site, in: shy.privateHiding).isEmpty)
        #expect(curtain.veils(on: site).map(\.selector) == ["#kept"], "what is kept, untouched")
        #expect(browser.stylesheets(in: shy.privateHiding)["other.example"] == "#elsewhere { display: none !important; }")
        #expect(browser.stylesheets(in: shy.privateHiding)[site] == "")
    }

    @Test func aPrivateChangeHoldsWhateverIsKeptDoes() throws {
        let (browser, curtain) = browser()
        let shy = browser.newTab(private: true)
        let plain = browser.newTab()

        // Shown here, then no longer kept, then hidden here again: hidden.
        browser.restore(try #require(curtain.veils(on: site).first), on: site, in: shy)
        browser.restoreAll(on: site, in: plain)
        browser.hide(choice("#kept"), on: site, in: shy)
        #expect(browser.veils(on: site, in: shy.privateHiding).map(\.selector) == ["#kept"])

        // Hidden here, then kept too: once.
        browser.hide(choice("#both"), on: site, in: shy)
        browser.hide(choice("#both"), on: site, in: plain)
        let selectors = browser.veils(on: site, in: shy.privateHiding).map(\.selector)
        #expect(selectors == ["#both", "#kept"], "kept first, each once")
    }

    @Test func aPrivateWindowSharesItsOpenersChanges() throws {
        let (browser, _) = browser()
        let opener = browser.newTab(private: true)
        let page = try #require(URL(string: "https://example.com/"))
        let popUp = try #require(browser.adopt(configuration: Tab.configuration(private: true),
                                               request: URLRequest(url: page), from: opener))
        #expect(popUp.privateHiding === opener.privateHiding, "the same scripts serve both")
        #expect(browser.newTab().privateHiding == nil)
        #expect(browser.newTab(private: true).privateHiding !== opener.privateHiding)
    }
}

/// Your bookmarks, kept in their file.
@MainActor
struct BookmarkStoreTests {
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("bookmarks-\(UUID().uuidString).json")
    private let page = URL(string: "https://example.com/article")!

    @Test func aPageIsKeptOnceAndLetGo() {
        let store = BookmarkStore(file: file)
        store.add(page, title: "Article")
        store.add(page, title: "Article again")
        #expect(store.items.count == 1)
        #expect(store.contains(page))
        #expect(store.toggle(page, title: "Article") == false)
        #expect(!store.contains(page))
        #expect(store.toggle(page, title: "Article") == true)
    }

    @Test func theyComeBackFromTheirFile() {
        let store = BookmarkStore(file: file)
        store.add(page, title: "Article")
        Disk.drain()
        let again = BookmarkStore(file: file)
        #expect(again.items.map(\.title) == ["Article"])
        #expect(again.items.first?.address == page)
    }

    @Test func everyWordTypedMustMatch() {
        let store = BookmarkStore(file: file)
        store.add(page, title: "Long Article")
        store.add(URL(string: "https://other.example/")!, title: "Other")
        #expect(store.matching("long art").map(\.title) == ["Long Article"])
        #expect(store.matching("example article").count == 1)
        #expect(store.matching("nothing").isEmpty)
        #expect(store.matching("  ").isEmpty)
    }
}

/// The rows under the address field.
@MainActor
struct SuggestionsTests {
    private func browser() -> Browser {
        let name = "eden-tests-\(UUID().uuidString)"
        return Browser(history: History(file: "history-\(UUID().uuidString).json", read: { _ in nil }),
                       bookmarks: BookmarkStore(file: FileManager.default.temporaryDirectory
                        .appendingPathComponent("bookmarks-\(UUID().uuidString).json")),
                       settings: Settings(store: UserDefaults(suiteName: name)!),
                       sessionFile: nil)
    }

    @Test func anAddressGoesFirst() {
        let rows = Suggestions.offers(for: "example.com", in: browser())
        #expect(rows.first?.kind == .known)
        #expect(rows.first?.url.absoluteString == "https://example.com")
    }

    @Test func wordsAreSearchedFirst() {
        let rows = Suggestions.offers(for: "eden browser", in: browser())
        #expect(rows.first?.kind == .search)
        #expect(rows.first?.url.host() == "www.google.com")
    }

    @Test func anOpenTabAndABookmarkAreOffered() {
        let browser = browser()
        let page = URL(string: "https://news.example/today")!
        browser.newTab(url: page, select: false)
        browser.bookmarks.add(URL(string: "https://docs.example/guide")!, title: "News Guide")
        let rows = Suggestions.offers(for: "news", in: browser)
        #expect(rows.contains { $0.kind == .open && $0.url == page && $0.tab != nil })
        #expect(rows.contains { $0.kind == .bookmark && $0.title == "News Guide" })
    }

    @Test func theTabInFrontIsNotOfferedAsATabToSwitchTo() {
        let browser = browser()
        browser.newTab(url: URL(string: "https://news.example/today")!)
        #expect(!Suggestions.offers(for: "news", in: browser).contains { $0.kind == .open })
    }

    @Test func aPrivateTabIsNeverOffered() {
        let browser = browser()
        browser.newTab(url: URL(string: "https://secret.example/")!, private: true, select: false)
        #expect(!Suggestions.offers(for: "secret", in: browser).contains { $0.kind == .open })
    }

    @Test func eachPageOnce() {
        let browser = browser()
        let page = URL(string: "https://example.com/")!
        browser.newTab(url: page, select: false)
        browser.bookmarks.add(page, title: "Example")
        let rows = Suggestions.offers(for: "example", in: browser)
        let ids = rows.filter { $0.kind != .search }.map { History.identity(for: $0.url) }
        #expect(Set(ids).count == ids.count)
        #expect(Suggestions.offers(for: "   ", in: browser).isEmpty)
    }
}

/// What can be chosen, and what each starts as.
@MainActor
struct SettingsTests {
    @Test func theDefaultsAreGoogleBlockingAndNoHandoff() {
        let name = "eden-tests-\(UUID().uuidString)"
        let settings = Settings(store: UserDefaults(suiteName: name)!)
        #expect(settings.engine == .google)
        #expect(settings.blocks)
        #expect(!settings.handsOff)
    }

    @Test func choicesAreKeptUnderTheMacsKeys() {
        let name = "eden-tests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let settings = Settings(store: store)
        settings.engine = .kagi
        settings.blocks = false
        settings.handsOff = true
        #expect(store.string(forKey: "search.engine") == "kagi")
        #expect(store.object(forKey: "shield") as? Bool == false)
        #expect(store.bool(forKey: "handoff"))
        let again = Settings(store: store)
        #expect(again.engine == .kagi && !again.blocks && again.handsOff)
    }
}
