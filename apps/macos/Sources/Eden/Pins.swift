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
//
// The kept area's groups are kept here too, with the pins they hold (see
// Column.swift, KeptGroups.swift): per space, shared by every window, and
// passed on with Pins.changed as the pins are.

@MainActor
enum Pins {
    /// Pins by space, in their order.
    private(set) static var bySpace: [UUID: [PinDef]] = [:]
    /// The pins every space of a profile shows before its own (see
    /// Browser.reconcilePins), by profile.
    private static var sharedBy: [UUID: [PinDef]] = [:]
    private static var loaded = false
    /// Each space's kept groups, in order (KeptGroups.swift).
    private(set) static var groupsBySpace: [UUID: [TabGroup]] = [:]
    /// By space, the group each folder flattened on its way in went into,
    /// while the rows in it may not be on disk there yet (see readGroups).
    private(set) static var moved: [UUID: [UUID: UUID]] = [:]

    /// A space's pins changed in one window; the others follow.
    static let changed = Notification.Name("EdenPinsChanged")

    private static var file: URL { Store.file("pins.json") }
    private static var groupsFile: URL { Store.file(KeptGroupsFile.name) }
    private static var legacyGroupsFile: URL { Store.file(LegacyPinFolders.name) }

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
    /// window's, from its session files — every space's. The kept groups
    /// are read with them, before any window makes its rows, as taking in
    /// the folders of before may move a pin (readGroups).
    static func load() {
        guard !loaded else { return }
        loaded = true
        defer { readGroups() }
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

    /// A space's pins in the groups `into` names for theirs, as the folders
    /// of before are taken in (readGroups): kept, with no window to tell,
    /// none having made its rows from them yet.
    static func refile(_ space: UUID, into: [UUID: UUID]) {
        load()
        guard let defs = bySpace[space] else { return }
        let refiled = LegacyPinFolders.refiled(defs, into: into)
        guard refiled != defs else { return }
        bySpace[space] = refiled
        save()
    }

    // MARK: - the kept groups

    /// A space's kept groups, in order.
    static func groups(_ space: UUID) -> [TabGroup] {
        load()
        return groupsBySpace[space] ?? []
    }

    /// The kept group of that id, and the space it is kept in: nil for any
    /// other, a window's own open group among them. Which area a group is
    /// in comes from here alone (Browser.area(ofGroup:)).
    static func keptGroup(_ id: UUID) -> (space: UUID, group: TabGroup)? {
        load()
        for (space, groups) in groupsBySpace {
            if let group = groups.first(where: { $0.id == id }) { return (space, group) }
        }
        return nil
    }

    /// A space's kept groups as they now are, kept and passed to the other
    /// windows when they changed. The groups first when rows go into a new
    /// one, so the rows rebuilt for the pins find theirs.
    static func setGroups(_ space: UUID, _ groups: [TabGroup], from browser: Browser?) {
        load()
        var seen = Set<UUID>()
        let groups = groups.filter { seen.insert($0.id).inserted }
        guard (groupsBySpace[space] ?? []) != groups else { return }
        groupsBySpace[space] = groups.isEmpty ? nil : groups
        saveGroups()
        NotificationCenter.default.post(name: changed, object: browser, userInfo: ["space": space])
    }

    /// The kept groups read from disk, as the pins are first read and again
    /// whenever a test asks. kept-groups.json when it is there; before it
    /// ever was, the folders of pin-folders.json taken in once, whole: each
    /// the group of its id, so every row (PinDef.group) stays in it, its
    /// name, colour, icon and fold kept, folders once inside others
    /// flattened (LegacyPinFolders), and the moves that flattening was
    /// still waiting on honoured.
    ///
    /// Those moves are kept, in the new file, until the rows are on disk in
    /// their new groups: dropped sooner, a pins file that failed to write
    /// would leave its rows pointing at folders gone for good. Kept, the
    /// next read makes them again. The old file goes only once the new one
    /// is known to be on disk (Disk.drain(since:)); till then it is read
    /// again next time, and nothing is lost either way. A file that isn't
    /// one at all is set aside, never written over.
    static func readGroups() {
        let files = FileManager.default
        var read: KeptGroupsFile.Read?
        var migrating = false
        if let data = try? Data(contentsOf: groupsFile) {
            read = KeptGroupsFile.decode(data)
            if read == nil { Store.quarantine(groupsFile) }
        }
        if read == nil, let data = try? Data(contentsOf: legacyGroupsFile) {
            read = LegacyPinFolders.decode(data)
            if read == nil { Store.quarantine(legacyGroupsFile) } else { migrating = true }
        }
        groupsBySpace = read?.bySpace ?? [:]
        moved = read?.moved ?? [:]
        let leftOver = !migrating && read != nil && files.fileExists(atPath: legacyGroupsFile.path)
        guard migrating || !moved.isEmpty || leftOver else { return }
        let mark = Disk.mark()
        for (space, into) in moved { refile(space, into: into) }
        if migrating || !moved.isEmpty { saveGroups() }
        guard Disk.drain(since: mark) else { return }
        // On disk, the rows in their groups and the groups with them.
        if !moved.isEmpty {
            moved = [:]
            saveGroups()
        }
        if files.fileExists(atPath: legacyGroupsFile.path) { Disk.remove(legacyGroupsFile) }
    }

    private static func saveGroups() {
        let read = KeptGroupsFile.Read(bySpace: groupsBySpace, moved: moved)
        Disk.write(groupsFile) { KeptGroupsFile.encode(read) }
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

    /// A space deleted: its pins go with it, and its kept groups.
    static func forget(_ space: UUID) {
        load()
        let hadGroups = groupsBySpace.removeValue(forKey: space) != nil
        let hadMoves = moved.removeValue(forKey: space) != nil
        if hadGroups || hadMoves { saveGroups() }
        guard bySpace.removeValue(forKey: space) != nil else { return }
        save()
    }

    /// The pins and the kept groups written again as they now are, changed
    /// or not: for something that is recorded as done only once it is on
    /// disk (PinShelf.bringBookmarks), so a write that failed before is
    /// tried again rather than taken as landed because nothing changed.
    static func write() {
        load()
        saveGroups()
        save()
    }

    private static func save() {
        let catalog = PinCatalog(bySpace: bySpace, sharedByProfile: sharedBy)
        Disk.write(file) { try? PinsFile.encode(catalog) }
    }
}
