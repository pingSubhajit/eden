import EdenCore
import Foundation
import Testing
@testable import Eden

/// An iPhone that synced before it kept spaces and pins, taking them over
/// (Syncing's SyncOwnership): through the real engine and its replica on
/// disk, against iCloud in memory. The release gate: nothing the Mac has is
/// edited or deleted by the upgrade, and the iPhone ends up holding it.
@MainActor
struct SyncOwnershipTests {
    private let folder: URL
    private let defaults: UserDefaults
    private let server = SimulatedServer()

    private let home = Space(id: Space.firstID, name: "Home", colour: 1, icon: "house")
    private let work = Space(id: UUID(), name: "Work", colour: 2, icon: "terminal", sharesSignIns: false)
    private let mail = PinDef(id: UUID(), letter: "M", home: "https://mail.example/", title: "Mail", listed: true)
    private let docs = PinDef(id: UUID(), letter: "D", home: "https://docs.example/", title: "Docs")
    private let notes = PinDef(id: UUID(), letter: "N", home: "https://notes.example/", title: "Notes")

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("eden-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "eden-ownership-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
    }

    /// A scope that holds what it is given, of what it keeps: the Mac, or an
    /// iPhone from before spaces.
    private final class Held: SyncScope {
        let name: String
        var items: [String: String]
        let keeps: (String) -> Bool
        var isReady: Bool { true }

        init(_ name: String, _ items: [String: String] = [:], keeps: @escaping (String) -> Bool = { _ in true }) {
            self.name = name
            self.items = items
            self.keeps = keeps
        }

        func snapshot(agreed: [String: String]) -> [String: String] { items }
        func owns(_ key: String, _ text: String) -> Bool { keeps(key) }
        func apply(_ live: [String: String]) { items = live.filter { keeps($0.key) } }
        func persist() {}
    }

    /// One device's sync pass, with its replica in `file`.
    @discardableResult
    private func sync(_ scopes: [SyncScope], as device: String, replica file: String) async -> CloudSync {
        let cloud = CloudSync(transport: SimulatedTransport(server: server), device: device,
                              store: SQLiteReplicaStore(url: folder.appendingPathComponent(file)))
        cloud.scopes = scopes
        await cloud.start()
        await cloud.refresh()
        return cloud
    }

    private var macPersonal: [String: String] {
        var items = SyncItems.spaces([work, home])
        items.merge(SyncItems.pins(bySpace: [home.id: [mail], work.id: [docs]], shared: [notes], base: [:])) { a, _ in a }
        items.merge(SyncItems.bookmarks([Bookmark.site("Example", URL(string: "https://example.com/")!)])) { a, _ in a }
        return items
    }

    private let macApp = ["set:spaces": "true", "set:pins.list": "true", "set:pins.home": "false",
                          "set:search.engine": "\"kagi\"", "set:look": "\"dark\""]

    /// The Mac's items on the server, and an iPhone from before spaces that
    /// synced them: its own settings and bookmarks kept, as that build kept
    /// them, the rest carried; its replica left on disk.
    private func upgradeFrom() async {
        let mac = await sync([Held("app", macApp), Held(Syncing.personal, macPersonal)], as: "mac", replica: "mac.sqlite")
        _ = mac.stop(forgetting: false)
        let oldSettings: Set<String> = ["set:search.engine", "set:search.custom", "set:shield"]
        let mine = Settings(store: defaults).syncItems.filter { oldSettings.contains($0.key) }
        let oldApp = Held("app", mine, keeps: { oldSettings.contains($0) })
        let oldPersonal = Held(Syncing.personal, keeps: { $0.hasPrefix("bm:") || $0.hasPrefix("kids:") })
        let old = await sync([oldApp, oldPersonal], as: "iphone", replica: "iphone.sqlite")
        _ = old.stop(forgetting: false)
        // What it applied, in its files.
        Settings(store: defaults).applySynced(oldApp.items)
        BookmarkStore(file: folder.appendingPathComponent("bookmarks.json")).adopt(SyncItems.applyBookmarks(oldPersonal.items))
        Disk.drain()
    }

    /// This build's browser over the iPhone's folder, as the old one left it.
    private func browser(pins file: String = "pins.json") -> Browser {
        let settings = Settings(store: defaults)
        return Browser(history: History(file: "history-\(UUID().uuidString).json", read: { _ in nil }),
                       bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json")),
                       settings: settings, curtain: Curtain(file: folder.appendingPathComponent("hidden.json")),
                       library: SpaceLibrary(file: folder.appendingPathComponent("spaces.json"), store: defaults),
                       pins: PinStore(file: folder.appendingPathComponent(file), store: defaults),
                       stores: WebsiteStores(settings: defaults),
                       sessionFile: folder.appendingPathComponent("tabs.json"))
    }

    /// This build syncing, as the app does once its history has read its
    /// file. The scopes hold their Syncing unowned, as the app's Syncing holds
    /// them through its engine: it is kept with them here.
    private func upgraded(_ browser: Browser) async -> (cloud: CloudSync, syncing: Syncing) {
        for _ in 0..<500 where !browser.history.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        let syncing = Syncing(browser: browser)
        let cloud = await sync([AppScope(syncing: syncing, browser: browser), PersonalScope(browser: browser)],
                               as: "iphone", replica: "iphone.sqlite")
        return (cloud, syncing)
    }

    /// What is on the server, its tabs items (written by each device for
    /// itself) left out.
    private var held: [String: SyncEntry] {
        server.records.filter { !$0.key.contains("/tabs:") }.mapValues(\.entry)
    }

    @Test func anUpgradeEditsAndDeletesNothingAndHoldsWhatTheMacHas() async throws {
        await upgradeFrom()
        let before = held
        let browser = browser()
        let (cloud, syncing) = await upgraded(browser)

        #expect(held == before, "nothing the Mac has edited, nothing deleted")
        #expect(!server.records.values.contains { $0.entry.v == nil })

        #expect(browser.library.spaces.map(\.id) == [work.id, Space.firstID], "the Mac's order, home moved")
        #expect(browser.library.space(Space.firstID)?.name == "Home")
        #expect(browser.library.space(work.id)?.sharesSignIns == false)
        #expect(browser.pins.catalog.pins(of: Space.firstID).map(\.id) == [mail.id])
        #expect(browser.pins.catalog.pins(of: work.id).map(\.id) == [docs.id])
        #expect(browser.pins.shared.map(\.id) == [notes.id])
        #expect(browser.settings.usesSpaces)
        #expect(browser.settings.listsPins)
        #expect(!browser.settings.pinsGoHome)
        #expect(browser.shownPins.map(\.def.id).contains(notes.id))

        // And a second pass is as quiet.
        await cloud.refresh()
        #expect(held == before)
        withExtendedLifetime(syncing) {}
    }

    @Test func whatWasMadeHereBeforeTheFirstSyncIsKeptAndSent() async throws {
        await upgradeFrom()
        let before = held
        let browser = browser()
        let travel = browser.library.add(named: "Travel", icon: nil, colour: 0, sharesSignIns: true)
        browser.settings.usesSpaces = false
        _ = await upgraded(browser)

        #expect(!server.records.values.contains { $0.entry.v == nil }, "nothing deleted")
        let personal = Syncing.personal + "/"
        for (key, entry) in before where key != personal + SyncItems.spacesOrder && key != "app/set:spaces" {
            #expect(held[key] == entry, "\(key) untouched")
        }
        #expect(server.value(personal + SyncItems.spaceKey(travel.id)) != nil, "the space made here, sent")
        let order = server.value(personal + SyncItems.spacesOrder).flatMap { SyncMerge.value([String].self, $0) }
        #expect(order == [work.id, Space.firstID, travel.id].map(\.uuidString))
        #expect(server.value("app/set:spaces") == "false", "chosen here, so this device's choice")
        #expect(browser.library.spaces.map(\.id) == [work.id, Space.firstID, travel.id])
    }

    @Test func aPinsFileThatWontReadIsTakenOverAgainNotTakenForNothing() async throws {
        await upgradeFrom()
        let first = browser()
        _ = await upgraded(first)
        let before = held
        Disk.drain()
        try Data("{not json".utf8).write(to: folder.appendingPathComponent("pins.json"))

        let again = browser()
        #expect(again.pins.damaged)
        _ = await upgraded(again)
        #expect(held == before, "no pin deleted everywhere")
        #expect(again.pins.catalog.pins(of: Space.firstID).map(\.id) == [mail.id], "back from what was agreed")
        #expect(!again.pins.damaged)
    }

    @Test func onceTakenOverAPinUnpinnedHereIsDeletedEverywhereAlone() async throws {
        await upgradeFrom()
        let browser = browser()
        let (cloud, syncing) = await upgraded(browser)
        defer { withExtendedLifetime(syncing) {} }
        let before = held
        let pin = try #require(browser.shownPins.first { $0.def.id == mail.id })
        browser.unpin(pin.tab)
        await cloud.refresh()
        let personal = Syncing.personal + "/"
        let gone = personal + SyncItems.pinKey(Space.firstID.uuidString, mail.id)
        #expect(server.value(gone) == nil)
        for (key, entry) in before where key != gone && !key.hasPrefix(personal + "order:pins") && !key.hasPrefix(personal + "title:pin") {
            #expect(held[key] == entry, "\(key) untouched")
        }
    }

    @Test func aTakeOverWhoseFileDidntLandIsDoneAgainUntilItDoes() async throws {
        await upgradeFrom()
        // pins.json can't be written: a folder with something in it is there.
        let pinsFile = folder.appendingPathComponent("pins.json")
        try FileManager.default.createDirectory(at: pinsFile, withIntermediateDirectories: true)
        try Data().write(to: pinsFile.appendingPathComponent("in-the-way"))
        let before = held
        let first = browser()
        _ = await upgraded(first)
        #expect(first.settings.ownership(of: Syncing.personal) == 0, "not taken over while its file isn't on disk")
        #expect(held == before, "and nothing said for it meanwhile")

        try FileManager.default.removeItem(at: pinsFile)
        _ = await upgraded(first)
        #expect(first.settings.ownership(of: Syncing.personal) == SyncOwnership.version)
        Disk.drain()
        let kept = try PinsFile.decode(Data(contentsOf: pinsFile))
        #expect(kept.pins(of: Space.firstID).map(\.id) == [mail.id], "written, though nothing changed since")
        let relaunched = browser()
        _ = await upgraded(relaunched)
        #expect(held == before)
    }

    @Test func aSpaceDeletedHereTakesItsPinsWithItEverywhere() async throws {
        await upgradeFrom()
        let browser = browser()
        let (cloud, syncing) = await upgraded(browser)
        defer { withExtendedLifetime(syncing) {} }
        browser.deleteSpace(work.id)
        await cloud.refresh()
        let personal = Syncing.personal + "/"
        #expect(server.value(personal + SyncItems.spaceKey(work.id)) == nil)
        #expect(server.value(personal + SyncItems.pinKey(work.id.uuidString, docs.id)) == nil, "its pin, deleted")
        #expect(server.value(personal + SyncItems.pinOrder(work.id.uuidString)) == nil, "and their order")
        #expect(server.value(personal + SyncItems.pinKey(Space.firstID.uuidString, mail.id)) != nil, "Personal's stay")
        #expect(server.value(personal + SyncItems.pinKey(SyncItems.sharedSpace, notes.id)) != nil, "and the shared ones")
    }
}
