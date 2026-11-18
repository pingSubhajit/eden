import EdenCore
import Foundation

// Pinned tabs are the same in every window: pinned, unpinned, moved,
// relettered or renamed in one, so they are in the others. Each window holds
// its own tab for each pin — its own page, wherever you took it — and only
// what makes the pin a pin is shared: its letter, its name, the page it was
// pinned at, its place among the pins. Per space, as the pins always were.
//
// pins.json holds them. The oldest window's session file keeps its pins as
// it always did, so 1.0.3 finds them there; the first launch of 1.0.4 takes
// them from there.
//
// Beside the spaces' pins, the ones every space shows first, while Settings ›
// Tabs › Pins in every space is on: Arc's favourites, above every space.
// The file, and how the two lists make a row, are EdenCore's (PinsFile,
// PinLists), the same on iPhone and iPad.

@MainActor
enum Pins {
    /// Pins by space, in their order.
    private(set) static var bySpace: [UUID: [PinDef]] = [:]
    /// The pins every space of a profile shows before its own (see
    /// Browser.reconcilePins), by profile.
    private static var sharedBy: [UUID: [PinDef]] = [:]
    private static var loaded = false

    /// A space's pins changed in one window; the others follow.
    static let changed = Notification.Name("EdenPinsChanged")

    private static var file: URL { Store.file("pins.json") }

    static func defs(_ space: UUID) -> [PinDef] {
        load()
        return bySpace[space] ?? []
    }

    /// The pins every space of a profile shows, in their order.
    static func shared(_ profile: UUID) -> [PinDef] {
        load()
        return sharedBy[profile] ?? []
    }

    /// Read once. Before there is a pins.json, the pins are the oldest
    /// window's, from its session files — every space's.
    static func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: file), let saved = try? PinsFile.decode(data) {
            bySpace = saved.bySpace
            sharedBy = saved.sharedByProfile
            return
        }
        for space in Spaces.read() {
            let defs = Session.read(space: space.id).tabs.compactMap { entry -> PinDef? in
                guard let letter = entry.pin else { return nil }
                return PinDef(id: entry.pinID ?? UUID(), letter: letter, home: entry.home ?? entry.url,
                              title: entry.title, name: entry.name)
            }
            if !defs.isEmpty { bySpace[space.id] = defs }
        }
        save()
    }

    /// A window's pins for a space, as they now are: kept, written, and
    /// passed to the other windows when they differ from what was there.
    static func set(_ space: UUID, _ defs: [PinDef], from browser: Browser) {
        load()
        guard (bySpace[space] ?? []) != defs else { return }
        bySpace[space] = defs.isEmpty ? nil : defs
        save()
        NotificationCenter.default.post(name: changed, object: browser, userInfo: ["space": space])
    }

    /// The shared pins as they now are, passed to the other windows, which
    /// take them into every space they hold. True when they changed.
    @discardableResult
    static func setShared(_ defs: [PinDef], from browser: Browser) -> Bool {
        load()
        let profile = browser.profileID
        guard (sharedBy[profile] ?? []) != defs else { return false }
        sharedBy[profile] = defs.isEmpty ? nil : defs
        save()
        NotificationCenter.default.post(name: changed, object: browser, userInfo: ["shared": true, "profile": profile])
        return true
    }

    /// Pins as another device left them (see Sync.swift): each of `spaces`
    /// given its list and the profile its shared one, and every window
    /// told of what changed, as when another window changes them.
    static func adopt(_ defs: [UUID: [PinDef]], in spaces: [UUID], shared: [PinDef], profile: UUID) {
        load()
        var changed: [UUID] = []
        for space in spaces where (bySpace[space] ?? []) != (defs[space] ?? []) {
            bySpace[space] = defs[space].flatMap { $0.isEmpty ? nil : $0 }
            changed.append(space)
        }
        let sharedChanged = (sharedBy[profile] ?? []) != shared
        if sharedChanged { sharedBy[profile] = shared.isEmpty ? nil : shared }
        guard !changed.isEmpty || sharedChanged else { return }
        save()
        for space in changed {
            NotificationCenter.default.post(name: Pins.changed, object: nil, userInfo: ["space": space])
        }
        if sharedChanged {
            NotificationCenter.default.post(name: Pins.changed, object: nil, userInfo: ["shared": true, "profile": profile])
        }
    }

    /// A profile deleted: the pins its spaces all showed go with it.
    static func forgetShared(of profile: UUID) {
        load()
        guard sharedBy.removeValue(forKey: profile) != nil else { return }
        save()
    }

    /// A space deleted: its pins go with it.
    static func forget(_ space: UUID) {
        PinFolders.forget(space)
        guard bySpace.removeValue(forKey: space) != nil else { return }
        save()
    }

    private static func save() {
        let catalog = PinCatalog(bySpace: bySpace, sharedByProfile: sharedBy)
        Disk.write(file) { try? PinsFile.encode(catalog) }
    }
}
