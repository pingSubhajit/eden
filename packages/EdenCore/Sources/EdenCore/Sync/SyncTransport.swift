import Foundation

// What CloudSync needs of the iCloud server, and what it hears back. In the
// apps, CloudKitTransport: Apple's CKSyncEngine, which owns change tokens,
// batching, retries, scheduling and push notifications. In the tests, a
// simulated server shared by simulated devices. Items cross this seam as
// full keys and ServerItems; CloudKit's own types never leave the transport.

/// Why a sync couldn't happen, in words a person can act on.
public enum CloudProblem: Error, Equatable, Sendable {
    /// No Apple Account on this device, or iCloud turned off.
    case noAccount
    /// iCloud is restricted on this device (Screen Time, a managed device).
    case restricted
    /// This build isn't signed with iCloud: a build made without its
    /// provisioning profile.
    case notEntitled
    /// Eden's data was deleted from iCloud (in Settings, by you): sync is
    /// turned off rather than putting it all back.
    case erased
    /// What sync keeps couldn't be written to disk: it stops until Eden is
    /// opened again.
    case unwritable
    /// The server couldn't be reached or said no for now.
    case unavailable(String)

    public var sentence: String {
        switch self {
        case .noAccount: return "Sign in to iCloud to sync"
        case .restricted: return "iCloud is restricted on this device"
        case .notEntitled: return "This build of Eden can't use iCloud"
        case .erased: return "Eden's data was deleted from iCloud. Turn sync on to upload this device's again"
        case .unwritable: return "Eden couldn't save its sync data. Quit and reopen Eden to sync again"
        case .unavailable(let why): return why
        }
    }
}

/// How Eden's zone on the server went away.
public enum ZoneLoss: Equatable, Sendable {
    /// Deleted, or purged from iCloud's settings: your choice, honoured.
    case erased
    /// iCloud's encryption keys were reset (an account recovery): what was
    /// there can't be read, and each device puts its own back.
    case encryptionReset
}

/// What a transport reports, always on the main actor, in order.
public enum TransportEvent: Equatable, Sendable {
    /// The engine's state to keep, with the items it describes.
    case checkpoint(Data)
    /// The Apple Account changed under a running engine.
    case accountChanged(String?)
    /// Eden's zone was created on the server.
    case zoneMade
    case zoneLost(ZoneLoss)
    /// Items fetched (by full key), and records gone (by record name).
    case fetched([String: ServerItem], removed: [String])
    case saved([String: ServerItem])
    /// Saves the server refused, holding these versions instead.
    case conflicted([String: ServerItem])
    /// Saves refused because the record is gone from the server (by full key).
    case untagged([String])
    /// Saves refused because Eden's zone isn't there (by full key).
    case zoneMissing([String])
    /// Records on the server this build can't read (by full key): a newer
    /// Eden's, never to be overwritten from here.
    case unreadable([String])
    /// Saves that failed in a way the engine doesn't retry on its own.
    case failed([String], CloudProblem)
    case fetching(Bool)
    case sending(Bool)
}

/// A record's contents to send: what CloudSync answers when the transport
/// builds a batch.
public struct OutgoingRecord: Equatable, Sendable {
    public var key: String
    public var entry: SyncEntry
    public var tag: Data?

    public init(key: String, entry: SyncEntry, tag: Data?) {
        self.key = key
        self.entry = entry
        self.tag = tag
    }
}

@MainActor
public protocol SyncTransportDelegate: AnyObject {
    func transport(_ event: TransportEvent)
    /// The record to send under a record name, or nil when nothing waits
    /// under it any more.
    func outgoing(recordName: String) -> OutgoingRecord?
}

@MainActor
public protocol SyncTransport: AnyObject {
    var delegate: SyncTransportDelegate? { get set }
    /// The Apple Account to sync with, by CloudKit's name for it. Throws
    /// CloudProblem when there is none to use.
    func account() async throws -> String
    /// Starts the engine from its kept state (nil: from nothing).
    func start(checkpoint: Data?)
    /// Eden's zone, to be made on the server.
    func makeZone()
    /// These items (by full key) have edits waiting to be sent.
    func queue(_ keys: [String])
    /// Everything that changed on the server, now. Throws CloudProblem.
    func fetch() async throws
    /// Every edit waiting, now. Throws CloudProblem.
    func send() async throws
    /// Stops: nothing more is asked of the server, and nothing more is
    /// reported.
    func stop()
}
