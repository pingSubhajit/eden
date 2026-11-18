import EdenCoreTesting
import Foundation
@testable import EdenCore

/// A device's replica kept in SQLite, as in the apps, with a way to make a
/// commit fail and to see each one land.
@MainActor
final class TestStore: ReplicaStore {
    let kept: SQLiteReplicaStore
    var failsCommits = false
    var failsErasing = false
    /// Every replica committed, newest last.
    private(set) var commits: [Replica] = []

    init(url: URL, formerBases: URL? = nil) {
        kept = SQLiteReplicaStore(url: url, formerBases: formerBases)
    }

    func load() throws -> Replica? { try kept.load() }

    func commit(_ replica: Replica) throws {
        if failsCommits { throw SQLiteError(code: 13, message: "disk full") }
        try kept.commit(replica)
        commits.append(replica)
    }

    func erase() throws {
        if failsErasing { throw SQLiteError(code: 5, message: "busy") }
        try kept.erase()
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
    var file: URL?
    let transport: SimulatedTransport
    let store: TestStore
    let sync: CloudSync
    let clock = Clock()
    private let owner: (String) -> Bool

    init(_ id: String, server: SimulatedServer, items: [String: String] = [:], folder: URL,
         legacy: URL? = nil, owns: @escaping (String) -> Bool = { _ in true }) {
        self.items = items
        owner = owns
        transport = SimulatedTransport(server: server)
        store = TestStore(url: folder.appendingPathComponent("\(id).sqlite"), formerBases: legacy)
        let clock = self.clock
        sync = CloudSync(transport: transport, device: id, store: store, clock: { Date(timeIntervalSince1970: clock.now) })
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
        guard let file else { return }
        let held = items
        Disk.write(file) { try? JSONEncoder().encode(held) }
        Disk.drain()
    }

    func pass(at now: Double) async {
        clock.now = now
        await sync.refresh()
    }
}
