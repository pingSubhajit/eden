import EdenCore
import Foundation
import Observation

/// The few things Eden for iPhone and iPad lets you choose, kept under the
/// same keys as the Mac's: the engine words go to, whether the blocker runs,
/// whether the page in front is offered to your other devices, and whether
/// Eden syncs through iCloud. The engine and the blocker sync with the
/// Mac's (Syncing), as the Mac's own settings items.
@Observable
final class Settings {
    /// Where words typed in the address field are searched.
    var engine: Engine {
        didSet {
            store.set(engine.rawValue, forKey: Keys.engine)
            if engine != oldValue { changed?() }
        }
    }

    /// The address of the Mac's custom engine, with %s where the words go:
    /// chosen there, used here when the engine is Custom.
    var customEngine: String {
        didSet {
            store.set(customEngine, forKey: Keys.customEngine)
            if customEngine != oldValue { changed?() }
        }
    }

    /// Ads and trackers blocked before they load (Shield). On unless turned off.
    var blocks: Bool {
        didSet {
            store.set(blocks, forKey: Keys.blocks)
            if blocks != oldValue { changed?() }
        }
    }

    /// The page in front offered to your other devices with Handoff. Off
    /// unless turned on, as on the Mac: its address and title then go to
    /// them, through Apple. A page handed over from them opens whatever
    /// this says.
    var handsOff: Bool {
        didSet { store.set(handsOff, forKey: Keys.handsOff) }
    }

    /// Reading mode asks a site for the Markdown copy of a page first, as the
    /// Mac can: the article as its writer gave it. Off unless turned on.
    var readsTwins: Bool {
        didSet { store.set(readsTwins, forKey: Keys.readsTwins) }
    }

    /// Tabs, bookmarks, history and these settings synced with your other
    /// devices through iCloud (Syncing). On unless turned off.
    var syncs: Bool {
        didSet { store.set(syncs, forKey: Keys.syncs) }
    }

    /// Told when a setting that syncs changes, here or from another device.
    @ObservationIgnored var changed: (() -> Void)?
    @ObservationIgnored private let store: UserDefaults

    enum Keys {
        static let engine = "search.engine"
        static let customEngine = "search.custom"
        static let blocks = "shield"
        static let handsOff = "handoff"
        static let syncs = "sync.icloud"
        static let readsTwins = "reader.twins"
    }

    init(store: UserDefaults = Store.settings) {
        self.store = store
        engine = store.string(forKey: Keys.engine).flatMap(Engine.init(rawValue:)) ?? .standard
        customEngine = store.string(forKey: Keys.customEngine) ?? ""
        blocks = store.object(forKey: Keys.blocks) as? Bool ?? true
        handsOff = store.bool(forKey: Keys.handsOff)
        syncs = store.object(forKey: Keys.syncs) as? Bool ?? true
        readsTwins = store.bool(forKey: Keys.readsTwins)
    }

    /// The search address words go to, with %s where they go: the Mac's
    /// custom one when that is the engine and it has one, else the engine's.
    var searchTemplate: String {
        engine == .custom && !customEngine.contains("%s") ? Engine.standard.template(custom: "")
            : engine.template(custom: customEngine)
    }

    // MARK: - sync

    /// The settings that sync, as the Mac's items for the same settings
    /// (SyncSettings there): the same keys, the same JSON.
    static let synced: Set<String> = ["set:" + Keys.engine, "set:" + Keys.customEngine, "set:" + Keys.blocks]

    var syncItems: [String: String] {
        var out: [String: String] = [:]
        out["set:" + Keys.engine] = SyncMerge.text(engine.rawValue)
        out["set:" + Keys.customEngine] = SyncMerge.text(customEngine)
        out["set:" + Keys.blocks] = SyncMerge.text(blocks)
        return out
    }

    /// The settings as your devices now agree on them.
    func applySynced(_ live: [String: String]) {
        if let raw = live["set:" + Keys.engine].flatMap({ SyncMerge.value(String.self, $0) }),
           let value = Engine(rawValue: raw), value != engine {
            engine = value
        }
        if let value = live["set:" + Keys.customEngine].flatMap({ SyncMerge.value(String.self, $0) }), value != customEngine {
            customEngine = value
        }
        if let value = live["set:" + Keys.blocks].flatMap({ SyncMerge.value(Bool.self, $0) }), value != blocks {
            blocks = value
        }
    }
}
