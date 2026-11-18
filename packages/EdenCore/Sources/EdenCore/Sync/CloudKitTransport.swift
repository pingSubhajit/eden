import CloudKit
import Foundation
import os
#if os(macOS)
import Security
#endif

// The iCloud server, through Apple's CKSyncEngine: it keeps the change
// tokens, batches and retries what is sent, schedules syncing (pushes from
// the subscription it keeps, the app coming forward, the system's own
// timing), and tells of account changes. Eden's part is only turning its
// events into TransportEvents for CloudSync, and records to send out of
// what CloudSync answers.
//
// On the server: Eden's zone in your private database, one record of type
// "Item" per item (ItemRecord), named by a hash of the item's full key,
// with the key, the merge's value, stamp and device as fields. Saves go
// over the server's change tag (the record's system fields, kept with each
// item), so one never silently overwrites a version it hasn't seen.

@MainActor
public final class CloudKitTransport: SyncTransport, CKSyncEngineDelegate {
    /// Eden's iCloud container, the same for the Mac, iPhone and iPad.
    public nonisolated static let container = "iCloud.com.subhajit.eden.beta"
    nonisolated static let zoneID = CKRecordZone.ID(zoneName: "Eden", ownerName: CKCurrentUserDefaultName)
    /// The engine's own subscription, which brings a push when another
    /// device changes something.
    nonisolated static let subscriptionID = "eden-sync"
    /// What the sync before CKSyncEngine subscribed with, deleted once.
    nonisolated static let formerSubscriptions = ["eden-changes", "eden-database"]
    /// For Console (subsystem com.subhajit.eden.beta, category CloudKit):
    /// never an item's contents.
    nonisolated static let log = Logger(subsystem: "com.subhajit.eden.beta", category: "CloudKit")

    public weak var delegate: SyncTransportDelegate?
    private let cloud: CKContainer
    private let settings: UserDefaults
    private var engine: CKSyncEngine?

    /// Only where `entitled`: CloudKit ends the app on the spot otherwise.
    public init(settings: UserDefaults = Store.settings) {
        cloud = CKContainer(identifier: CloudKitTransport.container)
        self.settings = settings
    }

    /// Whether this build may use Eden's container at all. On a Mac, a build
    /// made without its provisioning profile has no iCloud entitlement, and
    /// touching CloudKit there would end the app; an iPhone or iPad build is
    /// always signed with it.
    public nonisolated static var entitled: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        func value(_ name: String) -> CFTypeRef? { SecTaskCopyValueForEntitlement(task, name as CFString, nil) }
        let services = value("com.apple.developer.icloud-services")
        let usesCloudKit = (services as? [String])?.contains("CloudKit") == true || (services as? String) == "*"
        let containers = value("com.apple.developer.icloud-container-identifiers") as? [String]
        return usesCloudKit && containers?.contains(container) == true
        #else
        return true
        #endif
    }

    // MARK: - SyncTransport

    public func account() async throws -> String {
        do {
            switch try await cloud.accountStatus() {
            case .available: break
            case .noAccount: throw CloudProblem.noAccount
            case .restricted: throw CloudProblem.restricted
            case .couldNotDetermine, .temporarilyUnavailable: throw CloudProblem.unavailable("iCloud isn't available right now")
            @unknown default: throw CloudProblem.unavailable("iCloud isn't available right now")
            }
            return try await cloud.userRecordID().recordName
        } catch let problem as CloudProblem {
            throw problem
        } catch {
            throw CloudKitTransport.problem(error)
        }
    }

    public func start(checkpoint: Data?) {
        let state = checkpoint.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(database: cloud.privateCloudDatabase, stateSerialization: state,
                                                       delegate: self)
        configuration.subscriptionID = CloudKitTransport.subscriptionID
        engine = CKSyncEngine(configuration)
        retireFormerSubscriptions()
    }

    public func makeZone() {
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudKitTransport.zoneID))])
    }

    public func queue(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        engine?.state.add(pendingRecordZoneChanges: keys.map { .saveRecord(ItemRecord.id($0)) })
    }

    public func fetch() async throws {
        guard let engine else { return }
        do { try await engine.fetchChanges() } catch { throw CloudKitTransport.problem(error) }
    }

    public func send() async throws {
        guard let engine else { return }
        do { try await engine.sendChanges() } catch { throw CloudKitTransport.problem(error) }
    }

    public func stop() {
        let stopping = engine
        engine = nil
        Task { await stopping?.cancelOperations() }
    }

    // MARK: - CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // A stopped engine's last words are not listened to.
        guard syncEngine === engine, let delegate else { return }
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) { delegate.transport(.checkpoint(data)) }
        case .accountChange(let change):
            switch change.changeType {
            case .signIn(let user): delegate.transport(.accountChanged(user.recordName))
            case .switchAccounts(_, let user): delegate.transport(.accountChanged(user.recordName))
            case .signOut: delegate.transport(.accountChanged(nil))
            @unknown default: delegate.transport(.accountChanged(nil))
            }
        case .fetchedDatabaseChanges(let changes):
            if changes.modifications.contains(where: { $0.zoneID == CloudKitTransport.zoneID }) {
                delegate.transport(.zoneMade)
            }
            for deletion in changes.deletions where deletion.zoneID == CloudKitTransport.zoneID {
                switch deletion.reason {
                case .encryptedDataReset: delegate.transport(.zoneLost(.encryptionReset))
                case .deleted, .purged: delegate.transport(.zoneLost(.erased))
                @unknown default: delegate.transport(.zoneLost(.erased))
                }
            }
        case .fetchedRecordZoneChanges(let changes):
            var items: [String: ServerItem] = [:]
            var unreadable: [String] = []
            for modification in changes.modifications where modification.record.recordID.zoneID == CloudKitTransport.zoneID {
                if let (key, item) = ItemRecord.item(from: modification.record) {
                    items[key] = item
                } else if let key = ItemRecord.key(of: modification.record) {
                    unreadable.append(key)
                } else {
                    CloudKitTransport.log.error("a record this build can't read was left as it is")
                }
            }
            if !unreadable.isEmpty { delegate.transport(.unreadable(unreadable)) }
            let removed = changes.deletions.filter { $0.recordID.zoneID == CloudKitTransport.zoneID }.map(\.recordID.recordName)
            delegate.transport(.fetched(items, removed: removed))
        case .sentDatabaseChanges(let sent):
            if sent.savedZones.contains(where: { $0.zoneID == CloudKitTransport.zoneID }) { delegate.transport(.zoneMade) }
            for failure in sent.failedZoneSaves where failure.zone.zoneID == CloudKitTransport.zoneID {
                delegate.transport(.failed([], CloudKitTransport.problem(failure.error)))
            }
        case .sentRecordZoneChanges(let sent):
            sentRecords(sent, to: delegate)
        case .willFetchChanges: delegate.transport(.fetching(true))
        case .didFetchChanges: delegate.transport(.fetching(false))
        case .willSendChanges: delegate.transport(.sending(true))
        case .didSendChanges: delegate.transport(.sending(false))
        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges: break
        @unknown default: break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                          syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] id in
            await self?.record(for: id, in: syncEngine)
        }
    }

    /// The record to send under an ID, or nil — and no longer pending — when
    /// nothing waits under it.
    private func record(for id: CKRecord.ID, in syncEngine: CKSyncEngine) -> CKRecord? {
        guard let outgoing = delegate?.outgoing(recordName: id.recordName) else {
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
            return nil
        }
        return ItemRecord.record(outgoing)
    }

    private func sentRecords(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, to delegate: SyncTransportDelegate) {
        var saved: [String: ServerItem] = [:]
        for record in sent.savedRecords {
            if let (key, item) = ItemRecord.item(from: record) { saved[key] = item }
        }
        if !saved.isEmpty { delegate.transport(.saved(saved)) }

        var conflicted: [String: ServerItem] = [:]
        var untagged: [String] = []
        var unreadable: [String] = []
        var zoneMissing: [String] = []
        var failed: [(String, CKError)] = []
        for failure in sent.failedRecordSaves {
            guard let key = ItemRecord.key(of: failure.record) else { continue }
            switch failure.error.code {
            case .serverRecordChanged:
                if let server = failure.error.serverRecord, let (_, item) = ItemRecord.item(from: server) {
                    conflicted[key] = item
                } else {
                    // There, but not readable by this build: never overwritten.
                    unreadable.append(key)
                }
            case .unknownItem: untagged.append(key)
            case .zoneNotFound: zoneMissing.append(key)
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited:
                // Tried again by the engine on its own.
                break
            default: failed.append((key, failure.error))
            }
        }
        if !conflicted.isEmpty { delegate.transport(.conflicted(conflicted)) }
        if !untagged.isEmpty { delegate.transport(.untagged(untagged)) }
        if !unreadable.isEmpty { delegate.transport(.unreadable(unreadable)) }
        if !zoneMissing.isEmpty { delegate.transport(.zoneMissing(zoneMissing)) }
        if let first = failed.first {
            CloudKitTransport.log.error("\(failed.count, privacy: .public) saves failed: \(first.1.localizedDescription, privacy: .public)")
            delegate.transport(.failed(failed.map(\.0), CloudKitTransport.problem(first.1)))
        }
    }

    // MARK: - housekeeping

    /// The subscriptions and flags of the sync before CKSyncEngine, gone:
    /// once, as the engine keeps its own subscription.
    private func retireFormerSubscriptions() {
        let key = "cloud.former.retired"
        guard !settings.bool(forKey: key) else { return }
        for old in settings.dictionaryRepresentation().keys where old.hasPrefix("cloud.zone.ready") {
            settings.removeObject(forKey: old)
        }
        let database = cloud.privateCloudDatabase
        Task { [settings] in
            guard (try? await database.modifySubscriptions(saving: [], deleting: CloudKitTransport.formerSubscriptions)) != nil
            else { return }
            settings.set(true, forKey: key)
        }
    }

    nonisolated static func problem(_ error: Error) -> CloudProblem {
        guard let error = error as? CKError else { return .unavailable(error.localizedDescription) }
        switch error.code {
        case .notAuthenticated: return .noAccount
        case .quotaExceeded: return .unavailable("Your iCloud storage is full")
        case .networkUnavailable, .networkFailure: return .unavailable("Can't reach iCloud right now")
        default: return .unavailable(error.localizedDescription)
        }
    }
}

/// An item as a record, and back.
enum ItemRecord {
    static let type = "Item"

    static func id(_ key: String) -> CKRecord.ID {
        CKRecord.ID(recordName: Replica.recordName(key), zoneID: CloudKitTransport.zoneID)
    }

    /// The record to send: over the server's version when there is one (its
    /// system fields, so the save carries its change tag), else a new one.
    static func record(_ outgoing: OutgoingRecord) -> CKRecord {
        let id = id(outgoing.key)
        let record = outgoing.tag.flatMap(restore).flatMap { $0.recordID == id ? $0 : nil }
            ?? CKRecord(recordType: type, recordID: id)
        record["key"] = outgoing.key as NSString
        // A tombstone has no value: the field cleared, not left as it was.
        record["v"] = outgoing.entry.v.map { $0 as NSString }
        record["t"] = outgoing.entry.t as NSNumber
        record["d"] = outgoing.entry.d as NSString
        return record
    }

    /// The item in a record, with the record's system fields; nil for one
    /// this build can't read — of another type, misnamed, or with a field
    /// of the wrong kind — which is left as it is, never overwritten.
    static func item(from record: CKRecord) -> (String, ServerItem)? {
        guard record.recordType == type, let key = record["key"] as? String,
              record.recordID.recordName == Replica.recordName(key),
              let t = record["t"] as? Double, t.isFinite, t >= 0,
              let d = record["d"] as? String, !d.isEmpty else { return nil }
        let value = record["v"]
        if value != nil, !(value is String) { return nil }
        return (key, ServerItem(entry: SyncEntry(v: value as? String, t: t, d: d), tag: archive(record)))
    }

    static func key(of record: CKRecord) -> String? { record["key"] as? String }

    static func archive(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func restore(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
