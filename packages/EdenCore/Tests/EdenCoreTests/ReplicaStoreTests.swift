import XCTest
@testable import EdenCore

/// The replica in SQLite (SQLiteReplicaStore): what is committed comes back
/// as it was — empty maps apart from missing ones — row by row as it changes,
/// and what earlier Edens kept is carried over once.
@MainActor
final class ReplicaStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("replica-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var url: URL { folder.appendingPathComponent("cloud.sqlite") }

    private func entry(_ v: String?, _ t: Double, _ d: String = "mac") -> SyncEntry { SyncEntry(v: v, t: t, d: d) }

    private func sample() -> Replica {
        var replica = Replica(account: "_abc")
        replica.checkpoint = Data([1, 2, 3])
        replica.fetched = true
        replica.zoneMade = true
        replica.server = ["app/bm:1": ServerItem(entry: entry("A", 10), tag: Data(repeating: 7, count: 2400)),
                          "app/bm:2": ServerItem(entry: entry(nil, 11, "phone"), tag: nil)]
        replica.outgoing = ["app/bm:3": entry("C", 12)]
        replica.blocked = ["app/bm:9"]
        replica.applied = ["app": ["bm:1": entry("A", 10)], "profile-x": [:]]
        replica.projecting = ["app": [:]]
        return replica
    }

    func testWhatIsCommittedComesBackAsItWas() throws {
        try SQLiteReplicaStore(url: url).commit(sample())
        let read = try XCTUnwrap(try SQLiteReplicaStore(url: url).load())
        XCTAssertEqual(read, sample())
        XCTAssertEqual(read.applied["profile-x"], [:], "a scope applied empty is not a scope never applied")
        XCTAssertNil(read.applied["profile-y"])
        XCTAssertEqual(read.projecting["app"], [:], "an empty journal is a journal")
    }

    func testNothingKeptIsNil() throws {
        XCTAssertNil(try SQLiteReplicaStore(url: url).load())
    }

    func testChangesLandRowByRow() throws {
        let store = SQLiteReplicaStore(url: url)
        _ = try store.load()
        var replica = sample()
        try store.commit(replica)
        replica.server["app/bm:1"] = ServerItem(entry: entry("A, renamed", 20), tag: Data([9]))
        replica.server["app/bm:2"] = nil
        replica.outgoing = [:]
        replica.blocked = []
        replica.applied["profile-x"] = nil
        replica.applied["app"]?["bm:4"] = entry("D", 21)
        replica.projecting = [:]
        replica.checkpoint = Data([4])
        try store.commit(replica)
        XCTAssertEqual(try SQLiteReplicaStore(url: url).load(), replica)
    }

    func testANewerEdensDatabaseIsntRead() throws {
        try SQLiteReplicaStore(url: url).commit(sample())
        let database = try SQLiteDatabase(url: url)
        try database.execute("PRAGMA user_version = 99")
        XCTAssertThrowsError(try SQLiteReplicaStore(url: url).load())
    }

    func testTheJSONReplicaOfAnEarlierEdenIsCarriedOverOnce() throws {
        let former = folder.appendingPathComponent("cloud-replica.json")
        try JSONEncoder().encode(sample()).write(to: former)
        let store = SQLiteReplicaStore(url: url, formerReplica: former)
        let read = try XCTUnwrap(try store.load())
        XCTAssertEqual(read, sample())
        XCTAssertTrue(FileManager.default.fileExists(atPath: former.path), "kept until the database has it")
        try store.commit(read)
        XCTAssertFalse(FileManager.default.fileExists(atPath: former.path))
        XCTAssertEqual(try SQLiteReplicaStore(url: url, formerReplica: former).load(), sample())
    }

    func testErasingLeavesNothing() throws {
        let store = SQLiteReplicaStore(url: url)
        try store.commit(sample())
        try store.erase()
        XCTAssertNil(try SQLiteReplicaStore(url: url).load())
    }

    /// How many rows each table had written, counted by triggers.
    private func countWrites(in database: SQLiteDatabase) throws {
        try database.execute("CREATE TABLE writes (name TEXT PRIMARY KEY, n INTEGER NOT NULL)")
        for table in ["meta", "server", "outgoing", "blocked", "scopes", "scoped"] {
            try database.execute("""
                INSERT INTO writes VALUES ('\(table)', 0);
                CREATE TRIGGER count_\(table)_insert AFTER INSERT ON \(table)
                    BEGIN UPDATE writes SET n = n + 1 WHERE name = '\(table)'; END;
                CREATE TRIGGER count_\(table)_delete AFTER DELETE ON \(table)
                    BEGIN UPDATE writes SET n = n + 1 WHERE name = '\(table)'; END;
                """)
        }
    }

    private func writes(in database: SQLiteDatabase) throws -> [String: Int64] {
        var out: [String: Int64] = [:]
        for row in try database.rows("SELECT name, n FROM writes") { out[row[0].text ?? ""] = row[1].integer }
        return out
    }

    func testOnlyWhatChangedIsWrittenAndNothingWhenNothingDid() throws {
        let store = SQLiteReplicaStore(url: url)
        var replica = sample()
        try store.commit(replica)
        let watcher = try SQLiteDatabase(url: url)
        try countWrites(in: watcher)
        try store.commit(replica)
        XCTAssertEqual(try writes(in: watcher).values.reduce(0, +), 0, "the same replica again writes nothing")
        replica.outgoing["app/bm:5"] = entry("E", 30)
        try store.commit(replica)
        XCTAssertEqual(try writes(in: watcher), ["meta": 0, "server": 0, "outgoing": 1, "blocked": 0, "scopes": 0, "scoped": 0])
    }

    func testAFailureInsideACommitLeavesTheLastOneWholeAndARetryLands() throws {
        let store = SQLiteReplicaStore(url: url)
        let first = sample()
        try store.commit(first)
        let saboteur = try SQLiteDatabase(url: url)
        try saboteur.execute("""
            CREATE TRIGGER boom BEFORE INSERT ON outgoing WHEN NEW.key = 'app/boom'
                BEGIN SELECT RAISE(ABORT, 'boom'); END;
            """)
        var second = first
        second.checkpoint = Data([42])
        second.server["app/bm:1"] = nil
        second.outgoing["app/boom"] = entry("X", 40)
        XCTAssertThrowsError(try store.commit(second))
        XCTAssertEqual(try SQLiteReplicaStore(url: url).load(), first, "nothing of the failed commit landed")
        try saboteur.execute("DROP TRIGGER boom")
        try store.commit(second)
        XCTAssertEqual(try SQLiteReplicaStore(url: url).load(), second)
    }

    func testACommitWithoutALoadStillWritesOverWhatIsThere() throws {
        try SQLiteReplicaStore(url: url).commit(sample())
        try SQLiteReplicaStore(url: url).commit(Replica())
        XCTAssertEqual(try SQLiteReplicaStore(url: url).load(), Replica())
    }

    func testTextComesBackWholeZeroBytesAndAll() throws {
        var replica = sample()
        replica.outgoing["app/bm:z"] = entry("a\u{0}b", 1)
        try SQLiteReplicaStore(url: url).commit(replica)
        XCTAssertEqual(try SQLiteReplicaStore(url: url).load()?.outgoing["app/bm:z"]?.v, "a\u{0}b")
    }

    func testAFormerFileThatCantBeReadIsKeptAndHaltsTheLoad() throws {
        let former = folder.appendingPathComponent("cloud-replica.json")
        try Data("{\"account\": \"_abc\", \"serv".utf8).write(to: former)
        let store = SQLiteReplicaStore(url: url, formerReplica: former)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: former.path), "kept, not deleted unread")
    }

    func testErasingBeforeTheFirstCommitTakesTheFormerFilesToo() throws {
        let former = folder.appendingPathComponent("cloud-replica.json")
        try JSONEncoder().encode(sample()).write(to: former)
        let store = SQLiteReplicaStore(url: url, formerReplica: former)
        XCTAssertNotNil(try store.load())
        try store.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: former.path))
        XCTAssertNil(try SQLiteReplicaStore(url: url, formerReplica: former).load(), "turned on again, it joins afresh")
    }

    func testTheSchemaRefusesWhatCantBeRead() throws {
        try SQLiteReplicaStore(url: url).commit(sample())
        let database = try SQLiteDatabase(url: url)
        XCTAssertThrowsError(try database.run("INSERT INTO server (key, v, t, d) VALUES (?, ?, ?, ?)",
                                              [[.text("app/x"), .blob(Data([1])), .real(1), .text("mac")]]),
                             "a value that isn't text")
        XCTAssertThrowsError(try database.run("INSERT INTO scopes (kind, scope) VALUES (?, ?)",
                                              [[.text("other"), .text("app")]]), "a kind that isn't one of the two")
        try database.execute("PRAGMA foreign_keys = ON")
        XCTAssertThrowsError(try database.run("INSERT INTO scoped (kind, scope, key, v, t, d) VALUES (?, ?, ?, ?, ?, ?)",
                                              [[.text("applied"), .text("nowhere"), .text("k"), .null, .real(1), .text("mac")]]),
                             "an item under a scope with no map")
        try database.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [[.text("fetched"), .text("yes")]])
        XCTAssertThrowsError(try SQLiteReplicaStore(url: url).load(), "and what slips past is refused when read")
    }

    func testDamagedMetadataIsRefusedNotTakenForNothingKept() throws {
        for damage in ["DELETE FROM meta WHERE key = 'kept'", "UPDATE meta SET value = 2 WHERE key = 'kept'",
                       "DELETE FROM meta WHERE key = 'fetched'", "UPDATE meta SET value = NULL WHERE key = 'zoneMade'"] {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try SQLiteReplicaStore(url: url).commit(sample())
            try SQLiteDatabase(url: url).execute(damage)
            XCTAssertThrowsError(try SQLiteReplicaStore(url: url).load(), damage)
            XCTAssertThrowsError(try SQLiteReplicaStore(url: url).commit(Replica()), "nor written over: \(damage)")
        }
    }

    func testFormerFilesThatCouldntGoAreDeletedAfterARelaunch() throws {
        let place = folder.appendingPathComponent("former", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let former = place.appendingPathComponent("cloud-replica.json")
        try JSONEncoder().encode(sample()).write(to: former)
        let store = SQLiteReplicaStore(url: url, formerReplica: former)
        let carried = try XCTUnwrap(try store.load())
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: place.path)
        try store.commit(carried)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: place.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: former.path), "couldn't go then")
        XCTAssertEqual(try SQLiteReplicaStore(url: url, formerReplica: former).load(), sample())
        XCTAssertFalse(FileManager.default.fileExists(atPath: former.path), "gone at the next launch's load")
    }

    func testAnEraseThatCantTakeTheFormerFilesLeavesTheDatabase() throws {
        let place = folder.appendingPathComponent("former", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let former = place.appendingPathComponent("cloud-replica.json")
        try JSONEncoder().encode(Replica(account: "_old")).write(to: former)
        let store = SQLiteReplicaStore(url: url, formerReplica: former)
        _ = try store.load()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: place.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: place.path) }
        let newer = sample()
        try store.commit(newer)
        XCTAssertThrowsError(try store.erase())
        XCTAssertEqual(try SQLiteReplicaStore(url: url, formerReplica: former).load(), newer,
                       "relaunched, the newer state is there, not the former file's")
    }

    func testOldDeletionsAreForgottenHereUnlessAnEditWaits() {
        var replica = Replica(account: "a")
        let old = 1000.0
        replica.server = ["app/bm:1": ServerItem(entry: entry(nil, old), tag: nil),
                          "app/bm:2": ServerItem(entry: entry(nil, old), tag: nil),
                          "app/bm:3": ServerItem(entry: entry("Live", old), tag: nil)]
        replica.outgoing = ["app/bm:2": entry("Back", old + SyncMerge.tombstoneLife + 5)]
        replica.prune(now: old + SyncMerge.tombstoneLife + 10)
        XCTAssertEqual(Set(replica.server.keys), ["app/bm:2", "app/bm:3"])
    }
}
