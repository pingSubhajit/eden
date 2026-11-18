import Foundation
import XCTest
@testable import EdenCore

/// iCloud sync (CloudSync) between devices sharing one server, played by a
/// server in memory: what one device changes reaches the others, a deletion
/// travels, a device that doesn't understand an item carries it, and the
/// merge picks the same winner everywhere.
@MainActor
final class CloudSyncTests: XCTestCase {
    /// A CloudKit stand-in: every save a new revision, changes since a token
    /// the items saved after it.
    @MainActor
    final class Server: CloudStore {
        var records: [String: (entry: SyncEntry, revision: Int)] = [:]
        var revision = 0
        var problem: CloudProblem?
        var forgetsTokens = false
        var saves = 0

        var account = "someone"
        var failsSaves = false
        /// Run as a save reaches the server: the app changing meanwhile.
        var duringSave: (() -> Void)?

        func prepare() async throws -> String {
            if let problem { throw problem }
            return account
        }

        func changes(since token: Data?) async throws -> CloudChanges {
            let from = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
            let reset = from == nil || forgetsTokens
            let after = reset ? 0 : from ?? 0
            let found = records.filter { $0.value.revision > after }.mapValues(\.entry)
            return CloudChanges(entries: found, token: Data(String(revision).utf8), reset: reset)
        }

        func save(_ entries: [String: SyncEntry]) async throws {
            if failsSaves {
                if savesBeforeFailing > 0 { savesBeforeFailing -= 1 } else { throw CloudProblem.unavailable("offline") }
            }
            duringSave?()
            duringSave = nil
            saves += 1
            for (key, entry) in entries {
                revision += 1
                records[key] = (entry, revision)
            }
        }

        /// Saves that succeed before saving fails, when it does.
        var savesBeforeFailing = 0
    }

    /// A device: its items, what it applied last, and its sync.
    @MainActor
    final class Device {
        var items: [String: String]
        var applied: [String: String] = [:]
        let understood: (String) -> Bool
        let sync: CloudSync

        init(_ name: String, server: Server, items: [String: String] = [:], folder: URL,
             understood: @escaping (String) -> Bool = { _ in true }) {
            self.items = items
            self.understood = understood
            sync = CloudSync(store: server, device: name, file: folder.appendingPathComponent("\(name).json"))
        }

        var scope: CloudScope {
            CloudScope(name: "app", current: { [unowned self] _ in items }, apply: { [unowned self] live in
                applied = live
                // As the apps do: take what is agreed, of what this device keeps.
                items = live.filter { understood($0.key) }
            }, understood: { [unowned self] key, _ in understood(key) })
        }

        func pass(at now: TimeInterval) async {
            await sync.pass([scope], now: Date(timeIntervalSince1970: now))
        }
    }

    private var folder: URL!

    /// The history test's world, named as the history suites name theirs so
    /// whichever runs last clears it (Store.world is fixed for the process).
    override class func setUp() {
        setenv("EDEN_PROBE", "history-cloud-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("history-") {
            try? FileManager.default.removeItem(at: Store.folder)
            if let suite = Store.settingsSuite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        }
        super.tearDown()
    }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        Disk.drain()
        try? FileManager.default.removeItem(at: folder)
    }

    func testWhatOneDeviceHasReachesTheOther() async {
        let server = Server()
        let mac = Device("mac", server: server, items: ["bm:1": "Article"], folder: folder)
        let phone = Device("phone", server: server, folder: folder)
        await mac.pass(at: 1000)
        XCTAssertEqual(server.records["app/bm:1"]?.entry.v, "Article")
        await phone.pass(at: 1001)
        XCTAssertEqual(phone.items, ["bm:1": "Article"])
        XCTAssertEqual(mac.sync.status, .synced(Date(timeIntervalSince1970: 1000)))
    }

    func testAChangeAndADeletionTravel() async {
        let server = Server()
        let mac = Device("mac", server: server, items: ["bm:1": "One", "bm:2": "Two"], folder: folder)
        let phone = Device("phone", server: server, folder: folder)
        await mac.pass(at: 1000)
        await phone.pass(at: 1001)
        phone.items["bm:1"] = "One, renamed"
        phone.items["bm:2"] = nil
        await phone.pass(at: 1002)
        await mac.pass(at: 1003)
        XCTAssertEqual(mac.items, ["bm:1": "One, renamed"])
        XCTAssertNil(server.records["app/bm:2"]?.entry.v, "a tombstone on the server")
    }

    func testADeviceCarriesWhatItDoesntUnderstand() async {
        let server = Server()
        let mac = Device("mac", server: server, items: ["pin:a": "Mail", "bm:1": "Article"], folder: folder)
        // An iPhone with no pins of its own yet.
        let phone = Device("phone", server: server, folder: folder) { !$0.hasPrefix("pin:") }
        await mac.pass(at: 1000)
        await phone.pass(at: 1001)
        XCTAssertEqual(phone.items, ["bm:1": "Article"], "the phone keeps only what it knows")
        await phone.pass(at: 1002)
        XCTAssertEqual(server.records["app/pin:a"]?.entry.v, "Mail", "and never deletes the rest")
        await mac.pass(at: 1003)
        XCTAssertEqual(mac.items["pin:a"], "Mail")
    }

    func testANewcomerJoinsAndTheServerWinsWhereBothHaveOne() async {
        let server = Server()
        let mac = Device("mac", server: server, items: ["set:search.engine": "\"kagi\""], folder: folder)
        await mac.pass(at: 1000)
        let phone = Device("phone", server: server, items: ["set:search.engine": "\"google\"", "bm:9": "Mine"],
                           folder: folder)
        await phone.pass(at: 5000)
        XCTAssertEqual(phone.items["set:search.engine"], "\"kagi\"", "the devices already syncing win")
        XCTAssertEqual(phone.items["bm:9"], "Mine", "and nothing only the newcomer had is lost")
        await mac.pass(at: 5001)
        XCTAssertEqual(mac.items["bm:9"], "Mine")
    }

    func testTheSameEditOnTwoDevicesEndsTheSameEverywhere() async {
        let server = Server()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        let phone = Device("phone", server: server, folder: folder)
        await mac.pass(at: 1000)
        await phone.pass(at: 1001)
        mac.items["bm:1"] = "From the Mac"
        phone.items["bm:1"] = "From the phone"
        await mac.pass(at: 2000)
        await phone.pass(at: 2001)
        await mac.pass(at: 2002)
        await phone.pass(at: 2003)
        XCTAssertEqual(mac.items["bm:1"], phone.items["bm:1"])
        XCTAssertEqual(mac.items["bm:1"], "From the phone", "the later edit wins")
    }

    func testAnOldDeletionIsForgottenByTheDevicesButNeverTakenOffTheServer() async {
        let server = Server()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        await mac.pass(at: 1000)
        mac.items = [:]
        await mac.pass(at: 1001)
        let later = 1001 + SyncMerge.tombstoneLife + 10
        await mac.pass(at: later)
        XCTAssertNil(server.records["app/bm:1"]?.entry.v, "still a tombstone: taking it off could take off a restore")
        let phone = Device("phone", server: server, items: ["bm:1": "Brought back"], folder: folder)
        await phone.pass(at: later + 1)
        await mac.pass(at: later + 2)
        XCTAssertEqual(mac.items["bm:1"], "Brought back")
    }

    func testAProblemIsSaidAndNothingChanges() async {
        let server = Server()
        server.problem = .noAccount
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        await mac.pass(at: 1000)
        XCTAssertEqual(mac.sync.status, .problem(.noAccount))
        XCTAssertTrue(server.records.isEmpty)
        XCTAssertEqual(CloudProblem.noAccount.sentence, "Sign in to iCloud to sync")
    }

    func testAForgottenTokenFetchesEverythingAgain() async {
        let server = Server()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        let phone = Device("phone", server: server, folder: folder)
        await mac.pass(at: 1000)
        await phone.pass(at: 1001)
        server.forgetsTokens = true
        await phone.pass(at: 1002)
        XCTAssertEqual(phone.items, ["bm:1": "A"])
    }

    func testNothingIsSavedWhenNothingChanged() async {
        let server = Server()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        await mac.pass(at: 1000)
        let saves = server.saves
        await mac.pass(at: 1001)
        await mac.pass(at: 1002)
        XCTAssertEqual(server.saves, saves)
    }

    func testAFailedSaveChangesNothingHereAndARestoreElsewhereSurvives() async {
        let server = Server()
        let mac = Device("mac", server: server, items: ["bm:1": "Article"], folder: folder)
        let phone = Device("phone", server: server, folder: folder)
        await mac.pass(at: 1000)
        await phone.pass(at: 1001)
        phone.items["bm:1"] = nil
        await phone.pass(at: 1002)

        // The Mac hears of the deletion, but can't save its own new bookmark.
        mac.items["bm:2"] = "New"
        server.failsSaves = true
        await mac.pass(at: 1003)
        XCTAssertEqual(mac.sync.status, .problem(.unavailable("offline")))
        XCTAssertEqual(mac.items["bm:1"], "Article", "nothing applied while the server said no")

        // Then the phone brings it back.
        server.failsSaves = false
        phone.items["bm:1"] = "Article, again"
        await phone.pass(at: 1004)
        await mac.pass(at: 1005)
        XCTAssertEqual(mac.items["bm:1"], "Article, again", "the restore is not deleted by the retry")
        XCTAssertEqual(server.records["app/bm:1"]?.entry.v, "Article, again")
        XCTAssertEqual(server.records["app/bm:2"]?.entry.v, "New")
    }

    func testAChangeMadeWhileSavingIsKeptAndSyncedInTheSamePass() async {
        let server = Server()
        let mac = Device("mac", server: server, items: ["bm:1": "One"], folder: folder)
        server.duringSave = { mac.items["bm:2"] = "Two, added while saving" }
        await mac.pass(at: 1000)
        XCTAssertEqual(mac.items["bm:2"], "Two, added while saving", "not undone by the pass")
        XCTAssertEqual(server.records["app/bm:2"]?.entry.v, "Two, added while saving")
    }

    func testAnEditOrADeletionDuringTheFirstSaveWins() async {
        for edit in ["After", nil] as [String?] {
            let server = Server()
            let mac = Device("mac", server: server, items: ["bm:1": "Before"], folder: folder)
            server.duringSave = { mac.items["bm:1"] = edit }
            await mac.pass(at: 1000)
            XCTAssertEqual(mac.items["bm:1"], edit, "not undone by the pass")
            XCTAssertEqual(server.records["app/bm:1"]?.entry.v, edit, "and on the server by the pass that follows")
            mac.sync.forget()
        }
    }

    func testARemoteChangeArrivesThoughTheAppChangedDuringTheSave() async {
        let server = Server()
        let phone = Device("phone", server: server, items: ["bm:1": "From the phone", "bm:2": "Gone soon"], folder: folder)
        await phone.pass(at: 1000)
        let mac = Device("mac", server: server, items: ["bm:3": "Mac's"], folder: folder)
        await mac.pass(at: 1001)
        phone.items["bm:1"] = "Renamed on the phone"
        phone.items["bm:2"] = nil
        await phone.pass(at: 1002)
        mac.items["bm:4"] = "Another"
        server.duringSave = { mac.items["bm:3"] = "Mac's, renamed while saving" }
        await mac.pass(at: 1003)
        XCTAssertEqual(mac.items, ["bm:1": "Renamed on the phone", "bm:3": "Mac's, renamed while saving", "bm:4": "Another"])
    }

    func testTurnedOffDuringASaveTheServerIsLeftAlone() async {
        let server = Server()
        var many: [String: String] = [:]
        for index in 0..<(CloudSync.batch + 1) { many["bm:\(index)"] = "Site \(index)" }
        let mac = Device("mac", server: server, items: many, folder: folder)
        server.duringSave = { mac.sync.forget() }
        await mac.pass(at: 1000)
        XCTAssertEqual(server.saves, 1, "no batch after the one under way")
        XCTAssertEqual(mac.sync.status, .idle)
    }

    func testAPassAskedForAfterTurningOffDoesNothing() async {
        let server = Server()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        mac.sync.forget()
        await mac.pass(at: 1000)
        XCTAssertTrue(server.records.isEmpty)
        XCTAssertEqual(mac.sync.status, .idle)
    }

    func testAnEditAfterASaveThatFailedPartWayWins() async {
        let server = Server()
        var many: [String: String] = [:]
        for index in 0..<(CloudSync.batch + 1) { many["bm:\(index)"] = "Before" }
        let mac = Device("mac", server: server, items: many, folder: folder)
        server.failsSaves = true
        server.savesBeforeFailing = 1
        await mac.pass(at: 1000)
        XCTAssertEqual(mac.sync.status, .problem(.unavailable("offline")))
        server.failsSaves = false
        for key in many.keys { mac.items[key] = "After" }
        await mac.pass(at: 1001)
        XCTAssertEqual(Set(mac.items.values), ["After"])
        XCTAssertEqual(Set(server.records.values.map(\.entry.v)), ["After"])
    }

    func testAnotherAppleAccountStartsAfreshAndGetsNothingOfTheFirst() async {
        let first = Server()
        let phone = Device("phone", server: first, items: [SyncItems.tabsKey("phone"): "{}"], folder: folder)
        await phone.pass(at: 1000)
        let mac = Device("mac", server: first, items: ["bm:1": "Mine"], folder: folder) { !$0.hasPrefix("tabs:") }
        await mac.pass(at: 1001)
        Disk.drain()

        let second = Server()
        second.account = "someone else"
        let again = Device("mac", server: second, items: mac.items, folder: folder) { !$0.hasPrefix("tabs:") }
        await again.pass(at: 2000)
        XCTAssertNil(second.records["app/" + SyncItems.tabsKey("phone")], "the first account's phone stays there")
        XCTAssertEqual(second.records["app/bm:1"]?.entry.v, "Mine", "this Mac's own things join the new one")
    }

    // MARK: - open tabs

    func testOtherDevicesTabsNewestFirstAndRecentOnly() {
        let now = 100_000_000.0
        let mine = DeviceTabs(device: "phone", name: "iPhone", kind: .iphone,
                              tabs: [.init(url: "https://a.example/", title: "A")], at: now)
        let mac = DeviceTabs(device: "mac", name: "Mac", kind: .mac,
                             tabs: [.init(url: "https://b.example/", title: "B")], at: now - 60)
        let old = DeviceTabs(device: "old", name: "Old iPad", kind: .ipad,
                             tabs: [.init(url: "https://c.example/", title: "C")], at: now - 40 * 24 * 3600)
        let empty = DeviceTabs(device: "empty", name: "Other Mac", kind: .mac, tabs: [], at: now)
        var live: [String: String] = [:]
        for tabs in [mine, mac, old, empty] { live.merge(SyncItems.tabs(tabs)) { $1 } }
        XCTAssertEqual(SyncItems.otherTabs(live, except: "phone", now: now).map(\.device), ["mac"])
    }

    // MARK: - history

    func testHistoryRoundTripsAndForgetsWhatWasDeletedElsewhere() async throws {
        let here = History(file: "history-a-\(UUID().uuidString).json", read: { _ in nil })
        let there = History(file: "history-b-\(UUID().uuidString).json", read: { _ in nil })
        for _ in 0..<200 where !(here.isLoaded && there.isLoaded) { try await Task.sleep(nanoseconds: 5_000_000) }
        let page = try XCTUnwrap(URL(string: "https://example.com/article"))
        here.record(page, title: "Article")
        let items = here.syncItems()
        let key = History.syncKey(History.identity(for: page))
        XCTAssertNotNil(items[key], "the page, not its site's front door")
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(here.understands(key))

        there.applySynced(items)
        XCTAssertEqual(there.everything().map(\.url), [page])
        XCTAssertEqual(there.everything().first?.title, "Article")

        there.applySynced([:])
        XCTAssertTrue(there.everything().isEmpty, "deleted on the other device, forgotten here")
        here.flush()
        there.flush()
    }

    func testPlacesTakenInAreWrittenDown() async throws {
        let name = "history-taken-\(UUID().uuidString).json"
        let there = History(file: name, read: { _ in nil })
        for _ in 0..<200 where !there.isLoaded { try await Task.sleep(nanoseconds: 5_000_000) }
        let page = try XCTUnwrap(URL(string: "https://example.com/article"))
        let key = History.syncKey(History.identity(for: page))
        there.applySynced([key: try XCTUnwrap(SyncMerge.text(SyncedVisit(url: page.absoluteString, title: "Article",
                                                                          count: 2, last: 1000)))])
        there.flush()
        Disk.drain()
        let reopened = History(file: name)
        for _ in 0..<200 where !reopened.isLoaded { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(reopened.everything().map(\.url), [page])
    }

    func testOnlyAPlaceDeletedByHandIsDeletedEverywhere() async throws {
        let here = History(file: "history-hand-\(UUID().uuidString).json", read: { _ in nil })
        for _ in 0..<200 where !here.isLoaded { try await Task.sleep(nanoseconds: 5_000_000) }
        let page = try XCTUnwrap(URL(string: "https://example.com/kept"))
        let identity = History.identity(for: page)
        let elsewhere = History.syncKey(History.identity(for: try XCTUnwrap(URL(string: "https://other.example/page"))))
        XCTAssertFalse(here.understands(elsewhere), "a place never held here — left out for being full — is carried")
        here.record(page, title: "Kept")
        XCTAssertTrue(here.understands(History.syncKey(identity)))
        here.forget(identity)
        XCTAssertTrue(here.understands(History.syncKey(identity)), "deleted by hand: deleted everywhere")
        here.record(page, title: "Kept")
        here.flush()
    }
}
