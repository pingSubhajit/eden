import Foundation

// Sync between your devices through iCloud: Eden on your Macs, iPhone and
// iPad, each the same app (com.subhajit.eden.beta) in your own private
// CloudKit database. No server of ours.
//
// What travels is what the merge has always worked with (SyncMerge): a map
// of items, key → a small JSON text, each with a stamp, the device that set
// it, and a tombstone for one deleted. Each item is one record in a zone of
// Eden's in your private database (CloudKitStore), its key prefixed with
// the scope it belongs to ("app/…", "profile-<id>/…"), so each profile
// syncs on its own and settings across them all.
//
// A pass, on any device:
//   1. what changed on the server since the last pass is fetched (all of it
//      the first time) and laid over what this device knows the server holds;
//   2. each scope's items as the app has them now are stamped over what this
//      device last agreed, and merged with the server's — the same winner
//      on every device, whatever order they pass in;
//   3. what this device holds that the server doesn't is saved;
//   4. only then are the merged items handed to the app to apply and kept
//      as what this device agreed. A save that fails changes nothing here,
//      the app, and what this device agreed becomes what it holds (`held`),
//      so the next pass works out the same merge again. A scope whose items
//      changed in the app while the server was saving is neither applied nor
//      agreed: the next pass, which follows at once, takes the change in.
// What a device keeps is tied to the Apple Account it synced with: signed in
// with another, it joins that account's afresh.
//
// A deletion stays on the server as its tombstone for good, a few bytes each.
// Past SyncMerge.tombstoneLife the devices stop keeping it, but nobody takes
// it off the server: a record is deleted by its name alone, so taking off a
// tombstone could take off the item another device had just brought back.
// A device only ever deletes the items it understands (each scope says
// which): one that has no pins yet, an iPhone, carries the Mac's along and
// never turns them into tombstones.
//
// Two devices saving the same item at once may overwrite each other on the
// server; the one whose entry loses, by the merge's own rule, saves it again
// at its next pass, so they agree in the end.

/// A database that holds the items: CloudKit (CloudKitStore), or in the
/// tests one in memory.
@MainActor
public protocol CloudStore: AnyObject {
    /// Ready to sync: an account there, Eden's zone made. Throws CloudProblem.
    /// Returns who the account is, so what a device kept for one account is
    /// never used with another.
    func prepare() async throws -> String
    /// What changed on the server since `token`: every item when it is nil,
    /// or when the server has forgotten it (`reset`).
    func changes(since token: Data?) async throws -> CloudChanges
    /// Saves these items, each over what the server held.
    func save(_ entries: [String: SyncEntry]) async throws
}
// Each of them stops before its next request once its task is cancelled
// (sync turned off: CloudSync.forget).

/// The server's changes since a token, and the token to ask from next.
public struct CloudChanges: Equatable, Sendable {
    public var entries: [String: SyncEntry]
    public var token: Data?
    /// The token was too old: `entries` is every item, not only changes.
    public var reset: Bool

    public init(entries: [String: SyncEntry], token: Data?, reset: Bool = false) {
        self.entries = entries
        self.token = token
        self.reset = reset
    }
}

/// Why a pass couldn't happen, in words a person can act on.
public enum CloudProblem: Error, Equatable, Sendable {
    /// No Apple Account on this device, or iCloud turned off.
    case noAccount
    /// iCloud is restricted on this device (Screen Time, a managed device).
    case restricted
    /// This build isn't signed with iCloud: a build made without its
    /// provisioning profile.
    case notEntitled
    /// The server couldn't be reached or said no for now.
    case unavailable(String)

    public var sentence: String {
        switch self {
        case .noAccount: return "Sign in to iCloud to sync"
        case .restricted: return "iCloud is restricted on this device"
        case .notEntitled: return "This build of Eden can't use iCloud"
        case .unavailable(let why): return why
        }
    }
}

/// One scope's items: how the app reads them — handed what it last agreed,
/// for the items whose shape depends on it — applies them, and which keys it
/// understands (only those can be found missing and deleted).
public struct CloudScope {
    public let name: String
    public let current: @MainActor ([String: String]) -> [String: String]
    public let apply: @MainActor ([String: String]) -> Void
    public let understood: @MainActor (String, String) -> Bool

    public init(name: String, current: @escaping @MainActor ([String: String]) -> [String: String],
                apply: @escaping @MainActor ([String: String]) -> Void,
                understood: @escaping @MainActor (String, String) -> Bool) {
        self.name = name
        self.current = current
        self.apply = apply
        self.understood = understood
    }
}

@MainActor
public final class CloudSync {
    public enum Status: Equatable, Sendable {
        case idle
        case syncing
        case synced(Date)
        case problem(CloudProblem)
    }

    /// Where the last pass got to.
    public private(set) var status: Status = .idle {
        didSet { if status != oldValue { changed?(status) } }
    }
    /// Told whenever `status` changes.
    public var changed: ((Status) -> Void)?

    private let store: CloudStore
    private let device: String
    private let file: URL
    private var running = false
    /// The scopes of a pass asked for while one ran: it runs after, with
    /// them (a profile may have been added meanwhile).
    private var queued: [CloudScope]?
    /// Moves on when sync is turned off (`forget`): a pass begun before
    /// stops at its next step and changes nothing.
    private var generation = 0
    /// The pass running, to cancel when sync is turned off.
    private var task: Task<Void, Never>?
    /// Turned off (`forget`): this engine passes no more. Turned on again,
    /// the app makes a new one.
    private var forgotten = false
    /// What was kept, once read: a pass's own write lands on disk in the
    /// background, so the next pass doesn't read it back from there.
    private var state: State?

    /// What this device keeps between passes: the server's token, what it
    /// knows the server holds, and what it last agreed for each scope.
    struct State: Codable, Equatable {
        /// The account all of it belongs to.
        var account: String?
        var token: Data?
        var server: [String: SyncEntry] = [:]
        var bases: [String: [String: SyncEntry]] = [:]
    }

    /// `device`: this device's id, the same for every scope. `file`: where
    /// what it keeps between passes is kept.
    public init(store: CloudStore, device: String, file: URL) {
        self.store = store
        self.device = device
        self.file = file
    }

    /// One pass over `scopes`. A pass asked for while one runs runs after it,
    /// and returns at once.
    public func pass(_ scopes: [CloudScope], now: Date? = nil) async {
        guard !forgotten else { return }
        if running {
            queued = scopes
            return
        }
        running = true
        defer { running = false }
        var next: [CloudScope]? = scopes
        // A few in a row at most: an app whose items never read the same
        // twice would otherwise keep passing.
        var left = 5
        while let scopes = next, left > 0, !forgotten {
            queued = nil
            left -= 1
            let work = Task { await self.run(scopes, now: (now ?? Date()).timeIntervalSince1970) }
            task = work
            await work.value
            task = nil
            next = queued
        }
        queued = nil
    }

    /// Whether a pass is running now.
    public var isRunning: Bool { running }

    private func run(_ scopes: [CloudScope], now: Double) async {
        let started = generation
        status = .syncing
        do {
            let account = try await store.prepare()
            guard generation == started else { return }
            var state = load()
            if state.account != account {
                // Another Apple Account, or the first pass: nothing kept for
                // one belongs with the other.
                state = State(account: account)
            }
            let changes = try await store.changes(since: state.token)
            guard generation == started else { return }
            if changes.reset { state.server = [:] }
            state.server.merge(changes.entries) { _, theirs in theirs }

            struct Plan {
                let scope: CloudScope
                let agreed: [String: String]
                let current: [String: String]
                let merged: [String: SyncEntry]
            }
            var plans: [Plan] = []
            var save: [String: SyncEntry] = [:]
            for scope in scopes {
                let prefix = scope.name + "/"
                let theirs = Dictionary(uniqueKeysWithValues: state.server.compactMap { key, entry in
                    key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), entry) : nil
                })
                // No map at all when the server holds nothing for the scope: a
                // first pass then stamps this device's items as they are, rather
                // than as joining others (SyncMerge.pass), there being none.
                let agreed = SyncMerge.live(state.bases[scope.name] ?? [:])
                let current = scope.current(agreed)
                let merged = SyncMerge.pass(current: current, base: state.bases[scope.name],
                                            theirs: theirs.isEmpty ? [] : [theirs],
                                            device: device, now: now, understood: scope.understood)
                for (key, entry) in merged where theirs[key] != entry { save[prefix + key] = entry }
                plans.append(Plan(scope: scope, agreed: agreed, current: current, merged: merged))
            }

            // In batches, each a chance to stop once sync is turned off.
            let saving = Array(save)
            do {
                for start in stride(from: 0, to: saving.count, by: CloudSync.batch) {
                    let part = saving[start..<min(start + CloudSync.batch, saving.count)]
                    try await store.save(Dictionary(uniqueKeysWithValues: part.map { ($0.key, $0.value) }))
                    guard generation == started else { return }
                }
            } catch {
                // Some of it may be on the server, none of it is applied here:
                // what is agreed is what this device holds, so an edit made
                // before the next pass is stamped above what was sent. The
                // token stays, so the next pass asks again.
                if generation == started {
                    for plan in plans {
                        state.bases[plan.scope.name] = CloudSync.held(plan.current, merged: plan.merged,
                                                                      base: state.bases[plan.scope.name], device: device)
                    }
                    keep(state)
                }
                throw error
            }
            state.server.merge(save) { _, mine in mine }
            state.token = changes.token

            for plan in plans {
                if plan.scope.current(plan.agreed) == plan.current {
                    state.bases[plan.scope.name] = plan.merged
                    plan.scope.apply(SyncMerge.live(plan.merged))
                } else {
                    // Changed while the server was saving: applying now would
                    // undo that change. What is agreed is what this device
                    // holds: its own items as saved, so a change made since is
                    // stamped above them; and where another device's item won
                    // but isn't here yet, this device's item as it was, stamped
                    // under it, so it still arrives. The pass that follows, at
                    // once, takes both in.
                    state.bases[plan.scope.name] = CloudSync.held(plan.current, merged: plan.merged,
                                                                  base: state.bases[plan.scope.name], device: device)
                    if queued == nil { queued = scopes }
                }
            }
            keep(state)
            status = .synced(Date(timeIntervalSince1970: now))
        } catch is CancellationError {
            // Turned off: nothing to say.
        } catch let problem as CloudProblem {
            if generation == started { status = .problem(problem) }
        } catch {
            if generation == started { status = .problem(.unavailable(error.localizedDescription)) }
        }
    }

    /// Items a request carries at most (CloudKit takes 400).
    static let batch = 400

    /// What a device agreed for a scope it didn't apply: `merged` where it
    /// holds the same, else what it held (`current`), stamped as before or,
    /// new, under any other device's.
    static func held(_ current: [String: String], merged: [String: SyncEntry], base: [String: SyncEntry]?,
                     device: String) -> [String: SyncEntry] {
        var out: [String: SyncEntry] = [:]
        for (key, entry) in merged where entry.v == current[key] { out[key] = entry }
        for (key, value) in current where out[key] == nil {
            if let before = base?[key], before.v == value {
                out[key] = before
            } else {
                out[key] = SyncEntry(v: value, t: 0, d: device)
            }
        }
        return out
    }

    /// What was kept, or nothing for a device that never synced: its first
    /// pass joins, the server's items winning where both have one.
    private func load() -> State {
        if let state { return state }
        guard let data = try? Data(contentsOf: file) else { return State() }
        guard let read = try? JSONDecoder().decode(State.self, from: data) else {
            Store.quarantine(file)
            return State()
        }
        state = read
        return read
    }

    private func keep(_ kept: State) {
        state = kept
        Disk.write(file) { try? JSONEncoder().encode(kept) }
    }

    /// Everything this device kept about syncing gone, and this engine
    /// stopped: turned on again, a new one's first pass joins afresh.
    public func forget() {
        forgotten = true
        generation += 1
        task?.cancel()
        queued = nil
        state = nil
        Disk.remove(file)
        status = .idle
    }
}
