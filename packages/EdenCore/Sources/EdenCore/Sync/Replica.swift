import CryptoKit
import Foundation

// What one device knows about syncing, kept apart so that no event can be
// mistaken for another (CloudSync drives it; nothing here touches CloudKit):
//
//   server    every item as the server last said it holds it, with the
//             server's own metadata for it — the change tag a save over it
//             must carry, so a save never silently overwrites one it hasn't
//             seen;
//   outgoing  edits made on this device and not yet taken by the server,
//             each with the stamp it got when it was made, sent as many
//             times as it takes with that same stamp;
//   applied   per scope, what the browser holds, in the merge's terms: what
//             the last projection gave it, with every local edit since laid
//             over. A local edit is the difference between the browser's
//             items now and this;
//   projecting  per scope, what is being given to the browser right now:
//             written down before the browser's stores change, so a crash
//             between their writes and this file's is finished on the next
//             launch rather than taken for local edits;
//   blocked   items whose record on the server this build can't read (a
//             newer Eden's): never overwritten from here;
//   checkpoint  the sync engine's own state (its change tokens), committed
//             with the rest (ReplicaStore), so it never runs ahead of the items.
//
// Items live under full keys, "<scope>/<key>" ("app/set:search.engine",
// "profile-<id>/bm:<id>"), one record each on the server. The merge itself —
// stamps, the winner between two versions, deletions as tombstones, the
// joining rule, items a device carries without understanding them — is
// SyncMerge's, unchanged from the folder sync it began as.

/// An item as the server holds it, and the server's metadata for it.
public struct ServerItem: Codable, Equatable, Sendable {
    public var entry: SyncEntry
    /// The record's archived system fields (its change tag), opaque here.
    public var tag: Data?

    public init(entry: SyncEntry, tag: Data?) {
        self.entry = entry
        self.tag = tag
    }
}

public struct Replica: Codable, Equatable, Sendable {
    /// The Apple Account all of this belongs to (CloudKit's user record
    /// name). Another account starts from nothing.
    public var account: String?
    /// The sync engine's state, encoded; nil before it first said.
    public var checkpoint: Data?
    /// The first full fetch for this account has finished: until then the
    /// server's items aren't all known, so nothing is applied and nothing
    /// worked out as a local edit.
    public var fetched = false
    /// Eden's zone is known to exist on the server.
    public var zoneMade = false
    public var server: [String: ServerItem] = [:]
    public var outgoing: [String: SyncEntry] = [:]
    public var applied: [String: [String: SyncEntry]] = [:]
    public var projecting: [String: [String: SyncEntry]] = [:]
    public var blocked: Set<String> = []

    public init(account: String? = nil) {
        self.account = account
    }

    // MARK: - keys

    public static func full(_ scope: String, _ key: String) -> String { scope + "/" + key }

    /// The scope and the key within it of a full key.
    public static func split(_ full: String) -> (scope: String, key: String)? {
        guard let slash = full.firstIndex(of: "/") else { return nil }
        return (String(full[..<slash]), String(full[full.index(after: slash)...]))
    }

    /// A record's name: a hash of its full key, which can be longer than
    /// CloudKit lets a name be.
    public static func recordName(_ full: String) -> String {
        SHA256.hash(data: Data(full.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Deletions past SyncMerge.tombstoneLife forgotten here: they count for
    /// nothing in the merge, and the server keeps them for good, so a save
    /// over one later is refused with the server's version and goes again.
    public mutating func prune(now: Double) {
        let expired = server.filter { key, item in
            item.entry.v == nil && item.entry.t < now - SyncMerge.tombstoneLife && outgoing[key] == nil
        }.keys
        for key in expired { server[key] = nil }
    }

    /// Every full key this device knows of, on the server or waiting to go.
    public var keys: Set<String> { Set(server.keys).union(outgoing.keys) }

    private func entries(in scope: String) -> [String: SyncEntry] {
        let prefix = scope + "/"
        var out: [String: SyncEntry] = [:]
        for (full, item) in server where full.hasPrefix(prefix) { out[String(full.dropFirst(prefix.count))] = item.entry }
        return out
    }

    private func edits(in scope: String) -> [String: SyncEntry] {
        let prefix = scope + "/"
        var out: [String: SyncEntry] = [:]
        for (full, entry) in outgoing where full.hasPrefix(prefix) { out[String(full.dropFirst(prefix.count))] = entry }
        return out
    }

    // MARK: - account

    /// This replica for `account`: kept when it is the same account, started
    /// afresh — nothing of the other's carried over — when it isn't. Whether
    /// it started afresh.
    @discardableResult
    public mutating func bind(to account: String) -> Bool {
        guard self.account != account else { return false }
        self = Replica(account: account)
        return true
    }

    /// Everything known about the server forgotten, as after the server's
    /// data was reset: this device joins again with what it holds.
    public mutating func rejoin() {
        let account = account
        self = Replica(account: account)
    }

    // MARK: - local edits

    /// A scope's items as the browser has them now, taken in: what changed
    /// since `applied` is stamped as an edit and waits to be sent, unless
    /// the server already holds a newer version of it. `owns` says which of
    /// the scope's items this device may find missing and so delete. A scope
    /// never applied joins: where the server has items for it, the browser's
    /// are stamped under them (SyncMerge's joining rule). The full keys now
    /// waiting to be sent.
    public mutating func capture(scope: String, snapshot: [String: String], owns: (String, String) -> Bool,
                                 device: String, now: Double) -> [String] {
        let base = applied[scope]
        let theirs = SyncMerge.prune(entries(in: scope), now: now)
        let mine = edits(in: scope)
        let seen = max(theirs.values.map(\.t).max() ?? 0, mine.values.map(\.t).max() ?? 0)
        let stamped = SyncMerge.stamp(current: snapshot, base: base ?? [:], device: device, now: now,
                                      joining: base == nil && !theirs.isEmpty, seen: seen, understood: owns)
        var queued: [String] = []
        for (key, entry) in stamped where base?[key] != entry {
            let full = Replica.full(scope, key)
            // A record this build can't read is a newer Eden's: left alone.
            if blocked.contains(full) { continue }
            if let held = theirs[key], !SyncMerge.wins(entry, over: held) {
                // The server has a newer version: this one gives way to it
                // at the projection that follows.
                outgoing[full] = nil
                continue
            }
            outgoing[full] = entry
            queued.append(full)
        }
        applied[scope] = stamped
        return queued.sorted()
    }

    // MARK: - what the browser should hold

    /// A scope's items as every device will agree on them: the server's,
    /// with this device's edits not yet taken laid over, each the winner by
    /// the merge's rule. A deletion past SyncMerge.tombstoneLife counts for
    /// nothing, coming in or going out.
    public func target(scope: String, now: Double) -> [String: SyncEntry] {
        var out = SyncMerge.prune(entries(in: scope), now: now)
        for (key, entry) in edits(in: scope) {
            if let held = out[key], !SyncMerge.wins(entry, over: held) { continue }
            out[key] = entry
        }
        return SyncMerge.prune(out, now: now)
    }

    /// The browser now holds `target` for the scope.
    public mutating func applied(_ target: [String: SyncEntry], to scope: String) {
        applied[scope] = target
    }

    // MARK: - the server's word

    /// Items fetched from the server. An edit of this device's still waiting
    /// stays waiting where it is the newer; where the server's version wins,
    /// the edit is dropped — sent now, over the server's fresh tag, it would
    /// overwrite the newer version — and the server's is applied at the next
    /// projection.
    public mutating func received(_ items: [String: ServerItem]) {
        for (full, item) in items {
            server[full] = item
            blocked.remove(full)
            if let mine = outgoing[full], !SyncMerge.wins(mine, over: item.entry) { outgoing[full] = nil }
        }
    }

    /// Records on the server this build can't read: never overwritten, and
    /// this device's edits for them dropped, until a version it can read
    /// arrives.
    public mutating func unreadable(_ fulls: [String]) {
        for full in fulls {
            blocked.insert(full)
            outgoing[full] = nil
        }
    }

    /// Records gone from the server altogether (never by Eden, which keeps
    /// deletions as tombstones). They are forgotten here; an edit of this
    /// device's for one is sent again as a new record.
    public mutating func removed(_ fulls: [String]) {
        for full in fulls { server[full] = nil }
    }

    /// Items the server took. A save clears the edit it carried; an edit made
    /// since stays waiting, now over the new tag. The full keys still waiting.
    public mutating func saved(_ items: [String: ServerItem]) -> [String] {
        var again: [String] = []
        for (full, item) in items {
            server[full] = item
            if outgoing[full] == item.entry {
                outgoing[full] = nil
            } else if outgoing[full] != nil {
                again.append(full)
            }
        }
        return again.sorted()
    }

    /// The server refused a save: it holds another version, `items`. Where
    /// this device's edit still wins, it waits to be sent again over the
    /// server's tag; where the server's wins, the edit is dropped and the
    /// server's version is applied at the next projection. The full keys to
    /// send again.
    public mutating func conflicted(_ items: [String: ServerItem]) -> [String] {
        var again: [String] = []
        for (full, item) in items {
            server[full] = item
            guard let mine = outgoing[full] else { continue }
            if SyncMerge.wins(mine, over: item.entry) {
                again.append(full)
            } else {
                outgoing[full] = nil
            }
        }
        return again.sorted()
    }

    /// The server no longer has these records although this device holds a
    /// tag for them: the tag is forgotten, so each edit is sent as a new
    /// record. The full keys to send again.
    public mutating func untagged(_ fulls: [String]) -> [String] {
        for full in fulls { server[full] = nil }
        return fulls.filter { outgoing[$0] != nil }.sorted()
    }

    /// The record to send for a full key: the edit waiting and the server's
    /// tag for it. Nil when nothing waits.
    public func outgoing(for full: String) -> (entry: SyncEntry, tag: Data?)? {
        guard let entry = outgoing[full], !blocked.contains(full) else { return nil }
        return (entry, server[full]?.tag)
    }
}
