import EdenCore
import Foundation
import Testing
import WebKit
@testable import Eden

/// Your other devices' pages here (OtherDevices.swift, Syncing): opened in
/// their own space, never twice, carried on as they were left; what this
/// device tells them; and what the address field offers of theirs.
@MainActor
struct ElsewhereTests {
    private let folder: URL
    private let defaults: UserDefaults
    private let a = URL(string: "https://a.example/")!
    private let b = URL(string: "https://b.example/")!

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("eden-elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "eden-elsewhere-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
    }

    private func launch() -> (Browser, Syncing) {
        let settings = Settings(store: defaults)
        settings.usesSpaces = true
        let browser = Browser(history: History(file: "history-\(UUID().uuidString).json", read: { _ in nil }),
                              bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json")),
                              settings: settings, curtain: Curtain(file: folder.appendingPathComponent("hidden.json")),
                              library: SpaceLibrary(file: nil, store: defaults), pins: PinStore(file: nil, store: defaults),
                              stores: WebsiteStores(settings: defaults), sessionFile: nil)
        let syncing = Syncing(browser: browser)
        browser.sync = syncing
        return (browser, syncing)
    }

    private func mac(_ pages: [DeviceTabs.Page], seen: Double? = nil, front: Int? = nil,
                     closed: [DeviceTabs.Closed]? = nil) -> DeviceTabs {
        DeviceTabs(device: "mac", name: "Mac", kind: .mac, tabs: pages, at: Date().timeIntervalSince1970,
                   front: front, seen: seen, closed: closed)
    }

    @Test func aPageFromTheMacOpensInItsOwnSpaceAsItWasLeft() throws {
        let (browser, syncing) = launch()
        let work = browser.addSpace(named: "Work", sharesSignIns: true)
        browser.enter(Space.firstID)
        let page = DeviceTabs.Page(url: a.absoluteString, title: "A", space: work.id, scroll: 0.6, reading: true)
        syncing.showOtherTabs([mac([page])])
        browser.open(Elsewhere.Offer(device: mac([page]), page: page))
        #expect(browser.spaceID == work.id, "in the space it was open in")
        #expect(browser.active?.url == a)
        #expect(browser.active?.arrival == Tab.Arrival(page: a, scroll: 0.6, reading: true, from: "your Mac"))
        #expect(browser.isOpenHere(page))
        withExtendedLifetime(syncing) {}
    }

    @Test func aPageAlreadyOpenHereIsSwitchedToNeverOpenedTwice() throws {
        let (browser, syncing) = launch()
        let mine = try #require(browser.active)
        mine.restore(url: a, title: "A")
        browser.newTab(url: b)
        let page = DeviceTabs.Page(url: a.absoluteString, title: "A", space: Space.firstID, scroll: 0.7, reading: true)
        browser.open(Elsewhere.Offer(device: mac([page]), page: page))
        #expect(browser.active === mine)
        #expect(browser.ordinaryTabs.count == 2)
        #expect(mine.arrival == Tab.Arrival(page: a, scroll: 0.7, reading: true, from: "your Mac"),
                "read as it was left there, once its page is in")
        withExtendedLifetime(syncing) {}
    }

    @Test func aStartPagesEmptyTabTakesThePageItself() throws {
        let (browser, syncing) = launch()
        let empty = try #require(browser.active)
        let page = DeviceTabs.Page(url: b.absoluteString, title: "B", space: Space.firstID)
        browser.open(Elsewhere.Offer(device: mac([page]), page: page), in: empty)
        #expect(browser.ordinaryTabs.count == 1)
        #expect(empty.url == b)
        withExtendedLifetime(syncing) {}
    }

    @Test func whatThisDeviceTellsTheOthers() throws {
        let (browser, syncing) = launch()
        let work = browser.addSpace(named: "Work", sharesSignIns: true)
        let reading = try #require(browser.active)
        reading.restore(url: a, title: "A")
        let gone = browser.newTab(url: b)
        browser.close(gone)
        browser.select(reading)
        let scope = AppScope(syncing: syncing, browser: browser)
        let item = try #require(scope.snapshot(agreed: [:])[SyncItems.tabsKey(syncing.device)])
        let mine = try #require(SyncMerge.value(DeviceTabs.self, item))
        #expect(mine.tabs.map(\.url) == [a.absoluteString])
        #expect(mine.tabs.first?.space == work.id)
        #expect(mine.frontPage?.url == a.absoluteString)
        #expect(mine.closed?.map(\.url) == [b.absoluteString], "closed a moment ago")
        #expect(mine.closed?.first?.space == work.id)
        // Asked again with nothing changed, the same item: no edit.
        let again = try #require(scope.snapshot(agreed: [:])[SyncItems.tabsKey(syncing.device)])
        #expect(again == item)
    }

    @Test func thePageInFrontIsKeptWhenItIsOpenTwice() throws {
        let (browser, syncing) = launch()
        let first = try #require(browser.active)
        first.restore(url: a, title: "A")
        let work = browser.addSpace(named: "Work", sharesSignIns: true)
        let second = try #require(browser.active)
        second.restore(url: a, title: "A")
        let scope = AppScope(syncing: syncing, browser: browser)
        let item = try #require(scope.snapshot(agreed: [:])[SyncItems.tabsKey(syncing.device)])
        let mine = try #require(SyncMerge.value(DeviceTabs.self, item))
        #expect(mine.tabs.count == 1, "each page once")
        #expect(mine.frontPage?.space == work.id, "the one in front, with its space")
    }

    @Test func aDeviceWithOnlyClosedPagesOffersThemButListsNoTabs() throws {
        let closed = [DeviceTabs.Closed(url: a.absoluteString, title: "A", at: Date().timeIntervalSince1970)]
        let item = try #require(SyncMerge.text(mac([], closed: closed)))
        let heard = SyncItems.otherTabs(["tabs:mac": item], except: "me", now: Date().timeIntervalSince1970)
        #expect(heard.count == 1, "still heard, for what it closed")
        #expect(heard.filter(\.hasTabs).isEmpty, "with no tabs to list")
        #expect(Elsewhere.closed(on: heard, now: Date().timeIntervalSince1970, openHere: []).count == 1)
    }

    @Test func aPrivateTabOrAPinIsNeverClosedForTheOthers() throws {
        let (browser, syncing) = launch()
        browser.close(browser.newTab(url: a, private: true))
        let pinned = try #require(browser.active)
        pinned.restore(url: b, title: "B")
        browser.pin(pinned)
        browser.close(pinned)
        #expect(browser.recentlyClosed.isEmpty)
        withExtendedLifetime(syncing) {}
    }

    @Test func theAddressFieldOffersTheOtherDevicesPagesNotOpenHere() throws {
        let (browser, syncing) = launch()
        browser.active?.restore(url: a, title: "Alpha docs")
        syncing.showOtherTabs([mac([DeviceTabs.Page(url: a.absoluteString, title: "Alpha docs"),
                                    DeviceTabs.Page(url: "https://alpha.example/", title: "Alpha news")])])
        let rows = Suggestions.offers(for: "alpha", in: browser)
        let theirs = rows.filter { $0.kind == .elsewhere }
        #expect(theirs.map(\.url.absoluteString) == ["https://alpha.example/"], "not one open here already")
        #expect(theirs.first?.elsewhere?.deviceName == "Mac")
    }
}
