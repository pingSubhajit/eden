import EdenCoreTesting
import Foundation
import XCTest
@testable import EdenCore

/// Sync through iCloud (CloudSync over a SimulatedServer standing in for
/// CKSyncEngine and CloudKit): what one device changes reaches the others, a
/// deletion travels, a device that doesn't understand an item carries it,
/// the merge picks the same winner everywhere, and nothing is lost when
/// saves fail, race edits, or sync is turned off part-way.
@MainActor
final class CloudSyncTests: XCTestCase {
    private var folder: URL!

    /// The history tests' world, named as the history suites name theirs so
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

    // MARK: - travelling

    func testWhatOneDeviceHasReachesTheOther() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "Article"], folder: folder)
        let phone = Device("phone", server: server, folder: folder)
        await mac.pass(at: 1000)
        XCTAssertEqual(server.value("app/bm:1"), "Article")
        await phone.pass(at: 1001)
        XCTAssertEqual(phone.items, ["bm:1": "Article"])
        XCTAssertEqual(mac.sync.status, .synced(Date(timeIntervalSince1970: 1000)))
    }

    func testAChangeAndADeletionTravel() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "One", "bm:2": "Two"], folder: folder)
        let phone = Device("phone", server: server, folder: folder)
        await mac.pass(at: 1000)
        await phone.pass(at: 1001)
        phone.items["bm:1"] = "One, renamed"
        phone.items["bm:2"] = nil
        await phone.pass(at: 1002)
        await mac.pass(at: 1003)
        XCTAssertEqual(mac.items, ["bm:1": "One, renamed"])
        XCTAssertNotNil(server.records["app/bm:2"], "a tombstone on the server")
        XCTAssertNil(server.value("app/bm:2"))
    }

    func testADeviceCarriesWhatItDoesntUnderstand() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["pin:a": "Mail", "bm:1": "Article"], folder: folder)
        // An iPhone with no pins of its own.
        let phone = Device("phone", server: server, folder: folder) { !$0.hasPrefix("pin:") }
        await mac.pass(at: 1000)
        await phone.pass(at: 1001)
        XCTAssertEqual(phone.items, ["bm:1": "Article"], "the phone keeps only what it knows")
        await phone.pass(at: 1002)
        XCTAssertEqual(server.value("app/pin:a"), "Mail", "and never deletes the rest")
        await mac.pass(at: 1003)
        XCTAssertEqual(mac.items["pin:a"], "Mail")
    }

    func testAnAskToCloseReachesItsDeviceAndIsGoneOnceActedOn() async {
        let server = SimulatedServer()
        let key = SyncItems.closeKey("phone", id: "1")
        // Each speaks for every item but the asks to close the other's pages.
        let mac = Device("mac", server: server, items: [key: "ask"], folder: folder) { !SyncItems.asksToClose($0, on: "phone") }
        let phone = Device("phone", server: server, folder: folder) { !SyncItems.asksToClose($0, on: "mac") }
        await mac.pass(at: 1000)
        // Written once, then only carried by the device that asked.
        mac.items[key] = nil
        await mac.pass(at: 1001)
        XCTAssertEqual(server.value("app/" + key), "ask", "the asker never deletes it")
        await phone.pass(at: 1002)
        XCTAssertEqual(phone.given[key], "ask", "the phone hears it")
        // Acted on, and never kept: gone everywhere at its next pass.
        phone.items[key] = nil
        await phone.pass(at: 1003)
        XCTAssertNil(server.value("app/" + key))
        await mac.pass(at: 1004)
        XCTAssertNil(mac.given[key])
    }

    func testANewcomerJoinsAndTheServerWinsWhereBothHaveOne() async {
        let server = SimulatedServer()
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
        let server = SimulatedServer()
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

    func testAnEditWaitingHereGivesWayToANewerOneFetched() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        let phone = Device("phone", server: server, folder: folder)
        await mac.pass(at: 1000)
        await phone.pass(at: 1001)
        // The Mac's edit can't be sent; the phone's, made later, can.
        mac.items["bm:1"] = "Mac, earlier"
        server.savesBeforeFailing = 0
        await mac.pass(at: 2000)
        server.savesBeforeFailing = nil
        phone.items["bm:1"] = "Phone, later"
        await phone.pass(at: 3000)
        await mac.pass(at: 3500)
        XCTAssertEqual(server.value("app/bm:1"), "Phone, later", "the older edit isn't sent over the newer one")
        XCTAssertEqual(mac.items["bm:1"], "Phone, later")
    }

    func testASaveOverAVersionNotYetSeenIsSettledByTheMerge() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        await mac.pass(at: 1000)
        mac.items["bm:1"] = "Mac, newest"
        // Another device saves between the Mac's fetch and its save, with an
        // older stamp: the Mac's save is refused, and its edit, still the
        // newer, goes again over the new tag.
        server.duringSave = {
            _ = server.save("app/bm:1", SyncEntry(v: "Elsewhere, older", t: 1500, d: "pad"),
                            over: server.item("app/bm:1")?.tag)
        }
        await mac.pass(at: 2000)
        XCTAssertEqual(server.value("app/bm:1"), "Mac, newest")
        XCTAssertEqual(mac.items["bm:1"], "Mac, newest")
    }

    func testAnOldDeletionIsForgottenButNeverTakenOffTheServer() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        await mac.pass(at: 1000)
        mac.items = [:]
        await mac.pass(at: 1001)
        let later = 1001 + SyncMerge.tombstoneLife + 10
        await mac.pass(at: later)
        XCTAssertNotNil(server.records["app/bm:1"], "still a tombstone: taking it off could take off a restore")
        let phone = Device("phone", server: server, items: ["bm:1": "Brought back"], folder: folder)
        await phone.pass(at: later + 1)
        await mac.pass(at: later + 2)
        XCTAssertEqual(mac.items["bm:1"], "Brought back", "a year-old deletion beats nothing a newcomer brings")
    }

    func testNothingIsSavedWhenNothingChanged() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        await mac.pass(at: 1000)
        let saves = server.saves
        await mac.pass(at: 1001)
        await mac.pass(at: 1002)
        XCTAssertEqual(server.saves, saves)
    }

    func testAForgottenTokenFetchesEverythingAgain() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        let phone = Device("phone", server: server, folder: folder)
        await mac.pass(at: 1000)
        await phone.pass(at: 1001)
        phone.transport.token = 0
        await phone.pass(at: 1002)
        XCTAssertEqual(phone.items, ["bm:1": "A"])
    }

    // MARK: - the first sync

    func testNothingIsAppliedOrSentBeforeTheFirstFetch() async {
        let server = SimulatedServer()
        let phone = Device("phone", server: server, items: ["bm:1": "Mine"], folder: folder)
        server.refusal = .unavailable("offline")
        await phone.pass(at: 1000)
        XCTAssertEqual(phone.sync.status, .problem(.unavailable("offline")))
        XCTAssertTrue(server.records.isEmpty)
        XCTAssertEqual(phone.items, ["bm:1": "Mine"])
        XCTAssertEqual(phone.sync.status, .problem(.unavailable("offline")))
        server.refusal = nil
        await phone.pass(at: 1001)
        XCTAssertEqual(server.value("app/bm:1"), "Mine")
    }

    func testAProblemIsSaid() {
        XCTAssertEqual(CloudProblem.noAccount.sentence, "Sign in to iCloud to sync")
    }

    func testWhatADeviceAgreedBeforeCKSyncEngineCarriesOn() async throws {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "Kept", "bm:2": "Deleted later"], folder: folder)
        await mac.pass(at: 1000)
        // The phone synced with the sync before: it agreed both, then deleted one.
        struct Legacy: Encodable {
            var account: String
            var token: Data?
            var server: [String: SyncEntry] = [:]
            var bases: [String: [String: SyncEntry]]
        }
        let base = ["bm:1": SyncEntry(v: "Kept", t: 1000, d: "mac"), "bm:2": SyncEntry(v: "Deleted later", t: 1000, d: "mac")]
        let legacy = folder.appendingPathComponent("legacy.json")
        try JSONEncoder().encode(Legacy(account: "someone", token: nil, bases: ["app": base])).write(to: legacy)
        let phone = Device("phone", server: server, items: ["bm:1": "Kept"], folder: folder, legacy: legacy)
        await phone.pass(at: 2000)
        XCTAssertNil(server.value("app/bm:2"), "the deletion travels, rather than the item coming back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    // MARK: - saves that fail or race

    func testARestoreElsewhereSurvivesASaveThatFailed() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "Article"], folder: folder)
        let phone = Device("phone", server: server, folder: folder)
        await mac.pass(at: 1000)
        await phone.pass(at: 1001)
        phone.items["bm:1"] = nil
        await phone.pass(at: 1002)

        // The Mac hears of the deletion, but can't save its own new bookmark.
        mac.items["bm:2"] = "New"
        server.savesBeforeFailing = 0
        await mac.pass(at: 1003)
        XCTAssertEqual(mac.sync.status, .problem(.unavailable("offline")))
        XCTAssertNil(mac.items["bm:1"], "the deletion fetched is applied")

        // Then the phone brings it back.
        server.savesBeforeFailing = nil
        phone.items["bm:1"] = "Article, again"
        await phone.pass(at: 1004)
        await mac.pass(at: 1005)
        XCTAssertEqual(mac.items["bm:1"], "Article, again", "the restore is not deleted by the retry")
        XCTAssertEqual(server.value("app/bm:1"), "Article, again")
        XCTAssertEqual(server.value("app/bm:2"), "New")
    }

    func testAnEditAfterASaveThatFailedPartWayWins() async {
        let server = SimulatedServer()
        var many: [String: String] = [:]
        for index in 0..<401 { many["bm:\(index)"] = "Before" }
        let mac = Device("mac", server: server, items: many, folder: folder)
        server.savesBeforeFailing = 200
        await mac.pass(at: 1000)
        XCTAssertEqual(mac.sync.status, .problem(.unavailable("offline")))
        server.savesBeforeFailing = nil
        for key in many.keys { mac.items[key] = "After" }
        await mac.pass(at: 1001)
        XCTAssertEqual(Set(mac.items.values), ["After"])
        XCTAssertEqual(server.records.count, 401)
        XCTAssertEqual(Set(server.records.values.map(\.entry.v)), ["After"])
    }

    func testAnEditOrADeletionDuringTheFirstSaveWins() async {
        for edit in ["After", nil] as [String?] {
            let server = SimulatedServer()
            let mac = Device("mac", server: server, items: ["bm:1": "Before"], folder: folder)
            server.duringSave = { mac.items["bm:1"] = edit }
            await mac.pass(at: 1000)
            XCTAssertEqual(mac.items["bm:1"], edit, "not undone by the pass")
            await mac.pass(at: 1001)
            XCTAssertEqual(server.value("app/bm:1"), edit, "and on the server by the pass that follows")
            mac.sync.stop(forgetting: true)
        }
    }

    func testARemoteChangeArrivesThoughTheAppChangedDuringTheSave() async {
        let server = SimulatedServer()
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
        await mac.pass(at: 1004)
        XCTAssertEqual(mac.items, ["bm:1": "Renamed on the phone", "bm:3": "Mac's, renamed while saving", "bm:4": "Another"])
        XCTAssertEqual(server.value("app/bm:3"), "Mac's, renamed while saving")
    }

    func testWhatAScopeSaysWhileTakingItInIsNotAnEdit() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        let phone = Device("phone", server: server, folder: folder)
        await mac.pass(at: 1000)
        phone.whileApplying = { phone.sync.localChange() }
        await phone.pass(at: 1001)
        let saves = server.saves
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(server.saves, saves, "the echo of what it was given sends nothing")
    }

    func testASaveThatFailedGoesAgainAtTheNextRefresh() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        server.savesBeforeFailing = 0
        await mac.pass(at: 1000)
        XCTAssertNil(server.value("app/bm:1"))
        XCTAssertTrue(mac.transport.pending.isEmpty, "the engine let it go")
        server.savesBeforeFailing = nil
        await mac.pass(at: 1001)
        XCTAssertEqual(server.value("app/bm:1"), "A", "nothing changed here, and it went anyway")
    }

    func testACrashWhileTakingInADeletionIsFinishedNotTakenForAnEdit() async throws {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "Article", "bm:2": "Other"], folder: folder)
        let phone = Device("phone", server: server, folder: folder)
        await mac.pass(at: 1000)
        await phone.pass(at: 1001)
        phone.items["bm:1"] = nil
        await phone.pass(at: 1002)

        // The Mac takes the deletion in; its stores reach disk, then it stops
        // before its replica does: the replica as it was on disk mid-way,
        // kept again where the Mac keeps it.
        var crashed: Replica?
        mac.whileApplying = { crashed = mac.store.commits.last }
        await mac.pass(at: 1003)
        mac.sync.stop(forgetting: true)
        let journal = try XCTUnwrap(crashed)
        XCTAssertNotNil(journal.projecting["app"], "the journal was on disk before the stores changed")
        try SQLiteReplicaStore(url: folder.appendingPathComponent("mac.sqlite")).commit(journal)

        // Meanwhile the phone brings it back.
        phone.items["bm:1"] = "Article, again"
        await phone.pass(at: 1004)
        let restarted = Device("mac", server: server, items: mac.items, folder: folder)
        await restarted.pass(at: 1005)
        XCTAssertEqual(server.value("app/bm:1"), "Article, again", "no deletion stamped on the way back")
        XCTAssertEqual(restarted.items["bm:1"], "Article, again")
    }

    func testARecordThisBuildCantReadIsNeverOverwritten() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        await mac.pass(at: 1000)
        await mac.pass(at: 1001)
        let saves = server.saves
        // A newer Eden's version of it arrives, which this build can't read.
        mac.transport.delegate?.transport(.unreadable(["app/bm:1"]))
        mac.items["bm:1"] = "Edited here"
        await mac.pass(at: 1002)
        XCTAssertEqual(server.saves, saves, "left as the newer Eden wrote it")
    }

    func testAZoneGoneWhileRunningIsAskedAboutBeforeBeingMadeAgain() async throws {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        await mac.pass(at: 1000)
        var told: CloudProblem?
        mac.sync.stoppedItself = { told = $0 }
        let made = mac.transport.zonesMade
        server.zoneErased = true
        mac.transport.delegate?.transport(.zoneMissing(["app/bm:1"]))
        for _ in 0..<100 where told == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(told, .erased, "deleted from iCloud: sync turns off")
        XCTAssertEqual(mac.transport.zonesMade, made, "and the zone isn't made again")
    }

    func testAZoneIsNeverMadeAgainWithoutAFetchThatSaysItWasntDeleted() async throws {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        await mac.pass(at: 1000)
        let made = mac.transport.zonesMade
        server.refusal = .unavailable("offline")
        mac.transport.delegate?.transport(.zoneMissing(["app/bm:1"]))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mac.transport.zonesMade, made, "the fetch failed: nothing is made")
        server.refusal = nil
        await mac.pass(at: 1001)
        XCTAssertEqual(mac.transport.zonesMade, made + 1, "a fetch that says nothing of a deletion: made again")
    }

    func testAStoreThatCantBeWrittenHaltsSyncAndIsFinishedNextTime() async throws {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "Article", "bm:2": "Other"], folder: folder)
        let phone = Device("phone", server: server, folder: folder)
        await mac.pass(at: 1000)
        await phone.pass(at: 1001)
        phone.items["bm:1"] = nil
        await phone.pass(at: 1002)

        // The Mac's bookmarks file can't be written as it takes the deletion in.
        let locked = folder.appendingPathComponent("stores", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        mac.file = locked.appendingPathComponent("bookmarks.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        await mac.pass(at: 1003)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        XCTAssertEqual(mac.sync.status, .problem(.unwritable))
        let saves = server.saves
        mac.items["bm:2"] = "Edited after"
        await mac.pass(at: 1004)
        XCTAssertEqual(server.saves, saves, "nothing more is sent this time")

        // Opened again, with its bookmarks as they reached disk: the deletion
        // never did, the edit made after the halt, once the disk was back, did.
        mac.sync.stop(forgetting: false)
        let reopened = Device("mac", server: server, items: ["bm:1": "Article", "bm:2": "Edited after", "bm:3": "Added after"],
                              folder: folder)
        await reopened.pass(at: 2000)
        XCTAssertNil(reopened.items["bm:1"], "the deletion it was taking in is finished")
        XCTAssertEqual(server.records["app/bm:1"]?.entry.d, "phone", "with no new deletion of its own")
        XCTAssertEqual(reopened.items["bm:2"], "Edited after", "an edit saved since is kept")
        XCTAssertEqual(server.value("app/bm:2"), "Edited after", "and synced")
        XCTAssertEqual(server.value("app/bm:3"), "Added after")
    }

    func testNothingIsSentThatIsntOnDiskFirst() async throws {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        await mac.pass(at: 1000)
        let saves = server.saves
        mac.store.failsCommits = true
        mac.items["bm:1"] = nil
        await mac.pass(at: 1001)
        XCTAssertEqual(server.saves, saves, "the deletion's stamp couldn't be kept, so it didn't go")
        if case .problem = mac.sync.status {} else { XCTFail("and the problem is said") }
    }

    // MARK: - stopping

    func testTurnedOffDuringASaveTheServerIsLeftAlone() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A", "bm:2": "B", "bm:3": "C"], folder: folder)
        server.duringSave = { mac.sync.stop(forgetting: true) }
        await mac.pass(at: 1000)
        XCTAssertEqual(server.saves, 0, "nothing after it was turned off")
        XCTAssertEqual(mac.sync.status, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mac.sqlite").path))
    }

    func testWhatCantBeForgottenIsSaidNotHidden() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        await mac.pass(at: 1000)
        mac.store.failsErasing = true
        XCTAssertFalse(mac.sync.stop(forgetting: true))
        XCTAssertEqual(mac.sync.status, .problem(.unwritable))

        let phone = Device("phone", server: server, items: ["bm:1": "A"], folder: folder)
        await phone.pass(at: 1001)
        phone.store.failsErasing = true
        var told: CloudProblem?
        phone.sync.stoppedItself = { told = $0 }
        phone.transport.delegate?.transport(.zoneLost(.erased))
        XCTAssertEqual(told, .unwritable, "deleted from iCloud, but not forgotten here: that is what to say")
    }

    func testAPassAskedForAfterTurningOffDoesNothing() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        mac.sync.stop(forgetting: true)
        await mac.pass(at: 1000)
        XCTAssertTrue(server.records.isEmpty)
        XCTAssertEqual(mac.sync.status, .idle)
    }

    func testDataErasedFromICloudTurnsSyncOff() async {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        await mac.pass(at: 1000)
        var told: CloudProblem?
        mac.sync.stoppedItself = { told = $0 }
        mac.transport.delegate?.transport(.zoneLost(.erased))
        XCTAssertEqual(told, .erased)
        XCTAssertEqual(mac.sync.status, .problem(.erased))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mac.sqlite").path))
        XCTAssertEqual(mac.items, ["bm:1": "A"], "what is in the browser stays")
    }

    func testAnEncryptionResetPutsThisDevicesItemsBack() async throws {
        let server = SimulatedServer()
        let mac = Device("mac", server: server, items: ["bm:1": "A"], folder: folder)
        await mac.pass(at: 1000)
        server.records = [:]
        mac.transport.delegate?.transport(.zoneLost(.encryptionReset))
        for _ in 0..<100 where server.value("app/bm:1") == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(server.value("app/bm:1"), "A")
    }

    func testAnotherAppleAccountStartsAfreshAndGetsNothingOfTheFirst() async {
        let first = SimulatedServer()
        let phone = Device("phone", server: first, items: [SyncItems.tabsKey("phone"): "{}"], folder: folder)
        await phone.pass(at: 1000)
        let mac = Device("mac", server: first, items: ["bm:1": "Mine"], folder: folder) { !$0.hasPrefix("tabs:") }
        await mac.pass(at: 1001)
        mac.sync.stop(forgetting: false)

        let second = SimulatedServer()
        second.account = "someone else"
        let again = Device("mac", server: second, items: mac.items, folder: folder) { !$0.hasPrefix("tabs:") }
        await again.pass(at: 2000)
        XCTAssertNil(second.records["app/" + SyncItems.tabsKey("phone")], "the first account's phone stays there")
        XCTAssertEqual(second.value("app/bm:1"), "Mine", "this Mac's own things join the new one")
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
