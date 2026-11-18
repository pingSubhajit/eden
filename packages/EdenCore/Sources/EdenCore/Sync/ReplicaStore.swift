import Foundation

/// Where a device's Replica is kept between launches (CloudSync): on disk
/// before anything acts on it. One store owns its database: two over the same
/// file would each write against what it last saw.
@MainActor
public protocol ReplicaStore: AnyObject {
    /// What was kept, or nil when nothing was. Throws when something kept
    /// can't be read: sync halts rather than starting over it.
    func load() throws -> Replica?
    /// The replica kept, whole, when this returns; nothing of it when it
    /// throws.
    func commit(_ replica: Replica) throws
    /// Everything kept, gone: sync turned off. Throws when something couldn't
    /// be deleted.
    func erase() throws
}

// The replica in SQLite: each item a row, so a commit writes only what
// changed since the last one, in one transaction — an edit to send, what a
// scope was given, a projection's journal and the engine's checkpoint land
// together or not at all.
//
//   meta(key, value)                   account, checkpoint, fetched, zoneMade;
//                                      `kept`: a replica is here; `former`:
//                                      earlier Edens' files still to delete
//   server(key, v, t, d, tag)          the server's items, with their tags
//   outgoing(key, v, t, d)             edits waiting to be sent
//   blocked(key)                       records this build can't read
//   scopes(kind, scope)                which scopes have an `applied` map or a
//                                      `projecting` journal, empty or not: a
//                                      scope never applied joins, so "none"
//                                      and "empty" differ
//   scoped(kind, scope, key, v, t, d)  those maps' items, gone with their scope
//
// The schema holds its own rules — a value is text or null, a stamp a number,
// a kind one of the two, an item only under a scope that has the map — and a
// row that breaks one when read fails the load rather than being guessed at.
// WAL with full synchronous commits: what commit returned from is on disk.
// A commit compares the whole replica with the last one to find the rows to
// write: linear in its size, about a millisecond at 10,000 items. The history
// is capped at 2,000 places a profile and deletions are forgotten after a
// year, so a replica stays within thousands of items; tracking changed keys
// in Replica would earn its bookkeeping only far beyond that.
// `server` keeps its rowid: its rows carry a record's archived system fields
// (a couple of kilobytes each), which SQLite stores poorly in WITHOUT ROWID
// tables; the rest are small rows keyed by their text.

@MainActor
public final class SQLiteReplicaStore: ReplicaStore {
    /// The schema's version (PRAGMA user_version): a newer one, from a later
    /// Eden, isn't read.
    static let version: Int64 = 1

    private let url: URL
    private let formerReplica: URL?
    private let formerBases: URL?
    private var database: SQLiteDatabase?
    /// The replica as the database holds it, to write only the difference;
    /// nil until read from it.
    private var committed: Replica?
    /// Whether the database holds a replica at all (`meta.kept`).
    private var kept = false
    /// A former file was carried over: deleted once the database has it.
    private var carriedOver = false

    /// `url`: the database. `formerReplica`, `formerBases`: what earlier Edens
    /// kept (the replica as JSON; the per-scope bases of the sync before
    /// CKSyncEngine), carried over when the database has nothing yet and
    /// deleted once it does.
    public init(url: URL, formerReplica: URL? = nil, formerBases: URL? = nil) {
        self.url = url
        self.formerReplica = formerReplica
        self.formerBases = formerBases
    }

    public func load() throws -> Replica? {
        let stored = try baseline()
        if kept {
            removeFormerFiles()
            return stored
        }
        guard let carried = try former() else { return nil }
        carriedOver = true
        return carried
    }

    public func commit(_ replica: Replica) throws {
        let before = try baseline()
        if kept, replica == before { return removeFormerFiles() }
        let database = try open()
        try database.transaction {
            try writeMeta(replica, over: before, in: database)
            if !kept, carriedOver { try noteFormer(true, in: database) }
            try write(replica.server, over: before.server, in: database,
                      upsert: "INSERT OR REPLACE INTO server (key, v, t, d, tag) VALUES (?, ?, ?, ?, ?)",
                      row: { key, item in
                          [.text(key)] + SQLiteReplicaStore.values(item.entry) + [item.tag.map(SQLiteValue.blob) ?? .null]
                      },
                      delete: "DELETE FROM server WHERE key = ?", deleteRow: { [.text($0)] })
            try write(replica.outgoing, over: before.outgoing, in: database,
                      upsert: "INSERT OR REPLACE INTO outgoing (key, v, t, d) VALUES (?, ?, ?, ?)",
                      row: { key, entry in [.text(key)] + SQLiteReplicaStore.values(entry) },
                      delete: "DELETE FROM outgoing WHERE key = ?", deleteRow: { [.text($0)] })
            try database.run("INSERT INTO blocked (key) VALUES (?)",
                             replica.blocked.subtracting(before.blocked).map { [.text($0)] })
            try database.run("DELETE FROM blocked WHERE key = ?",
                             before.blocked.subtracting(replica.blocked).map { [.text($0)] })
            try writeScoped(.applied, replica.applied, over: before.applied, in: database)
            try writeScoped(.projecting, replica.projecting, over: before.projecting, in: database)
        }
        committed = replica
        kept = true
        removeFormerFiles()
    }

    /// Whether earlier Edens' files are still to delete: said in `meta`, so a
    /// deletion that failed is tried again after a relaunch too.
    private func noteFormer(_ pending: Bool, in database: SQLiteDatabase) throws {
        if pending {
            try database.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('former', 1)")
        } else {
            try database.execute("DELETE FROM meta WHERE key = 'former'")
        }
    }

    public func erase() throws {
        // The former files first: turned on again, sync must join afresh, not
        // carry them over a second time — so while one can't be deleted, the
        // database, newer than they are, stays too.
        for file in [formerReplica, formerBases].compactMap({ $0 }) where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        database = nil
        committed = nil
        kept = false
        carriedOver = false
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: - schema

    private func open() throws -> SQLiteDatabase {
        if let database { return database }
        let made = try SQLiteDatabase(url: url)
        // 8 KB pages, set before anything is written (a new database only):
        // three of `server`'s rows to a page, where 4 KB pages hold one.
        try made.execute("""
            PRAGMA page_size = 8192; PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA foreign_keys = ON
            """)
        let version = try made.rows("PRAGMA user_version").first?.first?.integer ?? 0
        if version == 0 {
            try made.transaction {
                try made.execute("""
                    CREATE TABLE meta (key TEXT NOT NULL PRIMARY KEY, value) WITHOUT ROWID;
                    CREATE TABLE server (
                        key TEXT NOT NULL PRIMARY KEY,
                        v TEXT CHECK (v IS NULL OR typeof(v) = 'text'),
                        t REAL NOT NULL, d TEXT NOT NULL CHECK (d <> ''),
                        tag BLOB CHECK (tag IS NULL OR typeof(tag) = 'blob'));
                    CREATE TABLE outgoing (
                        key TEXT NOT NULL PRIMARY KEY,
                        v TEXT CHECK (v IS NULL OR typeof(v) = 'text'),
                        t REAL NOT NULL, d TEXT NOT NULL CHECK (d <> '')) WITHOUT ROWID;
                    CREATE TABLE blocked (key TEXT NOT NULL PRIMARY KEY) WITHOUT ROWID;
                    CREATE TABLE scopes (
                        kind TEXT NOT NULL CHECK (kind IN ('applied', 'projecting')),
                        scope TEXT NOT NULL,
                        PRIMARY KEY (kind, scope)) WITHOUT ROWID;
                    CREATE TABLE scoped (
                        kind TEXT NOT NULL, scope TEXT NOT NULL, key TEXT NOT NULL,
                        v TEXT CHECK (v IS NULL OR typeof(v) = 'text'),
                        t REAL NOT NULL, d TEXT NOT NULL CHECK (d <> ''),
                        PRIMARY KEY (kind, scope, key),
                        FOREIGN KEY (kind, scope) REFERENCES scopes (kind, scope) ON DELETE CASCADE) WITHOUT ROWID;
                    PRAGMA user_version = \(SQLiteReplicaStore.version);
                    """)
            }
        } else if version > SQLiteReplicaStore.version {
            throw SQLiteError(code: 0, message: "kept by a newer Eden")
        }
        database = made
        return made
    }

    /// The replica as the database holds it, read once.
    private func baseline() throws -> Replica {
        if let committed { return committed }
        let read = try self.read(try open())
        let baseline = read ?? Replica()
        kept = read != nil
        committed = baseline
        return baseline
    }

    // MARK: - reading

    private enum Kind: String {
        case applied, projecting
    }

    /// A row the schema should never have let in.
    private static func malformed(_ table: String) -> SQLiteError {
        SQLiteError(code: 0, message: "a malformed row in \(table)")
    }

    private func read(_ database: SQLiteDatabase) throws -> Replica? {
        var meta: [String: SQLiteValue] = [:]
        for row in try database.rows("SELECT key, value FROM meta") {
            guard let key = row[0].text else { throw SQLiteReplicaStore.malformed("meta") }
            meta[key] = row[1]
        }
        guard let kept = meta["kept"] else {
            // Nothing kept: so every table is empty. Rows without the marker
            // are a database damaged, not one never written.
            for table in ["meta", "server", "outgoing", "blocked", "scopes", "scoped"]
                where try database.rows("SELECT 1 FROM \(table) LIMIT 1").isEmpty == false {
                throw SQLiteReplicaStore.malformed(table)
            }
            return nil
        }
        // Written whole at the first commit: each must be there, and right.
        guard kept == .integer(1), let account = meta["account"], let checkpoint = meta["checkpoint"],
              let fetched = meta["fetched"], let zoneMade = meta["zoneMade"] else { throw SQLiteReplicaStore.malformed("meta") }
        var replica = Replica(account: try SQLiteReplicaStore.optional(account, \.text, in: "meta"))
        replica.checkpoint = try SQLiteReplicaStore.optional(checkpoint, \.blob, in: "meta")
        replica.fetched = try SQLiteReplicaStore.flag(fetched)
        replica.zoneMade = try SQLiteReplicaStore.flag(zoneMade)
        if let former = meta["former"] {
            guard former == .integer(1) else { throw SQLiteReplicaStore.malformed("meta") }
            carriedOver = true
        }
        for row in try database.rows("SELECT key, v, t, d, tag FROM server") {
            guard let key = row[0].text else { throw SQLiteReplicaStore.malformed("server") }
            let tag = try SQLiteReplicaStore.optional(row[4], \.blob, in: "server")
            replica.server[key] = ServerItem(entry: try SQLiteReplicaStore.entry(row[1], row[2], row[3], in: "server"), tag: tag)
        }
        for row in try database.rows("SELECT key, v, t, d FROM outgoing") {
            guard let key = row[0].text else { throw SQLiteReplicaStore.malformed("outgoing") }
            replica.outgoing[key] = try SQLiteReplicaStore.entry(row[1], row[2], row[3], in: "outgoing")
        }
        for row in try database.rows("SELECT key FROM blocked") {
            guard let key = row[0].text else { throw SQLiteReplicaStore.malformed("blocked") }
            replica.blocked.insert(key)
        }
        for row in try database.rows("SELECT kind, scope FROM scopes") {
            guard let kind = row[0].text.flatMap(Kind.init), let scope = row[1].text else {
                throw SQLiteReplicaStore.malformed("scopes")
            }
            switch kind {
            case .applied: replica.applied[scope] = [:]
            case .projecting: replica.projecting[scope] = [:]
            }
        }
        for row in try database.rows("SELECT kind, scope, key, v, t, d FROM scoped") {
            guard let kind = row[0].text.flatMap(Kind.init), let scope = row[1].text, let key = row[2].text else {
                throw SQLiteReplicaStore.malformed("scoped")
            }
            let entry = try SQLiteReplicaStore.entry(row[3], row[4], row[5], in: "scoped")
            switch kind {
            case .applied:
                guard replica.applied[scope] != nil else { throw SQLiteReplicaStore.malformed("scoped") }
                replica.applied[scope]?[key] = entry
            case .projecting:
                guard replica.projecting[scope] != nil else { throw SQLiteReplicaStore.malformed("scoped") }
                replica.projecting[scope]?[key] = entry
            }
        }
        return replica
    }

    /// A value that may be null, else of one type.
    private static func optional<T>(_ value: SQLiteValue?, _ type: KeyPath<SQLiteValue, T?>, in table: String) throws -> T? {
        guard let value, value != .null else { return nil }
        guard let typed = value[keyPath: type] else { throw malformed(table) }
        return typed
    }

    private static func flag(_ value: SQLiteValue) throws -> Bool {
        guard case .integer(let number) = value, number == 0 || number == 1 else { throw malformed("meta") }
        return number == 1
    }

    private static func entry(_ v: SQLiteValue, _ t: SQLiteValue, _ d: SQLiteValue, in table: String) throws -> SyncEntry {
        guard let stamp = t.real ?? t.integer.map(Double.init), stamp.isFinite, let device = d.text, !device.isEmpty
        else { throw malformed(table) }
        return SyncEntry(v: try optional(v, \.text, in: table), t: stamp, d: device)
    }

    // MARK: - writing

    private func writeMeta(_ replica: Replica, over before: Replica, in database: SQLiteDatabase) throws {
        var rows: [[SQLiteValue]] = []
        if !kept { rows.append([.text("kept"), .integer(1)]) }
        if !kept || before.account != replica.account {
            rows.append([.text("account"), replica.account.map(SQLiteValue.text) ?? .null])
        }
        if !kept || before.checkpoint != replica.checkpoint {
            rows.append([.text("checkpoint"), replica.checkpoint.map(SQLiteValue.blob) ?? .null])
        }
        if !kept || before.fetched != replica.fetched { rows.append([.text("fetched"), .integer(replica.fetched ? 1 : 0)]) }
        if !kept || before.zoneMade != replica.zoneMade {
            rows.append([.text("zoneMade"), .integer(replica.zoneMade ? 1 : 0)])
        }
        try database.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", rows)
    }

    /// A map's rows: those new or changed written, those gone deleted.
    private func write<Value: Equatable>(_ map: [String: Value], over before: [String: Value], in database: SQLiteDatabase,
                                         upsert: String, row: (String, Value) -> [SQLiteValue],
                                         delete: String, deleteRow: (String) -> [SQLiteValue]) throws {
        try database.run(upsert, map.compactMap { key, value in before[key] == value ? nil : row(key, value) })
        try database.run(delete, before.keys.filter { map[$0] == nil }.map(deleteRow))
    }

    /// The per-scope maps (`applied`, `projecting`): which scopes have one,
    /// and their items; a scope's items go with it.
    private func writeScoped(_ kind: Kind, _ maps: [String: [String: SyncEntry]], over before: [String: [String: SyncEntry]],
                             in database: SQLiteDatabase) throws {
        let name = SQLiteValue.text(kind.rawValue)
        try database.run("DELETE FROM scopes WHERE kind = ? AND scope = ?",
                         before.keys.filter { maps[$0] == nil }.map { [name, .text($0)] })
        try database.run("INSERT INTO scopes (kind, scope) VALUES (?, ?)",
                         maps.keys.filter { before[$0] == nil }.map { [name, .text($0)] })
        for (scope, map) in maps {
            let old = before[scope] ?? [:]
            guard map != old else { continue }
            try write(map, over: old, in: database,
                      upsert: "INSERT OR REPLACE INTO scoped (kind, scope, key, v, t, d) VALUES (?, ?, ?, ?, ?, ?)",
                      row: { key, entry in [name, .text(scope), .text(key)] + SQLiteReplicaStore.values(entry) },
                      delete: "DELETE FROM scoped WHERE kind = ? AND scope = ? AND key = ?",
                      deleteRow: { [name, .text(scope), .text($0)] })
        }
    }

    private static func values(_ entry: SyncEntry) -> [SQLiteValue] {
        [entry.v.map(SQLiteValue.text) ?? .null, .real(entry.t), .text(entry.d)]
    }

    // MARK: - what earlier Edens kept

    /// The replica an earlier Eden kept as JSON, else what the sync before
    /// CKSyncEngine agreed per scope — so a device that synced then carries
    /// on, a deletion made since not taken for an item never seen. A file
    /// that is there but can't be read throws, and stays where it is.
    private func former() throws -> Replica? {
        if let formerReplica, FileManager.default.fileExists(atPath: formerReplica.path) {
            return try JSONDecoder().decode(Replica.self, from: Data(contentsOf: formerReplica))
        }
        struct Bases: Decodable {
            var account: String?
            var bases: [String: [String: SyncEntry]]
        }
        guard let formerBases, FileManager.default.fileExists(atPath: formerBases.path) else { return nil }
        let bases = try JSONDecoder().decode(Bases.self, from: Data(contentsOf: formerBases))
        guard let account = bases.account else { return nil }
        var replica = Replica(account: account)
        replica.applied = bases.bases
        return replica
    }

    /// The former files, once what was carried over from them is in the
    /// database; tried again at the next load or commit if they can't go now.
    private func removeFormerFiles() {
        guard carriedOver, kept, let database else { return }
        let files = [formerReplica, formerBases].compactMap { $0 }
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.removeItem(at: file)
        }
        guard !files.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        if (try? database.transaction({ try noteFormer(false, in: database) })) != nil { carriedOver = false }
    }
}
