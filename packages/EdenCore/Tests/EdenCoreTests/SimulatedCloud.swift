import Foundation
@testable import EdenCore

/// The iCloud server, played in memory for CloudSync's tests: records with
/// change tags, a save over a stale tag refused with the server's version
/// (as CKSyncEngine reports .serverRecordChanged), changes fetched since a
/// device's token. Devices are SimulatedTransports sharing one.
@MainActor
final class SimulatedServer {
    struct Record {
        var entry: SyncEntry
        var tag: Int
        var revision: Int
    }

    var records: [String: Record] = [:]
    var account = "someone"
    /// Every request refused, as when there is no account.
    var refusal: CloudProblem?
    /// Saves refused once this many more have been taken.
    var savesBeforeFailing: Int?
    /// Run as the next save reaches the server: the app changing meanwhile.
    var duringSave: (() -> Void)?
    /// Eden's zone deleted from iCloud's settings: the next fetch says so.
    var zoneErased = false
    private(set) var saves = 0
    private var revision = 0
    private var tags = 0

    var latest: Int { revision }

    func value(_ key: String) -> String? { records[key]?.entry.v }

    func item(_ key: String) -> ServerItem? {
        records[key].map { ServerItem(entry: $0.entry, tag: Data(String($0.tag).utf8)) }
    }

    func changes(since token: Int) -> [String: ServerItem] {
        var out: [String: ServerItem] = [:]
        for (key, record) in records where record.revision > token { out[key] = item(key) }
        return out
    }

    /// A save over `tag`: taken, or refused with what the server holds.
    func save(_ key: String, _ entry: SyncEntry, over tag: Data?) -> Result<ServerItem, SaveRefusal> {
        let sent = tag.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
        if let held = records[key], sent != held.tag, let item = item(key) { return .failure(.changed(item)) }
        if records[key] == nil, sent != nil { return .failure(.gone) }
        saves += 1
        revision += 1
        tags += 1
        records[key] = Record(entry: entry, tag: tags, revision: revision)
        return .success(item(key)!)
    }

    enum SaveRefusal: Error {
        case changed(ServerItem)
        case gone
    }
}

/// One device's connection to the simulated server, standing in for
/// CKSyncEngine: a token, the items waiting to be sent, and the events.
@MainActor
final class SimulatedTransport: SyncTransport {
    weak var delegate: SyncTransportDelegate?
    let server: SimulatedServer
    var token = 0
    private(set) var pending: Set<String> = []
    private(set) var running = false
    private(set) var zonesMade = 0

    init(server: SimulatedServer) {
        self.server = server
    }

    func account() async throws -> String {
        if let refusal = server.refusal { throw refusal }
        return server.account
    }

    func start(checkpoint: Data?) {
        token = checkpoint.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        running = true
    }

    func makeZone() {
        zonesMade += 1
        delegate?.transport(.zoneMade)
    }

    func queue(_ keys: [String]) {
        pending.formUnion(keys)
    }

    func fetch() async throws {
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

    func send() async throws {
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

    func stop() {
        running = false
    }
}

/// A device in the tests: one scope ("app") of plain items, its transport,
/// its sync, and a clock it is told.
@MainActor
final class Device: SyncScope {
    final class Clock {
        var now: Double = 0
    }

    let name = "app"
    var items: [String: String]
    var isReady = true
    /// What it was last given, items it carries included.
    private(set) var given: [String: String] = [:]
    /// Run inside `apply`, as an app's own observers would.
    var whileApplying: (() -> Void)?
    /// Where `persist` writes what it holds, through Disk, as the apps' stores do.
    var store: URL?
    let transport: SimulatedTransport
    let sync: CloudSync
    let clock = Clock()
    private let owner: (String) -> Bool

    init(_ id: String, server: SimulatedServer, items: [String: String] = [:], folder: URL,
         legacy: URL? = nil, owns: @escaping (String) -> Bool = { _ in true }) {
        self.items = items
        owner = owns
        transport = SimulatedTransport(server: server)
        let clock = self.clock
        sync = CloudSync(transport: transport, device: id, file: folder.appendingPathComponent("\(id).json"),
                         legacyFile: legacy, clock: { Date(timeIntervalSince1970: clock.now) })
        sync.scopes = [self]
    }

    func snapshot(agreed: [String: String]) -> [String: String] { items }

    func owns(_ key: String, _ text: String) -> Bool { owner(key) }

    func apply(_ live: [String: String]) {
        given = live
        // As the apps do: take what is agreed, of what this device keeps.
        items = live.filter { owner($0.key) }
        whileApplying?()
    }

    func persist() {
        guard let store else { return }
        let held = items
        Disk.write(store) { try? JSONEncoder().encode(held) }
        Disk.drain()
    }

    func pass(at now: Double) async {
        clock.now = now
        await sync.refresh()
    }
}
