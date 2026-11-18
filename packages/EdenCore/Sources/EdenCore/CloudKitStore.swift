import CloudKit
import CryptoKit
import Foundation
#if os(macOS)
import Security
#endif

/// The items in iCloud (CloudSync): one record each, of type "Item", in a
/// zone of Eden's own in your private database, so nothing of anyone else's
/// is ever read and nobody else can read yours. A record's name is a hash of
/// its key, which can be longer than CloudKit lets a name be; the key itself
/// is a field, beside the merge's value, stamp and device.
@MainActor
public final class CloudKitStore: CloudStore {
    /// Eden's iCloud container, the same for the Mac, iPhone and iPad.
    public static let container = "iCloud.com.subhajit.eden.beta"

    private let database: CKDatabase
    private let containerID: CKContainer
    private let zone = CKRecordZone.ID(zoneName: "Eden", ownerName: CKCurrentUserDefaultName)
    private let settings: UserDefaults
    /// The zone made, and the subscription that brings a silent push when
    /// another device changes something, as far as this device knows.
    private static let zoneKey = "cloud.zone.ready"
    private static let subscriptionKey = "cloud.subscription.ready"
    private static let subscriptionID = "eden-changes"
    /// The zone was made by this prepare: a token from before belongs to a
    /// zone that is gone, so the next changes are all of them.
    private var zoneIsNew = false

    /// Only on a build signed with iCloud (see `entitled`): CloudKit ends the
    /// app on the spot otherwise.
    public init(settings: UserDefaults = Store.settings) {
        let container = CKContainer(identifier: CloudKitStore.container)
        self.containerID = container
        self.database = container.privateCloudDatabase
        self.settings = settings
    }

    /// Whether this build may use iCloud at all. On a Mac, a build made
    /// without its provisioning profile has no iCloud entitlement, and
    /// touching CloudKit there would end the app; an iPhone or iPad build is
    /// always signed with it.
    public nonisolated static var entitled: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) != nil
        #else
        return true
        #endif
    }

    public func prepare() async throws -> String {
        try Task.checkCancellation()
        switch try await containerID.accountStatus() {
        case .available: break
        case .noAccount: throw CloudProblem.noAccount
        case .restricted: throw CloudProblem.restricted
        case .couldNotDetermine, .temporarilyUnavailable: throw CloudProblem.unavailable("iCloud isn't available right now")
        @unknown default: throw CloudProblem.unavailable("iCloud isn't available right now")
        }
        // Who the account is: the zone and subscription made are that
        // account's, and so is what the device keeps (CloudSync).
        try Task.checkCancellation()
        let account = try await containerID.userRecordID().recordName
        let zoneKey = CloudKitStore.zoneKey + "." + account
        let subscriptionKey = CloudKitStore.subscriptionKey + "." + account
        if !settings.bool(forKey: zoneKey) {
            try Task.checkCancellation()
            let made = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: [])
            for (_, result) in made.saveResults { _ = try result.get() }
            settings.set(true, forKey: zoneKey)
            zoneIsNew = true
        }
        if !settings.bool(forKey: subscriptionKey) {
            let subscription = CKRecordZoneSubscription(zoneID: zone, subscriptionID: CloudKitStore.subscriptionID)
            let info = CKSubscription.NotificationInfo()
            // Silent: the app wakes and passes, nothing is shown.
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            try Task.checkCancellation()
            let made = try await database.modifySubscriptions(saving: [subscription], deleting: [])
            for (_, result) in made.saveResults { _ = try result.get() }
            settings.set(true, forKey: subscriptionKey)
        }
        self.account = account
        return account
    }

    /// The account the last prepare found.
    private var account: String?

    public func changes(since token: Data?) async throws -> CloudChanges {
        var entries: [String: SyncEntry] = [:]
        var from = zoneIsNew ? nil : token.flatMap(CloudKitStore.token(from:))
        var reset = token == nil || zoneIsNew || from == nil
        zoneIsNew = false
        while true {
            do {
                try Task.checkCancellation()
                let found = try await database.recordZoneChanges(inZoneWith: zone, since: from)
                for (_, result) in found.modificationResultsByID {
                    // A record that couldn't be fetched fails the pass: the
                    // token isn't kept, so it is asked for again next time.
                    let modification = try result.get()
                    guard let (key, entry) = CloudKitStore.entry(from: modification.record) else { continue }
                    entries[key] = entry
                }
                from = found.changeToken
                if !found.moreComing { break }
            } catch let error as CKError where error.code == .changeTokenExpired {
                // The server forgot where this device was: everything again.
                entries = [:]
                from = nil
                reset = true
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                // Deleted from iCloud's settings: made again at the next pass.
                if let account {
                    settings.set(false, forKey: CloudKitStore.zoneKey + "." + account)
                    settings.set(false, forKey: CloudKitStore.subscriptionKey + "." + account)
                }
                throw CloudProblem.unavailable("Eden's iCloud data was removed; it syncs again next time")
            }
        }
        return CloudChanges(entries: entries, token: from.flatMap(CloudKitStore.data(from:)), reset: reset)
    }

    public func save(_ entries: [String: SyncEntry]) async throws {
        let records = entries.map { key, entry in record(key, entry) }
        // CloudKit takes at most 400 records a request.
        for start in stride(from: 0, to: records.count, by: 400) {
            try Task.checkCancellation()
            let batch = Array(records[start..<min(start + 400, records.count)])
            let result = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .allKeys, atomically: false)
            for (_, outcome) in result.saveResults {
                if case .failure(let error) = outcome { throw error }
            }
        }
    }

    // MARK: - records

    private func id(for key: String) -> CKRecord.ID {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: name, zoneID: zone)
    }

    private func record(_ key: String, _ entry: SyncEntry) -> CKRecord {
        let record = CKRecord(recordType: "Item", recordID: id(for: key))
        record["key"] = key as CKRecordValue
        record["v"] = entry.v.map { $0 as CKRecordValue }
        record["t"] = entry.t as CKRecordValue
        record["d"] = entry.d as CKRecordValue
        return record
    }

    /// An item from its record, or nil for one this build can't read.
    nonisolated static func entry(from record: CKRecord) -> (String, SyncEntry)? {
        guard record.recordType == "Item", let key = record["key"] as? String,
              let t = record["t"] as? Double, let d = record["d"] as? String else { return nil }
        return (key, SyncEntry(v: record["v"] as? String, t: t, d: d))
    }

    nonisolated static func data(from token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    nonisolated static func token(from data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}
