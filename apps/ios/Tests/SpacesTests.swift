import EdenCore
import Foundation
import Testing
import WebKit
@testable import Eden

/// Spaces on iPhone and iPad (Spaces.swift): each space's tabs, kept in a
/// file of its own and back at launch with the one in front; whose a tab is,
/// whatever is in front when its page answers; a space deleted with
/// everything it had; and whose sign-ins each space's pages have.
@MainActor
struct SpacesTests {
    private let folder: URL
    private let defaults: UserDefaults
    private let a = URL(string: "https://a.example/")!
    private let b = URL(string: "https://b.example/")!
    private let c = URL(string: "https://c.example/")!

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("eden-spaces-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "eden-spaces-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
    }

    private var tabsFile: URL { folder.appendingPathComponent("tabs.json") }

    /// A browser as a launch makes one, over this test's folder and settings.
    private func launch(spaces: Bool = true, library: SpaceLibrary? = nil, pinsGoHome: Bool = true) -> Browser {
        let settings = Settings(store: defaults)
        settings.usesSpaces = spaces
        settings.pinsGoHome = pinsGoHome
        return Browser(history: History(file: "history-\(UUID().uuidString).json", read: { _ in nil }),
                       bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json")),
                       settings: settings, curtain: Curtain(file: folder.appendingPathComponent("hidden.json")),
                       library: library ?? SpaceLibrary(file: folder.appendingPathComponent("spaces.json"), store: defaults),
                       pins: PinStore(file: folder.appendingPathComponent("pins.json")),
                       stores: WebsiteStores(settings: defaults), sessionFile: tabsFile)
    }

    private func session(_ space: UUID) throws -> Browser.Session {
        let file = folder.appendingPathComponent(SpaceSessionFile.name(for: space, stem: "tabs"))
        return try JSONDecoder().decode(Browser.Session.self, from: Data(contentsOf: file))
    }

    @Test func tabsFromBeforeSpacesComeBackAsPersonalsWithTheOneInFront() throws {
        let old = #"{"tabs":[{"url":"https://a.example/","title":"A"},{"url":"","title":"?"},{"url":"https://b.example/","title":"B"}],"active":2}"#
        try Data(old.utf8).write(to: tabsFile)
        let browser = launch(spaces: false)
        #expect(browser.spaceID == Space.firstID)
        #expect(browser.spaceTabs.map(\.url) == [a, b])
        #expect(browser.active?.url == b, "the one in front by its place in the file")
    }

    @Test func eachSpaceKeepsItsTabsAndTheOneInFront() throws {
        let browser = launch()
        browser.go(a.absoluteString, in: browser.active)
        browser.newTab(url: b)
        let personalFront = try #require(browser.active)
        let work = browser.addSpace(named: "Work", sharesSignIns: true)
        #expect(browser.spaceID == work.id)
        #expect(browser.spaceTabs.count == 1, "a new space starts with an empty tab")
        browser.go(c.absoluteString, in: browser.active)
        browser.newTab(private: true)

        browser.enter(Space.firstID)
        #expect(browser.active === personalFront, "back to the tab left in front")
        browser.enter(work.id)
        #expect(browser.active?.url == c, "a private tab is no space's")
        #expect(browser.privateTabs.count == 1)

        Disk.drain()
        #expect(try session(Space.firstID).tabs.map(\.url) == [a.absoluteString, b.absoluteString])
        #expect(try session(Space.firstID).active == 1)
        #expect(try session(work.id).tabs.map(\.url) == [c.absoluteString])

        // And at the next launch, in the space that was in front.
        let again = launch()
        #expect(again.spaceID == work.id)
        #expect(again.active?.url == c)
        #expect(again.privateTabs.isEmpty)
        again.enter(Space.firstID)
        #expect(again.active?.url == b)
    }

    @Test func spacesOffShowPersonalAndKeepTheRest() throws {
        let browser = launch()
        let work = browser.addSpace(named: "Work", sharesSignIns: true)
        browser.go(c.absoluteString, in: browser.active)
        browser.settings.usesSpaces = false
        browser.leaveSpaces()
        #expect(browser.spaceID == Space.firstID)
        browser.enter(work.id)
        #expect(browser.spaceID == Space.firstID, "no other space while they are off")
        #expect(browser.ordinaryTabs.contains { $0.url == c }, "kept for when they come back")
    }

    @Test func aPageAnsweringInASpaceOutOfSightIsWrittenInItsOwn() throws {
        let browser = launch()
        let work = browser.addSpace(named: "Work", sharesSignIns: true)
        let worker = try #require(browser.active)
        browser.enter(Space.firstID)
        // The page arrives somewhere while Personal is in front.
        worker.restore(url: c, title: "C")
        browser.tabChanged(worker)
        Disk.drain()
        #expect(try session(work.id).tabs.map(\.url) == [c.absoluteString])
        #expect(try session(Space.firstID).tabs.isEmpty)
    }

    @Test func aPopUpFromASpaceOutOfSightWaitsThere() throws {
        let browser = launch()
        let work = browser.addSpace(named: "Work", sharesSignIns: true)
        let opener = try #require(browser.active)
        browser.enter(Space.firstID)
        let personal = browser.active
        let popUp = try #require(browser.adopt(configuration: Tab.configuration(private: false),
                                               request: URLRequest(url: c), from: opener))
        #expect(popUp.owner == .space(work.id))
        #expect(browser.active === personal, "nothing changes under you")
        browser.enter(work.id)
        #expect(browser.active === popUp, "there on going back")
    }

    @Test func aDeletedSpaceTakesItsTabsFileAndStoreWithIt() throws {
        let browser = launch()
        let work = browser.addSpace(named: "Work", sharesSignIns: false)
        browser.go(c.absoluteString, in: browser.active)
        Disk.drain()
        let file = folder.appendingPathComponent(SpaceSessionFile.name(for: work.id, stem: "tabs"))
        #expect(FileManager.default.fileExists(atPath: file.path))

        browser.deleteSpace(work.id)
        Disk.drain()
        #expect(browser.spaceID == Space.firstID)
        #expect(!browser.tabs.contains { $0.owner == .space(work.id) })
        #expect(!browser.tabs.contains { $0.url == c }, "never reopened in Personal")
        #expect(!browser.spaces.contains { $0.id == work.id })
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Its store is written down to be removed, and still is at the next
        // launch until WebKit lets it go.
        let identifier = WebsiteStores(settings: defaults).identifier(for: work.id)
        #expect((defaults.stringArray(forKey: WebsiteStores.erasingKey) ?? []).contains(identifier.uuidString))
        // Personal can't be deleted.
        browser.deleteSpace(Space.firstID)
        #expect(browser.spaces.contains { $0.id == Space.firstID })
    }

    @Test func eachSpaceHasTheSignInsItWasMadeWith() throws {
        let browser = launch()
        let shared = browser.addSpace(named: "Shared", sharesSignIns: true)
        let own = browser.addSpace(named: "Own", sharesSignIns: false)
        #expect(browser.store(for: .space(Space.firstID)) === Tab.ordinaryStore)
        #expect(browser.store(for: .space(shared.id)) === Tab.ordinaryStore)
        let isolated = browser.store(for: .space(own.id))
        #expect(isolated !== Tab.ordinaryStore)
        #expect(browser.store(for: .space(own.id)) === isolated, "one store per space, made once")
        #expect(!browser.store(for: .private).isPersistent)
        // A test run's spaces never get a real space's store.
        #expect(isolated.identifier != own.id)
        #expect(isolated.identifier == WebsiteStores(settings: defaults).identifier(for: own.id))
        // Changing a space never changes whose sign-ins it has.
        browser.library.edit(own.id) { $0.sharesSignIns = true; $0.name = "Renamed" }
        #expect(browser.library.space(own.id)?.sharesSignIns == false)
        #expect(browser.library.space(own.id)?.name == "Renamed")
    }

    @Test func theSpacesListIsTheMacsFile() throws {
        let theirs = Space(id: UUID(), name: "Accounts", colour: 0, profile: UUID())
        let work = Space(id: UUID(), name: "Work", colour: 2, icon: "terminal", sharesSignIns: false)
        try SpacesFile.encode([work, Space.first(), theirs]).write(to: folder.appendingPathComponent("spaces.json"))
        let library = SpaceLibrary(file: folder.appendingPathComponent("spaces.json"), store: defaults)
        #expect(library.spaces.map(\.id) == [work.id, Space.firstID], "moved on the Mac, Personal's alone")
        library.move(work.id, to: 1)
        Disk.drain()
        let written = try SpacesFile.decode(Data(contentsOf: folder.appendingPathComponent("spaces.json")))
        #expect(written.map(\.id) == [theirs.id, Space.firstID, work.id], "another profile's kept")
    }

    // MARK: - pins

    /// A browser with one tab, on `url`.
    private func opened(_ url: URL, spaces: Bool = true, pinsGoHome: Bool = true) throws -> (Browser, Tab) {
        let browser = launch(spaces: spaces, pinsGoHome: pinsGoHome)
        let tab = try #require(browser.active)
        tab.restore(url: url, title: "Page")
        return (browser, tab)
    }

    @Test func pinningKeepsTheTabAndUnpinningKeepsThePage() throws {
        let (browser, tab) = try opened(a)
        browser.pin(tab)
        let pin = try #require(browser.shownPins.first)
        #expect(pin.tab === tab, "the same tab, its page and history with it")
        #expect(pin.def.home == a.absoluteString)
        #expect(pin.def.letter == "A")
        #expect(browser.looseTabs.isEmpty)
        browser.unpin(tab)
        #expect(browser.shownPins.isEmpty)
        #expect(browser.looseTabs.first === tab)
        #expect(browser.active === tab)
        #expect(browser.pins.catalog == PinCatalog())
    }

    @Test func closingAPinRestsItAtHomeOrWhereItWas() throws {
        for goesHome in [true, false] {
            let (browser, tab) = try opened(a, pinsGoHome: goesHome)
            browser.pin(tab)
            tab.restore(url: b, title: "Elsewhere")
            let other = browser.newTab(url: c)
            browser.select(tab)
            browser.close(tab)
            let pin = try #require(browser.shownPins.first)
            #expect(pin.tab !== tab, "its page let go")
            #expect(pin.tab.url == (goesHome ? a : b))
            #expect(browser.active === other, "the tab beside it in front")
        }
    }

    @Test func aPinComesBackAtHomeOrWhereItWasLeft() throws {
        for goesHome in [true, false] {
            let (browser, tab) = try opened(a)
            browser.pin(tab)
            tab.restore(url: b, title: "Elsewhere")
            browser.tabChanged(tab)
            Disk.drain()
            let again = launch(pinsGoHome: goesHome)
            #expect(again.shownPins.count == 1)
            #expect(again.shownPins.first?.tab.url == (goesHome ? a : b))
            try? FileManager.default.removeItem(at: tabsFile)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("pins.json"))
        }
    }

    @Test func aSharedPinIsEachSpacesOwnTab() throws {
        let (browser, tab) = try opened(a)
        browser.pin(tab)
        let work = browser.addSpace(named: "Work", sharesSignIns: false)
        #expect(browser.shownPins.isEmpty, "Personal's own, not Work's")
        browser.enter(Space.firstID)
        browser.showEverywhere(tab)
        browser.enter(work.id)
        let theirs = try #require(browser.shownPins.first)
        #expect(theirs.tab !== tab, "Work's own tab for it, with Work's sign-ins")
        #expect(theirs.tab.owner == .space(work.id))
        #expect(theirs.shared)
        // Kept by Personal alone: Work's tab for it, only resting, goes.
        browser.enter(Space.firstID)
        browser.keepHere(tab)
        browser.enter(work.id)
        #expect(browser.shownPins.isEmpty)
        #expect(!browser.tabs.contains { $0.owner == .space(work.id) && $0.pin != nil })
    }

    @Test func sharedPinsWaitWhileSpacesAreOff() throws {
        let (browser, tab) = try opened(a)
        browser.pin(tab)
        browser.showEverywhere(tab)
        browser.settings.usesSpaces = false
        browser.pinsChanged()
        #expect(browser.shownPins.isEmpty, "hidden, as on the Mac")
        #expect(browser.tabs.contains { $0.pin == tab.pin }, "kept for when they come back")
        #expect(browser.pins.isShared(try #require(tab.pin)))
    }

    @Test func closeAllKeepsThePinsAndOpenAsNewTabFreesAPage() throws {
        let (browser, tab) = try opened(a)
        browser.pin(tab)
        browser.newTab(url: b)
        browser.closeAll(private: false)
        #expect(browser.shownPins.count == 1)
        // At home: its page in a new tab.
        browser.openAsNewTab(tab)
        #expect(browser.looseTabs.last?.url == a)
        // Taken elsewhere: that page to an ordinary tab, the pin fresh at home.
        tab.restore(url: c, title: "C")
        browser.openAsNewTab(tab)
        #expect(tab.pin == nil)
        #expect(browser.looseTabs.contains { $0 === tab })
        #expect(browser.shownPins.first?.tab.url == a)
        #expect(browser.shownPins.first?.tab !== tab)
    }

    @Test func aDeletedSpacesPinsGoAndTheSharedOnesStay() throws {
        let browser = launch()
        let work = browser.addSpace(named: "Work", sharesSignIns: true)
        let tab = try #require(browser.active)
        tab.restore(url: a, title: "A")
        browser.pin(tab)
        let other = browser.newTab(url: b)
        browser.pin(other)
        browser.showEverywhere(other)
        browser.deleteSpace(work.id)
        #expect(browser.pins.catalog.bySpace[work.id] == nil)
        #expect(browser.pins.shared.map(\.home) == [b.absoluteString])
        #expect(browser.shownPins.map(\.def.home) == [b.absoluteString], "Personal has its own tab for it")
    }

    // MARK: - after the first review

    @Test func aRestedPinStaysTheBrowsersTab() throws {
        let (browser, tab) = try opened(a)
        browser.pin(tab)
        browser.newTab(url: b)
        browser.close(tab)
        let resting = try #require(browser.shownPins.first?.tab)
        #expect(resting.browser === browser, "it can open pop-ups and say where it went")
        #expect(tab.browser == nil, "the one closed says nothing more")
    }

    @Test func aSavedPageOutlivesItsPinTakenAwayElsewhere() throws {
        let (browser, tab) = try opened(a, pinsGoHome: false)
        browser.pin(tab)
        tab.restore(url: b, title: "Elsewhere")
        browser.tabChanged(tab)
        Disk.drain()
        let again = launch(pinsGoHome: false)
        let restored = try #require(again.shownPins.first?.tab)
        #expect(!restored.isBuilt)
        again.newTab()
        // Unpinned on another device before it was ever shown here.
        again.pins.remove(try #require(restored.pin))
        again.pinsChanged()
        #expect(again.looseTabs.contains { $0 === restored && $0.url == b }, "the page it was on, kept")
    }

    @Test func aPinRestingAtHomeGoesWithItsPin() throws {
        let (browser, tab) = try opened(a)
        browser.pin(tab)
        let work = browser.addSpace(named: "Work", sharesSignIns: true)
        browser.enter(Space.firstID)
        browser.showEverywhere(tab)
        let theirs = try #require(browser.shownPins(in: work.id).first?.tab)
        browser.keepHere(tab)
        #expect(!browser.tabs.contains { $0 === theirs }, "nothing of yours was in it")
    }

    @Test func aNewSpaceHasThePinsEverySpaceShowsBesideAnEmptyTab() throws {
        let (browser, tab) = try opened(a)
        browser.pin(tab)
        browser.showEverywhere(tab)
        let work = browser.addSpace(named: "Work", sharesSignIns: true)
        #expect(browser.shownPins.map(\.def.id) == [try #require(tab.pin)])
        #expect(browser.shownPins.first?.tab.owner == .space(work.id))
        #expect(browser.active?.pin == nil)
        #expect(browser.active?.url == nil)
    }

    @Test func aDeletedSpacesTabsCanAskForNothing() throws {
        let browser = launch()
        let work = browser.addSpace(named: "Work", sharesSignIns: false)
        let stale = try #require(browser.active)
        browser.deleteSpace(work.id)
        let made = browser.newTab(url: c, after: stale)
        #expect(made.owner == .space(Space.firstID), "in the space in front, never the one gone")
        #expect(browser.adopt(configuration: Tab.configuration(private: false), request: URLRequest(url: c), from: stale) == nil)
        #expect(!browser.store(for: .space(work.id)).isPersistent, "never Personal's sign-ins")
    }

    @Test func aDeletionCutShortIsFinishedAtTheNextLaunch() throws {
        let browser = launch()
        let work = browser.addSpace(named: "Work", sharesSignIns: true)
        browser.go(c.absoluteString, in: browser.active)
        Disk.drain()
        // The app stopped right after writing down the deletion.
        browser.settings.deletingSpaces.insert(work.id)
        let again = launch()
        Disk.drain()
        #expect(!again.spaces.contains { $0.id == work.id })
        #expect(!again.tabs.contains { $0.url == c }, "its tabs never came back")
        #expect(again.settings.deletingSpaces.isEmpty)
        let file = folder.appendingPathComponent(SpaceSessionFile.name(for: work.id, stem: "tabs"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // It was in front: Personal is now, and what is opened there is kept.
        #expect(again.spaceID == Space.firstID)
        #expect(again.settings.currentSpace == Space.firstID)
        #expect(again.active?.owner == .space(Space.firstID))
        again.go(a.absoluteString, in: again.active)
        Disk.drain()
        #expect(try session(Space.firstID).tabs.map(\.url).contains(a.absoluteString))
    }

    @Test func aDeletionWhoseFilesDidntLandIsTriedAgain() throws {
        let browser = launch()
        let work = browser.addSpace(named: "Work", sharesSignIns: true)
        Disk.drain()
        // pins.json can't be written: a folder with something in it is there.
        let pinsFile = folder.appendingPathComponent("pins.json")
        try FileManager.default.createDirectory(at: pinsFile, withIntermediateDirectories: true)
        try Data().write(to: pinsFile.appendingPathComponent("in-the-way"))
        browser.deleteSpace(work.id)
        #expect(browser.settings.deletingSpaces.contains(work.id), "kept until it is all on disk")
        try FileManager.default.removeItem(at: pinsFile)
        let again = launch()
        #expect(again.settings.deletingSpaces.isEmpty)
        #expect(!again.spaces.contains { $0.id == work.id })
        #expect(FileManager.default.fileExists(atPath: pinsFile.path))
    }

    @Test func everyEditHereTellsSyncAndNothingFromElsewhereDoes() throws {
        let (browser, tab) = try opened(a)
        var told = 0
        browser.library.changed = { told += 1 }
        browser.pins.changed = { told += 1 }
        browser.pin(tab)
        #expect(told == 1)
        browser.editPin(tab) { $0.name = "Mail" }
        tab.restore(url: b, title: "B")
        browser.setHome(tab)
        browser.movePins([try #require(tab.pin)])
        let work = browser.addSpace(named: "Work", sharesSignIns: true)
        browser.library.edit(work.id) { $0.name = "Office" }
        browser.library.move(work.id, to: 0)
        #expect(told == 6, "pin, rename, home, space, its name, its place (the order was already so)")
        browser.library.adopt([Space.first()])
        browser.pins.adopt([:], in: [Space.firstID], shared: [])
        #expect(told == 6, "what came from another device isn't sent back")
    }
}
