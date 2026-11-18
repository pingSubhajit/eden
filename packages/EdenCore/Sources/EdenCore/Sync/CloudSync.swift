import Foundation

// Sync between your devices through iCloud: Eden on your Macs, iPhone and
// iPad, each the same app (com.subhajit.eden.beta) in your own private
// CloudKit database. No server of ours.
//
// The parts, each with one job:
//   SyncScope       an app's kind of data — its settings and open tabs, a
//                   profile's spaces, pins, bookmarks and history: what it
//                   holds now, which items it may delete, and taking in
//                   what every device agrees on;
//   Replica         what this device knows (the server's items, its own
//                   edits not yet sent, what each scope was last given),
//                   worked on by pure functions over SyncMerge's rules;
//   SyncTransport   the server: CloudKitTransport, which is Apple's
//                   CKSyncEngine, in the apps;
//   CloudSync       this: the replica kept on disk, the scopes captured and
//                   given what they should hold, the transport's events taken
//                   in, all on the main actor, where the browser's stores are.
//
// The order that keeps everything safe:
//   - Nothing is applied and no local edit worked out until the first full
//     fetch for the account has finished: before it, an item missing here
//     can't be told from one not yet fetched. Then each scope joins, the
//     server's items winning where both have one (SyncMerge.stamp).
//   - Before a scope is given anything, its own edits are captured, in the
//     same call with nothing awaited between: a fetch never undoes an edit
//     made a moment before. Changes the scope reports while being given
//     what it should hold are its own echo, not edits.
//   - A local edit is written down before the engine hears of it, and sent
//     with the same stamp until the server takes exactly that edit.
//   - The scope's stores are on disk before the replica says the scope
//     holds what it was given; the replica is on disk before an event is
//     acknowledged, the engine's checkpoint with it.
//   - A conflict (the server holding a version this device hadn't seen) is
//     settled by SyncMerge.wins: the edit is sent again over the server's
//     tag, or gives way.
//   - Deletions are tombstones, kept on the server for good: a record
//     deleted by name could take a restore made elsewhere with it.
//
// Turned off, a CloudSync stops for good and what it kept is deleted;
// turned on again, the app makes a new one, which joins afresh.

/// An app's kind of data, as sync sees it.
@MainActor
public protocol SyncScope: AnyObject {
    /// "app", or "profile-<id>": the items' scope on the server.
    var name: String { get }
    /// Whether the scope can say what it holds yet (a history still reading
    /// its file can't).
    var isReady: Bool { get }
    /// What the scope holds now, as items. `agreed`: what it was last given,
    /// for items whose shape depends on it.
    func snapshot(agreed: [String: String]) -> [String: String]
    /// Whether the scope speaks for an item: only those, found missing, are
    /// deleted everywhere; the rest it carries for the devices that keep them.
    func owns(_ key: String, _ text: String) -> Bool
    /// What every device now agrees the scope holds.
    func apply(_ live: [String: String])
    /// What `apply` changed, written to disk now.
    func persist()
    /// What the scope holds by every device's account, after each sync,
    /// whether or not anything changed: for what the app shows of it.
    func settled(_ live: [String: String])
}

extension SyncScope {
    public func settled(_ live: [String: String]) {}
}

@MainActor
public final class CloudSync: SyncTransportDelegate {
    public enum Status: Equatable, Sendable {
        case idle
        case syncing
        case synced(Date)
        case problem(CloudProblem)
    }

    /// Where sync is.
    public private(set) var status: Status = .idle {
        didSet { if status != oldValue { changed?(status) } }
    }
    /// Told whenever `status` changes.
    public var changed: ((Status) -> Void)?
    /// Told when sync stops on its own — Eden's data erased from iCloud — so
    /// the app turns its switch off.
    public var stoppedItself: ((CloudProblem) -> Void)?

    /// The scopes to sync. Changing them captures and gives them what they
    /// should hold.
    public var scopes: [SyncScope] = [] {
        didSet { if replica.fetched { reconcile() } }
    }

    private let transport: SyncTransport
    private let device: String
    private let file: URL
    private let legacyFile: URL?
    private let clock: () -> Date
    private var replica = Replica()
    /// Record names → full keys, worked out again once the keys change.
    private var names: [String: String]?
    private var connected = false
    private var connecting = false
    private var stopped = false
    /// Something couldn't be written to disk: syncing stops until Eden is
    /// opened again, when what is in memory is what is on disk.
    private var halted = false
    private var applying = false
    private var echoed = false
    private var fetching = false
    private var sending = false
    private var lastFetch: Date?
    private var captureSoon: DispatchWorkItem?

    /// `device`: this device's id, the same for every scope. `file`: where
    /// the replica is kept. `legacyFile`: what the sync before CKSyncEngine
    /// kept, read once so a device that synced then carries on.
    public init(transport: SyncTransport, device: String, file: URL, legacyFile: URL? = nil,
                clock: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.device = device
        self.file = file
        self.legacyFile = legacyFile
        self.clock = clock
    }

    private var now: Double { clock().timeIntervalSince1970 }

    // MARK: - running

    /// Starts: the account checked, the engine started from what was kept,
    /// and a fetch. Again after it failed (no account, say), it tries again.
    public func start() async {
        guard !connected, !connecting, !stopped, !halted else { return }
        connecting = true
        defer { connecting = false }
        transport.delegate = self
        if !loaded { load() }
        status = .syncing
        do {
            let account = try await transport.account()
            guard !stopped else { return }
            replica.bind(to: account)
            names = nil
            guard keep() else { return }
            transport.start(checkpoint: replica.checkpoint)
            connected = true
            if replica.fetched, reconcile() { queueWaiting() }
        } catch {
            report(error)
            return
        }
        await refresh()
    }

    /// Everything that changed on the server fetched, taken in, and this
    /// device's edits sent.
    public func refresh() async {
        guard connected, !stopped, !halted else { return await start() }
        do {
            try await transport.fetch()
            guard connected, !stopped else { return }
            lastFetch = clock()
            if !replica.fetched {
                replica.fetched = true
                guard keep() else { return }
            }
            // Eden's zone, made only once a fetch has said it wasn't deleted:
            // a zone you deleted is reported by the fetch (.zoneLost), and
            // sync turns off instead.
            if !replica.zoneMade { transport.makeZone() }
            // Nothing goes to the server that isn't on disk here first.
            guard reconcile() else { return }
            queueWaiting()
            if !replica.outgoing.isEmpty { try await transport.send() }
            settle()
        } catch {
            report(error)
        }
    }

    /// Something a scope holds changed here: captured a moment from now, so
    /// what changed is readable by then and changes close together go as one.
    public func localChange() {
        guard !stopped, !halted else { return }
        if applying {
            echoed = true
            return
        }
        captureSoon?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.connected, self.replica.fetched, self.reconcile(),
                      !self.replica.outgoing.isEmpty else { return }
                Task { [weak self] in try? await self?.transport.send() }
            }
        }
        captureSoon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Stops for good. `forgetting`: what was kept is deleted, so the next
    /// sync joins afresh — sync turned off.
    public func stop(forgetting: Bool) {
        stopped = true
        connected = false
        captureSoon?.cancel()
        transport.stop()
        transport.delegate = nil
        if forgetting { try? FileManager.default.removeItem(at: file) }
        status = .idle
    }

    // MARK: - scopes

    /// Every edit still waiting, not only those made since: one whose save
    /// failed in a way the engine doesn't retry, or that was never handed
    /// over, goes again — every refresh at most.
    private func queueWaiting() {
        transport.queue(replica.outgoing.keys.filter { !replica.blocked.contains($0) }.sorted())
    }

    /// Each ready scope's edits captured, and the scope given what every
    /// device will agree it holds; the replica kept, then the engine told of
    /// the edits waiting. False, with nothing handed to the engine, when the
    /// replica couldn't be written.
    @discardableResult
    private func reconcile() -> Bool {
        guard connected, replica.fetched, !stopped else { return false }
        let now = self.now
        var queued: [String] = []
        for scope in scopes where scope.isReady {
            // Given something when the app last stopped, with no word that it
            // was done: finished, before anything is taken for an edit.
            if let unfinished = replica.projecting[scope.name], !finish(scope, unfinished) { return false }
            let agreed = SyncMerge.live(replica.applied[scope.name] ?? [:])
            let snapshot = scope.snapshot(agreed: agreed)
            queued += replica.capture(scope: scope.name, snapshot: snapshot, owns: scope.owns, device: device, now: now)
            let target = replica.target(scope: scope.name, now: now)
            let live = SyncMerge.live(target)
            // What the scope holds now, items it carries included.
            if live != SyncMerge.live(replica.applied[scope.name] ?? [:]) {
                guard give(scope, target) else { return false }
            } else {
                replica.applied(target, to: scope.name)
            }
            scope.settled(live)
        }
        names = nil
        guard keep() else { return false }
        if !queued.isEmpty { transport.queue(queued) }
        if echoed {
            // What the scopes said while taking it in was their own echo;
            // anything else is caught by a capture that follows.
            echoed = false
            localChange()
        }
        settle()
        return true
    }

    /// A scope given `target`: written down first, then the scope's stores
    /// changed and on disk, then the scope marked as holding it. False, with
    /// the scope untouched, when that couldn't be written down.
    private func give(_ scope: SyncScope, _ target: [String: SyncEntry]) -> Bool {
        replica.projecting[scope.name] = target
        guard keep() else { return false }
        let mark = Disk.mark()
        applying = true
        scope.apply(SyncMerge.live(target))
        scope.persist()
        applying = false
        // The scope's files didn't all reach disk: the journal stays where it
        // is, to be given again when Eden is next opened.
        guard Disk.drain(since: mark) else {
            halt()
            return false
        }
        replica.applied(target, to: scope.name)
        replica.projecting[scope.name] = nil
        return true
    }

    /// A projection left unfinished — the app stopped, or sync halted, before
    /// the scope's files were known to be on disk — finished item by item
    /// against what the scope holds now: an item still as it was before is
    /// given its new value; one already at its new value is done; one that
    /// is neither was changed here since, and is kept, to be captured as the
    /// edit it is. Items the scope only carries take the new value.
    private func finish(_ scope: SyncScope, _ target: [String: SyncEntry]) -> Bool {
        let before = SyncMerge.live(replica.applied[scope.name] ?? [:])
        let after = SyncMerge.live(target)
        let now = scope.snapshot(agreed: before)
        var finished: [String: String] = [:]
        for key in Set(before.keys).union(after.keys).union(now.keys) {
            let ownedText = after[key] ?? before[key] ?? now[key]
            let owned = ownedText.map { scope.owns(key, $0) } ?? false
            if !owned || now[key] == after[key] || now[key] == before[key] {
                if let value = after[key] { finished[key] = value }
            } else if let value = now[key] {
                finished[key] = value
            }
        }
        // The scope's own edits since are captured after: what it is given
        // here is what it will hold, and the replica takes the target as what
        // every device agreed.
        replica.projecting[scope.name] = target
        let mark = Disk.mark()
        if finished != now {
            applying = true
            scope.apply(finished)
            scope.persist()
            applying = false
        }
        guard Disk.drain(since: mark) else {
            halt()
            return false
        }
        replica.applied(target, to: scope.name)
        replica.projecting[scope.name] = nil
        return keep()
    }

    // MARK: - the transport's events

    public func transport(_ event: TransportEvent) {
        guard !stopped, !halted else { return }
        switch event {
        case .checkpoint(let data):
            replica.checkpoint = data
            keep()
        case .accountChanged(let account):
            // The engine's first start says who is signed in: nothing changed.
            guard account != replica.account else { break }
            // What this device kept belongs to the account before: started
            // again, it binds to the new one and joins afresh.
            restart(rejoining: false)
        case .zoneMade:
            replica.zoneMade = true
            keep()
        case .zoneLost(.erased):
            stop(forgetting: true)
            status = .problem(.erased)
            stoppedItself?(.erased)
        case .zoneLost(.encryptionReset):
            restart(rejoining: true)
        case .fetched(let items, let removed):
            replica.received(items)
            let index = recordNames()
            replica.removed(removed.compactMap { index[$0] })
            names = nil
            if replica.fetched { reconcile() } else { keep() }
        case .saved(let items):
            let again = replica.saved(items)
            guard keep() else { break }
            transport.queue(again)
            settle()
        case .conflicted(let items):
            let again = replica.conflicted(items)
            guard reconcile() else { break }
            transport.queue(again)
        case .untagged(let keys):
            let again = replica.untagged(keys)
            guard keep() else { break }
            transport.queue(again)
        case .zoneMissing:
            // Gone while running: why is in the server's database changes,
            // which the refresh fetches before it would make the zone again —
            // a zone you deleted turns sync off (.zoneLost); one that simply
            // isn't there is made. Kept, so a restart asks before making it too.
            replica.zoneMade = false
            keep()
            Task { [weak self] in await self?.refresh() }
        case .unreadable(let keys):
            replica.unreadable(keys)
            keep()
        case .failed(_, let problem):
            status = .problem(problem)
        case .fetching(let on):
            fetching = on
            settle()
        case .sending(let on):
            sending = on
            settle()
        }
    }

    public func outgoing(recordName: String) -> OutgoingRecord? {
        guard !stopped, !halted, let key = recordNames()[recordName], let waiting = replica.outgoing(for: key) else { return nil }
        return OutgoingRecord(key: key, entry: waiting.entry, tag: waiting.tag)
    }

    /// The engine started again from nothing: after another account, or the
    /// server's data reset (`rejoining`: the same account, everything known
    /// about the server forgotten).
    private func restart(rejoining: Bool) {
        transport.stop()
        connected = false
        if rejoining {
            replica.rejoin()
        } else {
            replica = Replica()
        }
        names = nil
        keep()
        Task { [weak self] in await self?.start() }
    }

    private func recordNames() -> [String: String] {
        if let names { return names }
        var made: [String: String] = [:]
        for key in replica.keys { made[Replica.recordName(key)] = key }
        names = made
        return made
    }

    // MARK: - status

    private func settle() {
        guard !stopped, !halted else { return }
        if fetching || sending || !replica.outgoing.isEmpty {
            if case .problem = status, !fetching, !sending { return }
            status = .syncing
        } else if let lastFetch {
            status = .synced(lastFetch)
        }
    }

    private func report(_ error: Error) {
        guard !stopped, !halted, !(error is CancellationError) else { return }
        status = .problem(error as? CloudProblem ?? .unavailable(error.localizedDescription))
    }

    // MARK: - on disk

    private var loaded = false

    private func load() {
        loaded = true
        if let data = try? Data(contentsOf: file) {
            if let read = try? JSONDecoder().decode(Replica.self, from: data) {
                replica = read
            } else {
                Store.quarantine(file)
            }
            return
        }
        // A device that synced before CKSyncEngine: what each scope was last
        // given carries on, so a deletion made since isn't taken for an item
        // never seen. The rest is fetched afresh.
        guard let legacyFile, let data = try? Data(contentsOf: legacyFile) else { return }
        struct Legacy: Decodable {
            var account: String?
            var bases: [String: [String: SyncEntry]]
        }
        if let legacy = try? JSONDecoder().decode(Legacy.self, from: data), let account = legacy.account {
            replica = Replica(account: account)
            replica.applied = legacy.bases
        }
    }

    /// The replica on disk, whole, before anything acts on it.
    private func persist() throws {
        let data = try JSONEncoder().encode(replica)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        if let legacyFile, FileManager.default.fileExists(atPath: legacyFile.path) {
            try? FileManager.default.removeItem(at: legacyFile)
        }
    }

    /// The replica on disk; when it can't be, syncing halts (`halt`). Whether
    /// it is on disk.
    @discardableResult
    private func keep() -> Bool {
        do {
            try persist()
            return true
        } catch {
            halt()
            return false
        }
    }

    /// Something of sync's couldn't be written: nothing more is sent or taken
    /// in until Eden is opened again. What is in memory but not on disk —
    /// an edit's stamp, a journal — is never acted on; what is on disk is
    /// taken up then, as it was left.
    private func halt() {
        guard !halted else { return }
        halted = true
        connected = false
        captureSoon?.cancel()
        transport.stop()
        status = .problem(.unwritable)
    }
}
