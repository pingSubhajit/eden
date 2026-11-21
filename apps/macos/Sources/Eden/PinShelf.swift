import EdenCore
import Foundation

// A space's kept area, its pinned rows and kept groups (Column.swift), read
// and changed as a tree of bookmarks. Pins are where the Mac keeps pages, as
// in Arc (#6), so this is what chrome.bookmarks hands an extension
// (ExtensionShims.swift), and the shape bookmarks come in as when they
// become pins: the ones you had (bringBookmarks), at the top level of the
// kept area with their folders as kept groups, and another browser's
// (Browser.takeBookmarks), in a group of their own.
//
// A folder is a kept group, by its id; a site is a pinned row (a listed
// PinDef), by its id, its title the name it was given or else the page's.
// The tree reads as the kept area draws it (ColumnTree.items): at the top
// its rows and groups in their order, each group where its first row
// stands; in a group its rows. Groups are one level deep, in both areas: a
// group holds rows, never another group, so a folder asked into a folder
// is refused, and bookmarks that come in nested are taken in flat, the
// pages of every folder inside going into the group they come in by, in
// the order they come. An index is the place itself, at the top as in a
// group, but for an empty group: having no row to stand by, it stands after
// the group before it (Column.swift), the nearest place the model has.
// The squares and the pins every space shows (Pins.shared) are not rows of
// the space: they are not in the tree, and every change keeps them as they
// are.
//
// Each change is written with Pins.setGroups and Pins.set, which tell the
// other windows (Pins.changed), another profile's included, and the window
// making it follows at once (Browser.pinsChanged).

@MainActor
struct PinShelf {
    /// The window making the changes.
    let browser: Browser
    let space: UUID

    /// `space`: the window's own space in front, unless another is named.
    init(_ browser: Browser, space: UUID? = nil) {
        self.browser = browser
        self.space = space ?? browser.spaceID
    }

    // MARK: - reading

    /// The rows and groups at the top, each group with what it holds.
    var roots: [Bookmark] { current.tree(nil) }

    /// The folder `id` is in; nil at the top, as every folder is, or when
    /// it isn't here.
    func parent(of id: Bookmark.ID) -> Bookmark.ID? {
        let shelf = current
        return shelf.defs.first { $0.id == id && $0.listed == true }.flatMap(shelf.home(of:))
    }

    // MARK: - changing

    /// A site as a pinned row, or a folder with what it holds, in `parent`
    /// at `index`: at the top for nil or a folder that isn't here, at the
    /// end of its level without an index. What chrome.bookmarks.create does.
    /// Nil when it can't be pinned: a folder asked into a folder, or an
    /// address that isn't a page (see row). The pages of a folder's own
    /// folders go into it, in their order, as ColumnTree.fromArc has them.
    ///
    /// A space keeps one pin of a page (SyncItems.applyPins): a second would
    /// be made here and then dropped by sync. So a page already a row of
    /// the space comes back as that row, moved into `parent` only when one
    /// is asked for; a page that is a square here, or a pin every space
    /// shows, is not pinned again (nil).
    @discardableResult
    func insert(_ node: Bookmark, into parent: Bookmark.ID?, at index: Int? = nil) -> Bookmark? {
        let before = current
        var shelf = before
        let parent = parent.flatMap { shelf.isFolder($0) ? $0 : nil }
        if !node.isFolder, let url = node.url, let address = URL(string: url) {
            let page = PinDef.page(address)
            let same = { (def: PinDef) in PinShelf.page(of: def) == page }
            if let pinned = shelf.defs.first(where: same) {
                guard pinned.listed == true else { return nil }
                if let parent { move(pinned.id, into: parent, at: index) }
                return current.node(pinned.id)
            }
            if Pins.shared(browser.profileID).contains(where: same) { return nil }
        }
        let id = shelf.uses(node.id) ? UUID() : node.id
        if node.isFolder {
            guard parent == nil else { return nil }
            shelf.put(TabGroup(id: id, name: PinShelf.folderName(node.title), collapsed: false), at: index)
            var noted = Noted()
            shelf.fill(node.children ?? [], into: id, besides: Pins.shared(browser.profileID), keepingIDs: false, noted: &noted)
            // Its rows came in at the end: the group stays where it was put.
            shelf.place(group: id, at: index)
        } else {
            guard let url = node.url, let row = PinShelf.row(title: node.title, url: url, id: id, group: parent) else { return nil }
            shelf.put(row, at: index)
        }
        save(shelf, over: before)
        return shelf.node(id)
    }

    /// A new title, or a new address for a row (never for a folder). An
    /// emptied title gives a row back the page's own; a folder keeps its
    /// name. What chrome.bookmarks.update does. False, and nothing changed,
    /// for an address that isn't a page, or that another pin of the space
    /// already has, a square or one every space shows among them: the space
    /// keeps one pin of a page (SyncItems.onePerPage), and sync would drop
    /// one of the two.
    @discardableResult
    func update(_ id: Bookmark.ID, title: String?, url: String?) -> Bool {
        let before = current
        var shelf = before
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = shelf.groups.firstIndex(where: { $0.id == id }) {
            guard let trimmed, !trimmed.isEmpty else { return true }
            shelf.groups[at].name = String(trimmed.prefix(200))
        } else if let at = shelf.defs.firstIndex(where: { $0.id == id && $0.listed == true }) {
            if let url {
                guard let row = PinShelf.row(title: "", url: url, id: id, group: nil),
                      let page = PinShelf.page(of: row)
                else { return false }
                let others = shelf.defs.filter { $0.id != id } + Pins.shared(browser.profileID)
                if others.contains(where: { PinShelf.page(of: $0) == page }) { return false }
                shelf.defs[at].home = row.home
            }
            if let trimmed { shelf.defs[at].name = trimmed.isEmpty ? nil : trimmed }
        }
        save(shelf, over: before)
        return true
    }

    /// A row or a folder, with what it holds, into `parent` (nil: the top)
    /// at `index` among what is there, or at the end. As in Chrome and the
    /// bookmarks list, the index is counted as the level reads before the
    /// move, so moving one just below itself leaves it where it is. Into
    /// something that isn't a folder, nothing moves. False, and nothing
    /// moved, for a folder asked into a folder, itself included: a folder
    /// holds rows only.
    @discardableResult
    func move(_ id: Bookmark.ID, into parent: Bookmark.ID?, at index: Int? = nil) -> Bool {
        let before = current
        var shelf = before
        if let parent, !shelf.isFolder(parent) { return true }
        if parent != nil, shelf.isFolder(id) { return false }
        var index = index
        let siblings = shelf.tree(parent)
        if let at = index, let from = siblings.firstIndex(where: { $0.id == id }), from < at {
            // It leaves a gap above the place it goes to.
            index = at - 1
        }
        if shelf.isFolder(id) {
            shelf.place(group: id, at: index)
        } else if let at = shelf.defs.firstIndex(where: { $0.id == id && $0.listed == true }) {
            var row = shelf.defs.remove(at: at)
            row.group = parent
            shelf.put(row, at: index)
        }
        save(shelf, over: before)
        return true
    }

    /// A row unpinned, or a folder taken away with everything in it, its
    /// rows unpinned. What chrome.bookmarks.remove and removeTree do.
    func remove(_ id: Bookmark.ID) {
        let before = current
        var shelf = before
        if shelf.isFolder(id) {
            shelf.groups.removeAll { $0.id == id }
            shelf.defs.removeAll { $0.listed == true && $0.group == id }
        } else {
            shelf.defs.removeAll { $0.id == id && $0.listed == true }
        }
        save(shelf, over: before)
    }

    // MARK: - bookmarks brought in

    /// Bookmarks, folders and all, as pinned rows. In a kept group named
    /// `name`, gone into if there is one of that name: every page, its
    /// folders' pages too, in the order they come, a group being one level
    /// deep; what another browser brings (folderName(import:)). With no
    /// name, as your own bookmarks come (bringBookmarks): a page at the top
    /// of what comes is a row at the top level, and each folder at the top
    /// a kept group of its name, gone into if there is one (with
    /// `keepingIDs`, first the one it made before, whatever it has been
    /// renamed since), its own folders' pages in it in their order. What
    /// comes in comes after what is there, in the order it comes.
    /// Nothing twice: a page already
    /// pinned here, the pins every space shows included, is counted as
    /// already here, and so is a second of one page in what comes, by the
    /// rule sync keeps one pin of a page by (PinDef.page, as
    /// SyncItems.onePerPage): another page of a site pinned at its root is
    /// a page of its own, and comes. A folder left with nothing in
    /// it is not made. Only pages are pinned: an address that isn't one, a
    /// bookmarklet's javascript: say, is passed over.
    ///
    /// `keepingIDs`: each row and folder takes the id its bookmark had, so
    /// two Macs bringing over the same synced bookmarks make the same pins
    /// and folders, which sync then sees as one each. Returns how many rows
    /// came in, how many were here already, and the id of every row made,
    /// and of each folder made, for taking them back out (withdraw).
    @discardableResult
    func take(_ nodes: [Bookmark], into name: String?, keepingIDs: Bool = false)
        -> (added: Int, already: Int, ids: [UUID]) {
        guard !nodes.isEmpty else { return (0, 0, []) }
        let before = current
        let (shelf, noted) = taking(nodes, into: name, keepingIDs: keepingIDs, over: before)
        let kept = Set(shelf.groups.map(\.id))
        save(shelf, over: before)
        return (noted.rows.count, noted.already, noted.folders.filter(kept.contains) + noted.rows)
    }

    /// The rows `take` would pin, worked out and nothing changed: for an
    /// import to make their tabs ahead, a batch at a time, before it takes
    /// them in (Browser.takeFile). With `keepingIDs`, the rows it then
    /// takes are these, by id, as long as the pins haven't changed between.
    func planned(_ nodes: [Bookmark], into name: String?, keepingIDs: Bool = false) -> [PinDef] {
        guard !nodes.isEmpty else { return [] }
        let (shelf, noted) = taking(nodes, into: name, keepingIDs: keepingIDs, over: current)
        let made = Set(noted.rows)
        return shelf.defs.filter { made.contains($0.id) }
    }

    /// What take makes of the shelf as it is now, and what it noted.
    private func taking(_ nodes: [Bookmark], into name: String?, keepingIDs: Bool, over before: Shelf) -> (Shelf, Noted) {
        var shelf = before
        var noted = Noted()
        let besides = Pins.shared(browser.profileID)
        if let name {
            let top = shelf.folder(named: name, id: UUID(), noted: &noted)
            shelf.fill(nodes, into: top, besides: besides, keepingIDs: keepingIDs, noted: &noted)
        } else {
            for node in nodes {
                guard node.isFolder else {
                    shelf.fill([node], into: nil, besides: besides, keepingIDs: keepingIDs, noted: &noted)
                    continue
                }
                let folder = keepingIDs && shelf.isFolder(node.id)
                    ? node.id : shelf.folder(named: node.title, id: keepingIDs ? node.id : UUID(), noted: &noted)
                shelf.fill(node.children ?? [], into: folder, besides: besides, keepingIDs: keepingIDs, noted: &noted)
            }
        }
        shelf.groups = ColumnTree.withoutEmpty(shelf.groups, keeping: Set(before.groups.map(\.id)), pins: shelf.defs)
        return (shelf, noted)
    }

    /// Takes back out what an import brought (see ImportRecord), from every
    /// space of the window's profile it is still in, and the profile's pins
    /// every space shows: each of its rows, then its folder if that is left
    /// with nothing in it. A folder of its that you put something of your
    /// own in stays, with that in it. Returns how many rows went, and the
    /// ids still to be taken out another time: those not taken out here
    /// that are still pinned somewhere, in another profile.
    ///
    /// The window's profile only: an import's record is kept by the
    /// browser's name, not by the profile it came into, and Replace in one
    /// profile must never take pins out of another. What is left stays in
    /// the record, for Replace in the profile that has them.
    @discardableResult
    static func withdraw(_ ids: [UUID], via browser: Browser) -> (rows: Int, left: [UUID]) {
        let ours = Set(ids)
        guard !ours.isEmpty else { return (0, []) }
        Pins.load()
        var gone = 0
        var removed = Set<UUID>()
        let spaces = Set(Pins.bySpace.keys).union(Pins.groupsBySpace.keys)
        for space in spaces where Spaces.profile(of: space) == browser.profileID {
            let shelf = PinShelf(browser, space: space)
            let before = shelf.current
            var now = before
            now.defs.removeAll { ours.contains($0.id) }
            gone += before.defs.count - now.defs.count
            let holding = Set(now.defs.compactMap(\.group))
            now.groups.removeAll { ours.contains($0.id) && !holding.contains($0.id) }
            removed.formUnion(Set(before.defs.map(\.id)).subtracting(now.defs.map(\.id)))
            removed.formUnion(Set(before.groups.map(\.id)).subtracting(now.groups.map(\.id)))
            shelf.save(now, over: before)
        }
        // One made a pin every space shows (Pins.shared) since: from there.
        let shared = Pins.shared(browser.profileID)
        let left = shared.filter { !ours.contains($0.id) }
        if left.count != shared.count {
            gone += shared.count - left.count
            removed.formUnion(shared.map(\.id).filter(ours.contains))
            Pins.setShared(left, from: browser)
            browser.sharedPinsChanged()
        }
        // Still pinned in another profile: kept for Replace there. One of
        // this profile's that stays, a folder holding a row of your own,
        // was dealt with here, and leaves the record.
        var elsewhere = Set<UUID>()
        for space in spaces where Spaces.profile(of: space) != browser.profileID {
            elsewhere.formUnion(Pins.defs(space).map(\.id) + Pins.groups(space).map(\.id))
        }
        for profile in Profiles.shared.list where profile.id != browser.profileID {
            elsewhere.formUnion(Pins.shared(profile.id).map(\.id))
        }
        return (gone, ids.filter { !removed.contains($0) && elsewhere.contains($0) })
    }

    // MARK: - the bookmarks you had

    /// Before #6's review: a key saying a profile's bookmarks had all been
    /// brought over, once. Read once, then gone (see brought).
    static func broughtKey(_ profile: UUID) -> String { "bookmarks.pinned." + profile.uuidString }

    /// Which of a profile's bookmarks have been brought into its pins, by
    /// id, kept so each comes over once: one you unpin never comes back.
    static func broughtIDsKey(_ profile: UUID) -> String { "bookmarks.brought." + profile.uuidString }

    /// Before your bookmarks came to the top level, they came into a
    /// folder named Bookmarks (#6): once a profile has run this, it is done,
    /// whatever it found (see unfolder).
    static func unfolderedKey(_ profile: UUID) -> String { "bookmarks.unfoldered." + profile.uuidString }

    /// The bookmarks a profile has that this Mac hasn't brought over yet,
    /// as pinned rows in the profile's home space (the first space for
    /// Personal, the one it started with for another, as Sync.apply has it):
    /// a bookmark at the top of the list a row at the top level, and each
    /// folder of the list a kept group of its name, the pages of its own
    /// folders in it in order (see take). Run as each
    /// window opens, and again whenever the list changes (Bookmarks.saved,
    /// as sync adopts what another device has), so a Mac whose bookmarks
    /// were still on their way from iCloud brings them once they come, and
    /// the iPhone's new bookmarks become pins here until it has pins of its
    /// own (#8). Only adds: a bookmark gone from the list leaves its pin,
    /// and one brought before is never brought again. The list itself is
    /// left as it is: sync still carries it for the iPhone, and its file
    /// is the backup.
    ///
    /// What was done is recorded only once the pins and the kept groups it
    /// changed are known to be on disk (Disk.drain(since:)), as the pin
    /// folders of before are taken in (Pins.readGroups): recorded with a
    /// write that failed, the bookmarks it brought would be passed by for
    /// good, and an old Bookmarks folder kept. Unrecorded, the next run does
    /// it again, which adds nothing twice: a page pinned already is passed
    /// by, a folder made already is gone into by its id, and the Bookmarks
    /// folder already gone has nothing left to take away. Each time the
    /// files are written whole (Pins.write), so a run that finds nothing
    /// left to change still puts on disk what the one before couldn't.
    static func bringBookmarks(into browser: Browser) {
        let profile = browser.profileID
        let roots = Profiles.bookmarks(profile).roots
        let home = profile == Profile.personalID ? Space.firstID : Profiles.shared.profile(profile).home
        var brought = Set((Store.settings.stringArray(forKey: broughtIDsKey(profile)) ?? []).compactMap(UUID.init))
        // Brought over all at once before: everything in the list then.
        if Store.settings.bool(forKey: broughtKey(profile)) {
            brought.formUnion(siteIDs(roots))
            Store.settings.removeObject(forKey: broughtKey(profile))
            Store.settings.set(brought.map(\.uuidString).sorted(), forKey: broughtIDsKey(profile))
        }
        if !Store.settings.bool(forKey: unfolderedKey(profile)) {
            let mark = Disk.mark()
            PinShelf(browser, space: home).unfolder(brought: brought)
            Pins.write()
            if Disk.drain(since: mark) { Store.settings.set(true, forKey: unfolderedKey(profile)) }
        }
        let fresh = unbrought(roots, brought)
        guard !fresh.isEmpty else { return }
        let mark = Disk.mark()
        PinShelf(browser, space: home).take(fresh, into: nil, keepingIDs: true)
        Pins.write()
        guard Disk.drain(since: mark) else { return }
        brought.formUnion(siteIDs(fresh))
        Store.settings.set(brought.map(\.uuidString).sorted(), forKey: broughtIDsKey(profile))
    }

    /// The group named Bookmarks your bookmarks were brought into before
    /// (#6), taken away, its rows at the top level where they stand.
    /// Only the one that bringing them made: named Bookmarks, as it was
    /// named, and holding a row brought from the list, which took its
    /// bookmark's id (`brought`, by id). A Bookmarks folder of your own,
    /// holding none, is left as it is. Its rows of your own, put in it
    /// since, go to the top with the rest, as everything in it was meant
    /// to be.
    func unfolder(brought: Set<UUID>) {
        let before = current
        var shelf = before
        let ours = shelf.groups.filter { group in
            group.name == PinShelf.folderName("Bookmarks")
                && shelf.defs.contains { $0.listed == true && $0.group == group.id && brought.contains($0.id) }
        }
        guard !ours.isEmpty else { return }
        let gone = Set(ours.map(\.id))
        shelf.groups.removeAll { gone.contains($0.id) }
        for at in shelf.defs.indices where shelf.defs[at].group.map(gone.contains) == true {
            shelf.defs[at].group = nil
        }
        save(shelf, over: before)
    }

    /// Every site's id in a tree, folders opened.
    private static func siteIDs(_ nodes: [Bookmark]) -> [UUID] {
        nodes.flatMap { $0.isFolder ? siteIDs($0.children ?? []) : [$0.id] }
    }

    /// The tree less every site among `brought`, and every folder that then
    /// holds no site.
    private static func unbrought(_ nodes: [Bookmark], _ brought: Set<UUID>) -> [Bookmark] {
        nodes.compactMap { node -> Bookmark? in
            guard node.isFolder else { return brought.contains(node.id) ? nil : node }
            let kids = unbrought(node.children ?? [], brought)
            guard !kids.isEmpty else { return nil }
            var folder = node
            folder.children = kids
            return folder
        }
    }

    // MARK: - the pieces

    /// The space's pins and kept groups, read now.
    private var current: Shelf {
        Shelf(defs: Pins.defs(space), groups: Pins.groups(space))
    }

    /// The change written, the groups first so the rows rebuilt for the
    /// pins find theirs; nothing when there is none. In the order drawn,
    /// each group's rows together and the groups in the order they stand,
    /// as the window that makes its row from them will have them.
    private func save(_ shelf: Shelf, over before: Shelf) {
        guard shelf.defs != before.defs || shelf.groups != before.groups else { return }
        var shelf = shelf
        shelf.set(shelf.items)
        Pins.setGroups(space, shelf.groups, from: browser)
        Pins.set(space, shelf.defs, from: browser)
        browser.pinsChanged(in: space)
    }

    /// A pinned row for a bookmark, as Arc's pinned pages come in (see
    /// Browser.takeArc): its letter the site's first, its name the
    /// bookmark's title, so the row reads as the bookmark did rather than
    /// as whatever the page calls itself when it loads. Nil for an address
    /// that isn't a page a pin can hold.
    static func row(title: String, url: String, id: UUID, group: UUID?) -> PinDef? {
        guard let address = URL(string: url), ["http", "https", "file"].contains(address.scheme?.lowercased() ?? "")
        else { return nil }
        let host = address.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return PinDef(id: id, letter: host.first.map { String($0).uppercased() } ?? "•", home: address.absoluteString,
                      title: name.isEmpty ? Address.pretty(address) : name, name: name.isEmpty ? nil : name,
                      listed: true, group: group)
    }

    /// The group another browser's bookmarks come into, named after where
    /// they came from: "Chrome Bookmarks", or a bookmarks file's name. A
    /// name that already says bookmarks, as a file exported from a browser
    /// usually does ("bookmarks_11_21_26"), is kept as it is rather than
    /// said twice.
    static func folderName(import source: String) -> String {
        let name = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Bookmarks" }
        return name.localizedCaseInsensitiveContains("bookmark") ? name : name + " Bookmarks"
    }

    /// A group always has a name.
    static func folderName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Folder" : String(trimmed.prefix(200))
    }

    /// A pin's page, as sync tells one pin of a page from another
    /// (PinDef.page).
    static func page(of def: PinDef) -> String? {
        URL(string: def.home).map(PinDef.page)
    }

    /// What one take made, and what it found here already.
    struct Noted {
        var rows: [UUID] = []
        var folders: [UUID] = []
        var already = 0
        /// Every page pinned in the space, by PinDef.page, filled on first use.
        var pages: Set<String>?
        /// Every id the space's pins and groups use, filled on first use:
        /// looked up for each bookmark, which by scanning the pins made an
        /// import of fifteen hundred a quarter of a second.
        var ids: Set<UUID>?
    }

    /// The pins and kept groups one change works on.
    @MainActor struct Shelf {
        /// The space's own pins, squares and rows, in their order.
        var defs: [PinDef]
        var groups: [TabGroup]

        func isFolder(_ id: UUID) -> Bool { groups.contains { $0.id == id } }

        /// Whether a pin or group of the space already has this id.
        func uses(_ id: UUID) -> Bool { isFolder(id) || defs.contains { $0.id == id } }

        /// The group a row is drawn in: nil at the top, as is a row whose
        /// group is gone.
        func home(of def: PinDef) -> UUID? {
            def.group.flatMap { isFolder($0) ? $0 : nil }
        }

        /// The kept area as drawn (ColumnTree.items).
        var items: [ColumnItem<PinDef>] {
            ColumnTree.items(defs.filter { $0.listed == true }, group: \.group, groups: groups, keepingEmpty: true)
        }

        /// The kept area made `items`: each row in the group it stands in,
        /// the squares first as they were, and the groups in the order they
        /// stand.
        mutating func set(_ items: [ColumnItem<PinDef>]) {
            let flat = ColumnTree.flattened(items)
            let rows = flat.members.map { member -> PinDef in
                var row = member.member
                row.group = member.group
                return row
            }
            let placed = Set(flat.groups.map(\.id))
            defs = defs.filter { $0.listed != true } + rows
            groups = flat.groups + groups.filter { !placed.contains($0.id) }
        }

        /// A level as the kept area draws it: at the top its rows and groups,
        /// each group with its rows; in a group, its rows.
        func tree(_ parent: UUID?) -> [Bookmark] {
            let items = self.items
            if let parent {
                return items.first { $0.group?.id == parent }?.tabs.map(Shelf.site) ?? []
            }
            return items.map { item in
                switch item {
                case .tab(let def): return Shelf.site(def)
                case .group(let group, let rows): return Bookmark(id: group.id, title: group.name, url: nil, children: rows.map(Shelf.site))
                }
            }
        }

        private static func site(_ def: PinDef) -> Bookmark {
            Bookmark(id: def.id, title: def.name ?? def.title, url: def.home, children: nil)
        }

        func node(_ id: UUID) -> Bookmark? {
            if let group = groups.first(where: { $0.id == id }) {
                return Bookmark(id: group.id, title: group.name, url: nil, children: tree(group.id))
            }
            return defs.first { $0.id == id && $0.listed == true }.map(Shelf.site)
        }

        /// A new group at `index` among the top level, or at the end.
        mutating func put(_ group: TabGroup, at index: Int?) {
            var items = self.items
            items.insert(.group(group, []), at: min(max(index ?? items.count, 0), items.count))
            set(items)
        }

        /// A row at `index` among its group's rows (row.group), or at the
        /// top level for none, or at the end of either.
        mutating func put(_ row: PinDef, at index: Int?) {
            var items = self.items
            if let group = home(of: row), let at = items.firstIndex(where: { $0.group?.id == group }),
               case .group(let held, var rows) = items[at] {
                rows.insert(row, at: min(max(index ?? rows.count, 0), rows.count))
                items[at] = .group(held, rows)
            } else {
                var row = row
                row.group = nil
                items.insert(.tab(row), at: min(max(index ?? items.count, 0), items.count))
            }
            set(items)
        }

        /// A group, with its rows, to `index` among the top level, or the end.
        mutating func place(group id: UUID, at index: Int?) {
            var items = self.items
            guard let at = items.firstIndex(where: { $0.group?.id == id }) else { return }
            let item = items.remove(at: at)
            items.insert(item, at: min(max(index ?? items.count, 0), items.count))
            set(items)
        }

        /// The group of that name, made (with `id`) if there is none.
        mutating func folder(named title: String, id: UUID, noted: inout Noted) -> UUID {
            let name = PinShelf.folderName(title)
            if let same = groups.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                return same.id
            }
            let id = uses(id) ? UUID() : id
            groups.append(TabGroup(id: id, name: name, collapsed: false))
            noted.folders.append(id)
            noted.ids?.insert(id)
            return id
        }

        /// `nodes` into the group `parent` (see take): every page, the pages
        /// of its folders too, in the order they come, after what is there.
        /// `besides`: pins of the space's that aren't its own, the ones
        /// every space shows, whose pages count as pinned here too.
        mutating func fill(_ nodes: [Bookmark], into parent: UUID?, besides: [PinDef], keepingIDs: Bool,
                           noted: inout Noted) {
            if noted.pages == nil {
                noted.pages = Set((defs + besides).compactMap(PinShelf.page(of:)))
            }
            if noted.ids == nil {
                noted.ids = Set(defs.map(\.id) + groups.map(\.id))
            }
            for node in nodes {
                if node.isFolder {
                    fill(node.children ?? [], into: parent, besides: besides, keepingIDs: keepingIDs, noted: &noted)
                    continue
                }
                // The pin this bookmark makes, already here: synced from a
                // Mac that brought it over first. Kept groups don't sync, so
                // it came without its group: it gets it back.
                if keepingIDs, noted.ids?.contains(node.id) == true, let at = defs.firstIndex(where: { $0.id == node.id }) {
                    if defs[at].listed == true, home(of: defs[at]) == nil, parent != nil { defs[at].group = parent }
                    noted.already += 1
                    continue
                }
                let id = keepingIDs && noted.ids?.contains(node.id) == false ? node.id : UUID()
                guard let url = node.url, let row = PinShelf.row(title: node.title, url: url, id: id, group: parent),
                      let page = PinShelf.page(of: row)
                else { continue }
                if noted.pages?.insert(page).inserted == false {
                    noted.already += 1
                    continue
                }
                defs.append(row)
                noted.rows.append(id)
                noted.ids?.insert(id)
            }
        }
    }
}

extension Browser {
    /// This window's space in front, as a tree of bookmarks (see PinShelf).
    var pinShelf: PinShelf { PinShelf(self) }
}
