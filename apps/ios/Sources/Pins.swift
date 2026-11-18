import EdenCore
import Foundation
import Observation

// Pins on iPhone and iPad, as on the Mac: a tab kept at the head of its
// space, with its letter, its name and the page it was pinned at — its home.
// What makes a pin a pin is kept in the Mac's pins.json, by the same rules
// (PinsFile, PinLists): each space's own, and Personal's shared ones, which
// every space shows first while spaces are on.
//
// Each space has its own tab for each pin it shows, wherever you took it: a
// shared pin opened in Work is Work's, with Work's sign-ins, and Personal's
// stays where it was. Closing a pin rests it — its page let go, back to its
// home when it is next shown if Settings › Return Pins Home is on — and
// unpinning keeps the page, as an ordinary tab.

/// pins.json: what every pin is.
@Observable
final class PinStore {
    private(set) var catalog: PinCatalog
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let store: UserDefaults
    /// The file wouldn't read, or is gone though it was written: what it
    /// held isn't known, and must not be taken for nothing (Syncing).
    @ObservationIgnored private(set) var damaged = false
    /// Told when the pins change here — never when they came from another
    /// device (adopt) — so sync sends them.
    @ObservationIgnored var changed: (() -> Void)?

    static let keptKey = "pins.kept"

    /// `file`: nil keeps nothing (tests).
    init(file: URL? = Store.file("pins.json"), store: UserDefaults = Store.settings) {
        self.file = file
        self.store = store
        var catalog = PinCatalog()
        if let file {
            if let data = try? Data(contentsOf: file) {
                do { catalog = try PinsFile.decode(data) } catch {
                    Store.quarantine(file)
                    damaged = true
                }
            } else {
                damaged = store.bool(forKey: PinStore.keptKey)
            }
        }
        self.catalog = catalog
    }

    /// What it holds is known again (Syncing).
    func recovered() { damaged = false }

    /// Personal's shared pins.
    var shared: [PinDef] { catalog.shared(by: Space.personalProfileID) }

    /// What a space's row shows: the shared pins first while they show,
    /// then its own.
    func row(in space: UUID, showingShared: Bool) -> [PinDef] {
        PinLists.row(own: catalog.pins(of: space), shared: shared, showing: showingShared)
    }

    /// A pin, wherever it is kept.
    func def(_ id: UUID) -> PinDef? {
        shared.first { $0.id == id } ?? catalog.bySpace.values.lazy.compactMap { $0.first { $0.id == id } }.first
    }

    /// Whether `space` has the pin, shown or not: its own, or shared.
    func has(_ id: UUID, in space: UUID) -> Bool {
        catalog.pins(of: space).contains { $0.id == id } || shared.contains { $0.id == id }
    }

    func isShared(_ id: UUID) -> Bool { shared.contains { $0.id == id } }

    /// A new pin, last among the space's own.
    func add(_ def: PinDef, in space: UUID) {
        change { $0.bySpace[space, default: []].append(def) }
    }

    /// One pin as `edit` leaves it, wherever it is kept.
    func edit(_ id: UUID, _ edit: (inout PinDef) -> Void) {
        change { catalog in
            if let at = catalog.sharedByProfile[Space.personalProfileID]?.firstIndex(where: { $0.id == id }) {
                edit(&catalog.sharedByProfile[Space.personalProfileID]![at])
            }
            for space in catalog.bySpace.keys {
                if let at = catalog.bySpace[space]?.firstIndex(where: { $0.id == id }) { edit(&catalog.bySpace[space]![at]) }
            }
        }
    }

    /// A pin gone, wherever it was kept.
    func remove(_ id: UUID) {
        change { catalog in
            catalog.sharedByProfile[Space.personalProfileID]?.removeAll { $0.id == id }
            for space in catalog.bySpace.keys { catalog.bySpace[space]?.removeAll { $0.id == id } }
        }
    }

    /// One of a space's own shown by every space from now on (PinLists.share).
    func share(_ id: UUID, from space: UUID) {
        change { catalog in
            let moved = PinLists.share(id, own: catalog.pins(of: space), shared: catalog.shared(by: Space.personalProfileID))
            catalog.bySpace[space] = moved.own
            catalog.sharedByProfile[Space.personalProfileID] = moved.shared
        }
    }

    /// A shared one kept by `space` alone (PinLists.keep).
    func keep(_ id: UUID, in space: UUID) {
        change { catalog in
            let moved = PinLists.keep(id, own: catalog.pins(of: space), shared: catalog.shared(by: Space.personalProfileID))
            catalog.bySpace[space] = moved.own
            catalog.sharedByProfile[Space.personalProfileID] = moved.shared
        }
    }

    /// A row's pins in a new order: each list keeps its own, in the row's.
    func reorder(_ row: [UUID], in space: UUID) {
        change { catalog in
            let place = Dictionary(row.enumerated().map { ($1, $0) }) { first, _ in first }
            func ordered(_ defs: [PinDef]) -> [PinDef] {
                defs.enumerated().sorted { (place[$0.element.id] ?? Int.max, $0.offset) < (place[$1.element.id] ?? Int.max, $1.offset) }
                    .map(\.element)
            }
            catalog.bySpace[space] = ordered(catalog.pins(of: space))
            catalog.sharedByProfile[Space.personalProfileID] = ordered(catalog.shared(by: Space.personalProfileID))
        }
    }

    /// A deleted space's own pins gone with it; the shared ones stay.
    func forget(space: UUID) {
        change { $0.bySpace[space] = nil }
    }

    /// The pins as another device left them (Syncing): each of `spaces`
    /// given its list, and Personal its shared one; not told back as a
    /// change of this device's.
    func adopt(_ bySpace: [UUID: [PinDef]], in spaces: [UUID], shared: [PinDef]) {
        change(told: false) { catalog in
            for space in spaces { catalog.bySpace[space] = bySpace[space] }
            catalog.sharedByProfile[Space.personalProfileID] = shared
        }
    }

    /// The file written as it is, changed or not: for sync to know it is on
    /// disk (Disk.drain(since:)).
    func save() {
        guard let file else { return }
        let written = catalog
        Disk.write(file) { try? PinsFile.encode(written) }
        store.set(true, forKey: PinStore.keptKey)
    }

    private func change(told: Bool = true, _ edit: (inout PinCatalog) -> Void) {
        var next = catalog
        edit(&next)
        for (space, defs) in next.bySpace where defs.isEmpty { next.bySpace[space] = nil }
        for (profile, defs) in next.sharedByProfile where defs.isEmpty { next.sharedByProfile[profile] = nil }
        guard next != catalog else { return }
        catalog = next
        save()
        if told { changed?() }
    }
}

extension PinDef {
    /// The letter a page's pin starts with: its site's first.
    static func letter(for url: URL) -> String {
        String((url.host().map(Address.withoutWWW) ?? "•").prefix(1)).uppercased()
    }

    /// What it is called: the name given it, else its page's title, else
    /// its site.
    var label: String {
        if let name, !name.isEmpty { return name }
        if !title.isEmpty { return title }
        return URL(string: home).flatMap { $0.host().map(Address.withoutWWW) } ?? home
    }

    var homeURL: URL? { URL(string: home) }
}

/// A pin as one space shows it: what it is, and that space's tab for it.
struct ShownPin: Identifiable {
    let def: PinDef
    let tab: Tab
    let shared: Bool
    var id: UUID { def.id }
    /// Off its home page, somewhere it was taken since.
    var wandered: Bool { !Browser.samePage(def.homeURL, tab.url) }
}

extension Browser {
    /// The space in front's pins, in their order, each with its tab.
    var shownPins: [ShownPin] { shownPins(in: spaceID) }

    func shownPins(in space: UUID) -> [ShownPin] {
        let mine = tabs.filter { $0.owner == .space(space) && $0.pin != nil }
        return pins.row(in: space, showingShared: settings.usesSpaces).compactMap { def in
            mine.first { $0.pin == def.id }.map { ShownPin(def: def, tab: $0, shared: pins.isShared(def.id)) }
        }
    }

    /// The space in front's tabs that aren't pins.
    var looseTabs: [Tab] { spaceTabs.filter { $0.pin == nil } }

    /// The pin a tab is, if it is one.
    func pinDef(of tab: Tab) -> PinDef? { tab.pin.flatMap(pins.def) }

    /// The same page, give or take a trailing slash.
    static func samePage(_ one: URL?, _ other: URL?) -> Bool {
        guard let one, let other else { return false }
        func bare(_ url: URL) -> String {
            var text = url.absoluteString
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return bare(one) == bare(other)
    }

    /// Whether a tab's page can be pinned: an ordinary tab, on a web page.
    func canPin(_ tab: Tab) -> Bool {
        !tab.isPrivate && tab.pin == nil && Continuity.page(tab.url) != nil
    }
}
