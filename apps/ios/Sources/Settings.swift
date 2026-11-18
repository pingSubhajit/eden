import EdenCore
import Foundation
import Observation

/// The few things Eden for iPhone and iPad lets you choose, kept under the
/// same keys as the Mac's (so Phase 4 can sync them as they are): the
/// engine words go to, whether the blocker runs, and whether the page in
/// front is offered to your other devices.
@Observable
final class Settings {
    /// Where words typed in the address field are searched.
    var engine: Engine {
        didSet { store.set(engine.rawValue, forKey: Keys.engine) }
    }

    /// Ads and trackers blocked before they load (Shield). On unless turned off.
    var blocks: Bool {
        didSet { store.set(blocks, forKey: Keys.blocks) }
    }

    /// The page in front offered to your other devices with Handoff. Off
    /// unless turned on, as on the Mac: its address and title then go to
    /// them, through Apple. A page handed over from them opens whatever
    /// this says.
    var handsOff: Bool {
        didSet { store.set(handsOff, forKey: Keys.handsOff) }
    }

    @ObservationIgnored private let store: UserDefaults

    enum Keys {
        static let engine = "search.engine"
        static let blocks = "shield"
        static let handsOff = "handoff"
    }

    init(store: UserDefaults = Store.settings) {
        self.store = store
        engine = store.string(forKey: Keys.engine).flatMap(Engine.init(rawValue:)) ?? .standard
        blocks = store.object(forKey: Keys.blocks) as? Bool ?? true
        handsOff = store.bool(forKey: Keys.handsOff)
    }

    /// The search address words go to, with %s where they go.
    var searchTemplate: String { engine.template(custom: "") }
}
