import EdenCore
import Foundation
import Observation
import WebKit

// Spaces on iPhone and iPad, as on the Mac: separate sets of tabs, each with
// its name, icon and colour, signed in where Personal is or with cookies and
// sign-ins of its own. Off unless turned on in Settings; until then there is
// one space, Personal, and nothing about it shows.
//
// The spaces are the Mac's spaces.json, by the same rules (SpacesFile); this
// device shows Personal's, and keeps any other profile's as the file has
// them. Each space keeps its tabs in a file of its own — Personal's in
// tabs.json, as before spaces, the others' beside it — and every space's tabs
// come back at launch, each page made only once it is shown. A private tab
// belongs to no space, and is never written anywhere.

/// Whose a tab is, for as long as it lives: a space's, or private. Every
/// save, close and pop-up goes by it, so a page finishing in one space after
/// another came to the front is still that space's.
enum TabOwner: Hashable {
    case space(UUID)
    case `private`
}

/// The spaces, as spaces.json keeps them: every profile's, though this
/// device shows Personal's alone.
@Observable
final class SpaceLibrary {
    /// Every profile's, repaired (SpacesFile).
    private(set) var all: [Space]
    /// Whether one has been moved: the order is the user's from then on.
    @ObservationIgnored private var orderKept: Bool
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let store: UserDefaults
    /// The file wouldn't read, or is gone though it was written: what it
    /// held isn't known, and must not be taken for nothing (Syncing).
    @ObservationIgnored private(set) var damaged = false
    /// Told when the spaces change here — never when they came from another
    /// device (adopt) — so sync sends them.
    @ObservationIgnored var changed: (() -> Void)?

    static let orderKeptKey = "spaces.orderKept"
    static let keptKey = "spaces.kept"

    /// `file`: nil keeps nothing (tests).
    init(file: URL? = Store.file("spaces.json"), store: UserDefaults = Store.settings) {
        self.file = file
        self.store = store
        orderKept = store.bool(forKey: SpaceLibrary.orderKeptKey)
        var saved: [Space] = []
        if let file {
            if let data = try? Data(contentsOf: file) {
                do { saved = try SpacesFile.decode(data) } catch {
                    Store.quarantine(file)
                    damaged = true
                }
            } else {
                damaged = store.bool(forKey: SpaceLibrary.keptKey)
            }
        }
        all = SpacesFile.spaces(from: saved, orderKept: orderKept) { _ in nil }
    }

    /// What it holds is known again (Syncing).
    func recovered() { damaged = false }

    /// Personal's spaces, in their order.
    var spaces: [Space] {
        SpacesFile.spaces(of: Space.personalProfileID, in: all, saved: all, orderKept: orderKept) { _ in nil }
    }

    func space(_ id: UUID) -> Space? { all.first { $0.id == id } }

    /// A new space, at the end.
    @discardableResult
    func add(named name: String, icon: String?, colour: Int, sharesSignIns: Bool) -> Space {
        let made = Space(id: UUID(), name: name, colour: colour, icon: icon ?? SpaceAppearance.freeIcon(among: spaces),
                         sharesSignIns: sharesSignIns)
        replace(spaces + [made])
        return made
    }

    /// One space's name, icon or colour, as `edit` leaves it. Whether it has
    /// sign-ins of its own is never changed: its store can't change under its
    /// tabs.
    func edit(_ id: UUID, _ edit: (inout Space) -> Void) {
        var list = spaces
        guard let at = list.firstIndex(where: { $0.id == id }) else { return }
        let signIns = list[at].sharesSignIns
        edit(&list[at])
        list[at].sharesSignIns = signIns
        if list[at].name.trimmingCharacters(in: .whitespaces).isEmpty { return }
        replace(list)
    }

    /// Moved to `index` among Personal's spaces; the order is the user's
    /// from then on.
    func move(_ id: UUID, to index: Int) {
        var list = spaces
        guard let from = list.firstIndex(where: { $0.id == id }), list.indices.contains(index), from != index else { return }
        list.move(fromOffsets: IndexSet(integer: from), toOffset: index > from ? index + 1 : index)
        orderKept = true
        store.set(true, forKey: SpaceLibrary.orderKeptKey)
        replace(list)
    }

    /// Gone from the list. Never the first space: it is where everything was
    /// before there were spaces.
    func remove(_ id: UUID) {
        guard id != Space.firstID else { return }
        replace(spaces.filter { $0.id != id })
    }

    /// Personal's spaces as another device left them (Syncing): not told
    /// back as a change of this device's.
    func adopt(_ spaces: [Space]) {
        guard spaces != self.spaces else { return }
        replace(spaces, told: false)
    }

    /// The file written as it is, changed or not: for sync to know it is on
    /// disk (Disk.drain(since:)).
    func save() {
        guard let file else { return }
        let all = all
        Disk.write(file) { try? SpacesFile.encode(all) }
        store.set(true, forKey: SpaceLibrary.keptKey)
    }

    private func replace(_ personal: [Space], told: Bool = true) {
        all = SpacesFile.replacing(profile: Space.personalProfileID, in: all, with: personal)
        save()
        if told { changed?() }
    }
}

/// The website stores spaces' tabs use: Personal's — the store there always
/// was — for Personal and any space signed in with it, and one of its own,
/// made by identifier, for each other. A test run never touches a real
/// space's store: its spaces get identifiers of the test world's own.
@MainActor
final class WebsiteStores {
    private var made: [UUID: WKWebsiteDataStore] = [:]
    private let settings: UserDefaults

    /// Spaces deleted whose store WebKit hasn't let go of yet, by id.
    static let erasingKey = "spaces.erasing"
    /// A test world's identifiers for its spaces' stores, by space.
    static let probeKey = "spaces.probeStores"
    /// Where a test world's spaces' identifiers start (Store.probeStore):
    /// clear of the ones its own stores use.
    private static let firstProbeKind: UInt32 = 100

    init(settings: UserDefaults = Store.settings) {
        self.settings = settings
    }

    func store(for key: SpaceStoreKey) -> WKWebsiteDataStore {
        guard case .space(let id) = key else { return Tab.ordinaryStore }
        if let store = made[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: identifier(for: id))
        made[id] = store
        return store
    }

    /// The identifier of a space's own store: its id, or in a test run one
    /// of the test world's, kept from one run to the next.
    func identifier(for space: UUID) -> UUID {
        guard Store.testing else { return space }
        var kinds = settings.dictionary(forKey: WebsiteStores.probeKey) as? [String: Int] ?? [:]
        if let kind = kinds[space.uuidString] { return Store.probeStore(UInt32(kind)) }
        let kind = Int(WebsiteStores.firstProbeKind) + kinds.count
        kinds[space.uuidString] = kind
        settings.set(kinds, forKey: WebsiteStores.probeKey)
        return Store.probeStore(UInt32(kind))
    }

    /// Every identifier a test world has given its spaces, for its fresh
    /// start to clear (EdenApp).
    static func probeIdentifiers(in settings: UserDefaults) -> [UUID] {
        let kinds = settings.dictionary(forKey: probeKey) as? [String: Int] ?? [:]
        return kinds.values.map { Store.probeStore(UInt32($0)) }
    }

    /// A deleted space's store and everything in it, gone: written down
    /// first, emptied now, and removed once WebKit lets go of it — at a
    /// later launch, if not in this one.
    func erase(_ space: UUID) {
        let identifier = identifier(for: space)
        var pending = Set(settings.stringArray(forKey: WebsiteStores.erasingKey) ?? [])
        pending.insert(identifier.uuidString)
        settings.set(pending.sorted(), forKey: WebsiteStores.erasingKey)
        if let store = made.removeValue(forKey: space) {
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
        sweep()
    }

    /// Every deleted space's store still there, tried again.
    func sweep() {
        for text in settings.stringArray(forKey: WebsiteStores.erasingKey) ?? [] {
            guard let identifier = UUID(uuidString: text), erasable(identifier) else {
                forget(text)
                continue
            }
            // Still in use: tried again once it isn't, at a later launch.
            if made.values.contains(where: { $0.identifier == identifier }) { continue }
            Task {
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                } catch {
                    // Gone already is as good as removed; anything else is
                    // tried again at the next launch.
                    guard !(await WKWebsiteDataStore.allDataStoreIdentifiers).contains(identifier) else { return }
                }
                forget(text)
            }
        }
    }

    /// Never, in a test run, a store that isn't one of its spaces'.
    private func erasable(_ identifier: UUID) -> Bool {
        guard Store.testing else { return true }
        return WebsiteStores.probeIdentifiers(in: settings).contains(identifier)
    }

    private func forget(_ text: String) {
        let left = (settings.stringArray(forKey: WebsiteStores.erasingKey) ?? []).filter { $0 != text }
        settings.set(left, forKey: WebsiteStores.erasingKey)
    }
}

extension Browser {
    /// Personal's spaces, in their order.
    var spaces: [Space] { library.spaces }

    /// The space in front.
    var space: Space { library.space(spaceID) ?? Space.first() }

    /// The tabs of the space in front, in their order.
    var spaceTabs: [Tab] { tabs.filter { $0.owner == .space(spaceID) } }

    /// The store a tab of `owner` is made with.
    func store(for owner: TabOwner) -> WKWebsiteDataStore {
        switch owner {
        case .private:
            return .nonPersistent()
        case .space(let id):
            // A space gone meanwhile never borrows Personal's sign-ins.
            guard let space = library.space(id) else { return .nonPersistent() }
            return stores.store(for: space.storeKey(profileHome: Space.firstID))
        }
    }

    /// A new space, signed in where Personal is or starting afresh with
    /// cookies and sign-ins of its own, in front.
    @discardableResult
    func addSpace(named name: String, icon: String? = nil, colour: Int = 0, sharesSignIns: Bool) -> Space {
        let made = library.add(named: name, icon: icon, colour: colour, sharesSignIns: sharesSignIns)
        // With the pins every space shows, beside an empty tab.
        pinsChanged()
        enter(made.id)
        return made
    }

    /// A space deleted on another device: deleted here as it would be here,
    /// and said if it was in front.
    func spaceDeletedElsewhere(_ space: Space) {
        let inFront = spaceID == space.id
        deleteSpace(space.id)
        if inFront { announce("“\(space.name)” was deleted on another device") }
    }

    /// Spaces turned off: back to Personal. The others keep their tabs,
    /// files and sign-ins, for when they are turned on again.
    func leaveSpaces() {
        enter(Space.firstID)
        // A shared pin in front waits with the others, out of sight.
        if let tab = active, tab.pin != nil, !shownPins.contains(where: { $0.tab === tab }) {
            if let loose = looseTabs.last { select(loose) } else { newTab() }
        }
    }
}
