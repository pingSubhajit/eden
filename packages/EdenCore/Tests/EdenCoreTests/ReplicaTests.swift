import CloudKit
import XCTest
@testable import EdenCore

/// The replica's rules on their own (Replica), and items as CloudKit records
/// and back (ItemRecord), without a server.
final class ReplicaTests: XCTestCase {
    private let all: (String, String) -> Bool = { _, _ in true }

    private func entry(_ v: String?, _ t: Double, _ d: String = "mac") -> SyncEntry { SyncEntry(v: v, t: t, d: d) }

    func testAnEditIsStampedAfterEverythingSeenAndWaitsOnce() {
        var replica = Replica(account: "a")
        replica.received(["app/bm:1": ServerItem(entry: entry("A", 5000, "phone"), tag: nil)])
        replica.applied(["bm:1": entry("A", 5000, "phone")], to: "app")
        let queued = replica.capture(scope: "app", snapshot: ["bm:1": "B"], owns: all, device: "mac", now: 1000)
        XCTAssertEqual(queued, ["app/bm:1"])
        XCTAssertGreaterThan(replica.outgoing["app/bm:1"]?.t ?? 0, 5000, "later than the server's, whatever the clock")
        let again = replica.capture(scope: "app", snapshot: ["bm:1": "B"], owns: all, device: "mac", now: 1001)
        XCTAssertTrue(again.isEmpty, "the same edit isn't stamped twice")
    }

    func testAScopeNeverAppliedJoinsUnderTheServer() {
        var replica = Replica(account: "a")
        replica.received(["app/set:x": ServerItem(entry: entry("\"server\"", 10, "phone"), tag: nil)])
        _ = replica.capture(scope: "app", snapshot: ["set:x": "\"mine\"", "bm:1": "Only here"], owns: all,
                            device: "mac", now: 1000)
        XCTAssertNil(replica.outgoing["app/set:x"], "where both have one, the server's wins")
        XCTAssertEqual(replica.outgoing["app/bm:1"]?.v, "Only here", "what only this device has goes up")
        XCTAssertEqual(SyncMerge.live(replica.target(scope: "app", now: 1000)),
                       ["set:x": "\"server\"", "bm:1": "Only here"])
    }

    func testOnlyWhatTheScopeOwnsIsDeleted() {
        var replica = Replica(account: "a")
        replica.applied(["pin:a": entry("Mail", 10), "bm:1": entry("A", 10)], to: "app")
        replica.received(["app/pin:a": ServerItem(entry: entry("Mail", 10), tag: nil),
                          "app/bm:1": ServerItem(entry: entry("A", 10), tag: nil)])
        _ = replica.capture(scope: "app", snapshot: [:], owns: { key, _ in key.hasPrefix("bm:") }, device: "phone", now: 1000)
        XCTAssertEqual(replica.outgoing["app/bm:1"]?.v, .some(nil), "a tombstone for what it owns")
        XCTAssertNil(replica.outgoing["app/pin:a"], "and nothing for what it only carries")
    }

    func testASaveClearsOnlyTheEditItCarried() {
        var replica = Replica(account: "a")
        replica.outgoing["app/bm:1"] = entry("Newer", 20)
        let again = replica.saved(["app/bm:1": ServerItem(entry: entry("Older", 10), tag: Data([1]))])
        XCTAssertEqual(again, ["app/bm:1"], "an edit made since still waits")
        XCTAssertEqual(replica.outgoing(for: "app/bm:1")?.tag, Data([1]), "now over the new tag")
        _ = replica.saved(["app/bm:1": ServerItem(entry: entry("Newer", 20), tag: Data([2]))])
        XCTAssertNil(replica.outgoing["app/bm:1"])
    }

    func testAConflictKeepsTheWinner() {
        var replica = Replica(account: "a")
        replica.outgoing["app/bm:1"] = entry("Mine", 20)
        XCTAssertEqual(replica.conflicted(["app/bm:1": ServerItem(entry: entry("Theirs", 10, "pad"), tag: Data([3]))]),
                       ["app/bm:1"], "mine is newer: sent again")
        XCTAssertTrue(replica.conflicted(["app/bm:1": ServerItem(entry: entry("Theirs", 30, "pad"), tag: Data([4]))]).isEmpty)
        XCTAssertNil(replica.outgoing["app/bm:1"], "theirs is newer: mine gives way")
    }

    func testAnotherAccountKeepsNothing() {
        var replica = Replica(account: "a")
        replica.outgoing["app/bm:1"] = entry("A", 1)
        replica.fetched = true
        XCTAssertFalse(replica.bind(to: "a"))
        XCTAssertTrue(replica.bind(to: "b"))
        XCTAssertEqual(replica, Replica(account: "b"))
    }

    func testKeysSplitAtTheirFirstSlash() {
        XCTAssertEqual(Replica.split("profile-x/bm:1")?.scope, "profile-x")
        XCTAssertEqual(Replica.split("app/visit:https://a/b")?.key, "visit:https://a/b")
        XCTAssertEqual(Replica.recordName("app/bm:1").count, 64)
    }

    // MARK: - records

    func testAnItemGoesAndComesBackAsARecord() throws {
        let outgoing = OutgoingRecord(key: "app/bm:1", entry: entry("Article", 1234.5), tag: nil)
        let record = ItemRecord.record(outgoing)
        XCTAssertEqual(record.recordID.recordName, Replica.recordName("app/bm:1"))
        let (key, item) = try XCTUnwrap(ItemRecord.item(from: record))
        XCTAssertEqual(key, "app/bm:1")
        XCTAssertEqual(item.entry, outgoing.entry)
        XCTAssertNotNil(item.tag)
        // Sent again over its tag, it is the same record.
        let over = ItemRecord.record(OutgoingRecord(key: key, entry: entry(nil, 2000), tag: item.tag))
        XCTAssertEqual(over.recordID, record.recordID)
        XCTAssertNil(over["v"], "a tombstone clears the value")
        XCTAssertEqual(ItemRecord.item(from: over)?.1.entry, entry(nil, 2000))
    }

    func testARecordThisBuildCantReadIsLeftAlone() {
        let record = ItemRecord.record(OutgoingRecord(key: "app/bm:1", entry: entry("A", 1), tag: nil))
        record["v"] = 42 as NSNumber
        XCTAssertNil(ItemRecord.item(from: record), "a value of another kind isn't taken for a deletion")
        let misnamed = CKRecord(recordType: "Item", recordID: CKRecord.ID(recordName: "x", zoneID: CloudKitTransport.zoneID))
        misnamed["key"] = "app/bm:1" as NSString
        misnamed["t"] = 1 as NSNumber
        misnamed["d"] = "mac" as NSString
        XCTAssertNil(ItemRecord.item(from: misnamed))
    }
}
