import EdenCore
import Foundation

// What stands in for iCloud in tests of sync, here and in the apps': the
// server and each device's transport, in memory.


/// The iCloud server, played in memory for CloudSync's tests: records with
/// change tags, a save over a stale tag refused with the server's version
/// (as CKSyncEngine reports .serverRecordChanged), changes fetched since a
/// device's token. Devices are SimulatedTransports sharing one.
@MainActor
public final class SimulatedServer {
    public struct Record {
        public var entry: SyncEntry
        public var tag: Int
        public var revision: Int
    }

    public var records: [String: Record] = [:]
    public var account = "someone"
    /// Every request refused, as when there is no account.
    public var refusal: CloudProblem?
    /// Saves refused once this many more have been taken.
    public var savesBeforeFailing: Int?
    /// Run as the next save reaches the server: the app changing meanwhile.
    public var duringSave: (() -> Void)?
    /// Eden's zone deleted from iCloud's settings: the next fetch says so.
    public var zoneErased = false
    public private(set) var saves = 0
    private var revision = 0
    private var tags = 0

    public var latest: Int { revision }

    public init() {}

    public func value(_ key: String) -> String? { records[key]?.entry.v }

    public func item(_ key: String) -> ServerItem? {
        records[key].map { ServerItem(entry: $0.entry, tag: Data(String($0.tag).utf8)) }
    }

    public func changes(since token: Int) -> [String: ServerItem] {
        var out: [String: ServerItem] = [:]
        for (key, record) in records where record.revision > token { out[key] = item(key) }
        return out
    }

    /// A save over `tag`: taken, or refused with what the server holds.
    public func save(_ key: String, _ entry: SyncEntry, over tag: Data?) -> Result<ServerItem, SaveRefusal> {
        let sent = tag.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
        if let held = records[key], sent != held.tag, let item = item(key) { return .failure(.changed(item)) }
        if records[key] == nil, sent != nil { return .failure(.gone) }
        saves += 1
        revision += 1
        tags += 1
        records[key] = Record(entry: entry, tag: tags, revision: revision)
        return .success(item(key)!)
    }

    public enum SaveRefusal: Error {
        case changed(ServerItem)
        case gone
    }
}

/// One device's connection to the simulated server, standing in for
/// CKSyncEngine: a token, the items waiting to be sent, and the events.
@MainActor
public final class SimulatedTransport: SyncTransport {
    public weak var delegate: SyncTransportDelegate?
    public let server: SimulatedServer
    public var token = 0
    public private(set) var pending: Set<String> = []
    public private(set) var running = false
    public private(set) var zonesMade = 0

    public init(server: SimulatedServer) {
        self.server = server
    }

    public func account() async throws -> String {
        if let refusal = server.refusal { throw refusal }
        return server.account
    }

    public func start(checkpoint: Data?) {
        token = checkpoint.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        running = true
    }

    public func makeZone() {
        zonesMade += 1
        delegate?.transport(.zoneMade)
    }

    public func queue(_ keys: [String]) {
        pending.formUnion(keys)
    }

    public func fetch() async throws {
        guard running else { return }
        if let refusal = server.refusal { throw refusal }
        delegate?.transport(.fetching(true))
        if server.zoneErased {
            delegate?.transport(.zoneLost(.erased))
            return
        }
        let changes = server.changes(since: token)
        token = server.latest
        delegate?.transport(.fetched(changes, removed: []))
        delegate?.transport(.checkpoint(Data(String(token).utf8)))
        delegate?.transport(.fetching(false))
    }

    public func send() async throws {
        guard running else { return }
        if let refusal = server.refusal { throw refusal }
        guard !pending.isEmpty else { return }
        delegate?.transport(.sending(true))
        var saved: [String: ServerItem] = [:]
        var conflicted: [String: ServerItem] = [:]
        var untagged: [String] = []
        var failed: [String] = []
        for key in pending.sorted() {
            // Stopped part-way: nothing more reaches the server.
            guard running else { break }
            guard let outgoing = delegate?.outgoing(recordName: Replica.recordName(key)) else {
                pending.remove(key)
                continue
            }
            if let left = server.savesBeforeFailing {
                if left == 0 {
                    // Not retried by the engine: no longer pending.
                    failed.append(key)
                    pending.remove(key)
                    continue
                }
                server.savesBeforeFailing = left - 1
            }
            if let during = server.duringSave {
                server.duringSave = nil
                during()
                guard running else { break }
            }
            switch server.save(key, outgoing.entry, over: outgoing.tag) {
            case .success(let item): saved[key] = item
            case .failure(.changed(let item)): conflicted[key] = item
            case .failure(.gone): untagged.append(key)
            }
            pending.remove(key)
        }
        guard running else { return }
        if !saved.isEmpty { delegate?.transport(.saved(saved)) }
        if !conflicted.isEmpty { delegate?.transport(.conflicted(conflicted)) }
        if !untagged.isEmpty { delegate?.transport(.untagged(untagged)) }
        if !failed.isEmpty { delegate?.transport(.failed(failed, .unavailable("offline"))) }
        delegate?.transport(.sending(false))
        if !failed.isEmpty { throw CloudProblem.unavailable("offline") }
        // A conflict lost or won, and sent again: the engine carries on.
        if !pending.isEmpty, failed.isEmpty { try await send() }
    }

    public func stop() {
        running = false
    }
}
