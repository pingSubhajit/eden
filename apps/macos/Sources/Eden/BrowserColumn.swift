import Foundation

// The column's two areas as a window holds them (see Column.swift for what
// they are): the kept area's groups with the pins, the open area's with the
// window, the same TabGroup in both, and how a tab or a group goes from one
// to the other. A group's own operations — rename, fold, colour, icon,
// Separate Tabs, Copy All Links — are one each, for a group in either area
// (Browser.changeGroup and its neighbours); only where each area keeps its
// things differs.
//
// Only rows of this space's own go in a kept group: not a square, nor a row
// every space shows (Pins.shared), which keep the head of the kept area.

extension Browser {
    // MARK: - the two areas

    /// This space's kept groups, in their order.
    var keptGroups: [TabGroup] { Pins.groups(spaceID) }

    /// An area's groups, in their order.
    func groups(in area: ColumnArea) -> [TabGroup] {
        switch area {
        case .kept: keptGroups
        case .open: tabGroups
        }
    }

    /// The area a group is in, from where it is kept and nowhere else: kept
    /// while the pins store holds it (any space's), open while it is one of
    /// this window's groups (the space on screen's, or a parked one's), nil
    /// once it is gone.
    func area(ofGroup id: UUID) -> ColumnArea? {
        if Pins.keptGroup(id) != nil { return .kept }
        if tabGroups.contains(where: { $0.id == id }) { return .open }
        if parked.values.contains(where: { $0.groups?.contains { $0.id == id } == true }) { return .open }
        return nil
    }

    /// A group of the space on screen as it now is, in either area.
    func columnGroup(_ id: UUID) -> TabGroup? {
        tabGroups.first { $0.id == id } ?? keptGroups.first { $0.id == id }
    }

    /// The area a tab is drawn in: kept for a pinned row, open for any tab
    /// that isn't a pin, nil for a square, above both.
    func area(of tab: Tab) -> ColumnArea? {
        if tab.pin == nil { return .open }
        return tab.listed ? .kept : nil
    }

    /// The group a tab is drawn in, in its area: a kept row's kept group, an
    /// open tab's open one; none for a square.
    func columnGroupID(of tab: Tab) -> UUID? {
        switch area(of: tab) {
        case .kept: keptGroup(of: tab)
        case .open: group(of: tab)
        case nil: nil
        }
    }

    /// The kept group a row is drawn in: none for a row every space shows,
    /// or one whose group is gone, which is drawn at the top.
    func keptGroup(of tab: Tab) -> UUID? {
        guard fitsKeptGroup(tab), let id = tab.keptGroupID, keptGroups.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// A group's tabs in their order, folded away or not, in either area.
    func members(ofGroup id: UUID) -> [Tab] {
        switch area(ofGroup: id) {
        case .kept: listedPins.filter { fitsKeptGroup($0) && $0.keptGroupID == id }
        case .open: tabs(in: id)
        case nil: []
        }
    }

    /// An area's items, in order (Column.swift).
    func items(in area: ColumnArea) -> [SideItem] {
        switch area {
        case .kept: keptItems()
        case .open: sideItems
        }
    }

    /// The kept area's items: the rows every space shows, which keep its
    /// head, then this space's own, each group where its first row stands
    /// and the empty ones after the group before them.
    func keptItems() -> [SideItem] {
        Browser.keptItems(listedPins, groups: keptGroups)
    }

    /// The same for any space's rows and kept groups: another space's,
    /// passing in a swipe, too.
    static func keptItems(_ rows: [Tab], groups: [TabGroup]) -> [SideItem] {
        let everywhere = rows.filter(\.everywhere).map(SideItem.tab)
        let own = rows.filter { !$0.everywhere && !$0.shy }
        return everywhere + ColumnTree.items(own, group: \.keptGroupID, groups: groups, keepingEmpty: true)
    }

    /// The kept area's lines as drawn, a folded group showing only the tab
    /// in front, if it is one of its own.
    func keptLines() -> [ColumnLine<Tab>] {
        let front = activeID
        return ColumnTree.lines(keptItems(), showing: { $0.id == front })
    }

    /// Whether the kept area is drawn with groups: a kept group to draw.
    /// With none, the rows are drawn as they always were.
    var drawsKeptGroups: Bool { !keptGroups.isEmpty }

    /// Whether a pin can go in a kept group: a row of this space's own.
    func fitsKeptGroup(_ tab: Tab) -> Bool {
        tab.pin != nil && tab.listed && !tab.everywhere && !tab.shy
    }

    /// A row's pins with the rows in the order the kept area draws them:
    /// the squares as they are, the rows every space shows first (see
    /// keepBlocks), then this space's own, each group's together, then the
    /// rest.
    static func arrangedPins(_ row: [Tab], groups: [TabGroup]) -> [Tab] {
        let pinned = row.filter { $0.pin != nil && !$0.shy }
        let loose = row.filter { $0.pin == nil || $0.shy }
        let rows = pinned.filter(\.listed)
        let own = ColumnTree.ordered(rows.filter { !$0.everywhere }, group: \.keptGroupID, groups: groups)
        return pinned.filter { !$0.listed } + rows.filter(\.everywhere) + own + loose
    }

    // MARK: - the kept area

    /// The kept groups as they now are, here and in every window.
    func saveKeptGroups(_ groups: [TabGroup]) {
        objectWillChange.send()
        Pins.setGroups(spaceID, groups, from: self)
    }

    /// The row put in the kept area's order, when it isn't.
    func arrangeKept() {
        applyKept(ownKeptItems())
    }

    /// New Folder: a kept group after the kept groups there are, holding
    /// `tab` if one is given. Its name arrives selected, as a new group's
    /// does, unless `rename` is false. Nil for a tab that can't go in one.
    @discardableResult
    func newKeptGroup(named name: String = "New Folder", holding tab: Tab? = nil, rename: Bool = true) -> UUID? {
        if let tab, !fitsKeptGroup(tab) { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let made = TabGroup(id: UUID(), name: trimmed.isEmpty ? "New Folder" : String(trimmed.prefix(200)), collapsed: false)
        saveKeptGroups(keptGroups + [made])
        if let tab {
            move(tab, to: ColumnPlace(area: .kept, group: made.id))
        } else {
            arrangeKept()
            writeSession(now: true)
        }
        if rename { editingGroupID = made.id }
        return made.id
    }

    /// Delete Folder, a kept group's Separate Tabs: its rows stay pinned
    /// where it stood, as Separate Tabs leaves a group's tabs open. No pin
    /// is closed.
    func ungroupKept(_ id: UUID) {
        guard keptGroups.contains(where: { $0.id == id }) else { return }
        if editingGroupID == id { editingGroupID = nil }
        if iconGroupID == id { iconGroupID = nil }
        let items = ownKeptItems().flatMap { item -> [SideItem] in
            guard case .group(let group, let members) = item, group.id == id else { return [item] }
            return members.map(SideItem.tab)
        }
        saveKeptGroups(keptGroups.filter { $0.id != id })
        applyKept(items)
        writeSession(now: true)
    }

    /// This space's own kept items, without the tabs `leaving`.
    private func ownKeptItems(without leaving: Set<Tab.ID> = []) -> [SideItem] {
        let own = tabs.filter { fitsKeptGroup($0) && !leaving.contains($0.id) }
        return ColumnTree.items(own, group: \.keptGroupID, groups: keptGroups, keepingEmpty: true)
    }

    /// The rows every space shows, which stand at the head of the kept area.
    private var everywhereRows: [Tab] {
        tabs.filter { $0.pin != nil && $0.listed && $0.everywhere && !$0.shy }
    }

    /// `moving` put into `items`: into `group`'s tabs (nil: the top level)
    /// at `index`, or at the end.
    private static func inserting(_ moving: [Tab], into group: UUID?, at index: Int?, in items: [SideItem]) -> [SideItem] {
        var items = items
        if let group, let at = items.firstIndex(where: { $0.group?.id == group }), case .group(let held, var members) = items[at] {
            members.insert(contentsOf: moving, at: min(max(index ?? members.count, 0), members.count))
            items[at] = .group(held, members)
        } else {
            items.insert(contentsOf: moving.map(SideItem.tab), at: min(max(index ?? items.count, 0), items.count))
        }
        return items
    }

    /// The kept area made `items`, this space's own: each row in the group
    /// it is drawn in, the row in that order after the squares and the rows
    /// every space shows, and the kept groups' own order following what is
    /// drawn, which is all an empty group has to stand by. The groups are
    /// kept when their order changed; the pins are left for the caller to
    /// write, with the rest of what it changed (writeSession).
    private func applyKept(_ items: [SideItem]) {
        let flat = ColumnTree.flattened(items)
        for (tab, group) in flat.members where tab.keptGroupID != group { tab.keptGroupID = group }
        let own = flat.members.map(\.member)
        let ids = Set(own.map(\.id))
        let pinned = tabs.filter { $0.pin != nil && !$0.shy && !ids.contains($0.id) }
        let loose = tabs.filter { ($0.pin == nil || $0.shy) && !ids.contains($0.id) }
        rearrangeTabs(pinned.filter { !$0.listed } + pinned.filter(\.listed) + own + loose)
        let kept = keptGroups
        let order = flat.groups.map(\.id)
        let standing = order.compactMap { id in kept.first { $0.id == id } } + kept.filter { !order.contains($0.id) }
        if standing.map(\.id) != kept.map(\.id) { saveKeptGroups(standing) }
    }

    // MARK: - across the line

    /// Whether `tab` can go to `place`, the one rule the column's carry asks
    /// before the rows part for it and the move asks again: above the line,
    /// anything that can be pinned — not a private tab, nor a pair, unless
    /// `detaching` one half of it, a page on its own — and a pin every
    /// space shows, square or row, only at the top level, among the rows
    /// every space shows at its head (move clamps it there); into a kept
    /// group, one that is there. Below it, anything; into an open group, one that
    /// is there, while groups are on, and not a private tab or a script's.
    func takes(_ tab: Tab, at place: ColumnPlace, detaching: Bool = false) -> Bool {
        guard tabs.contains(where: { $0.id == tab.id }) else { return false }
        switch place.area {
        case .kept:
            if tab.pin == nil {
                guard canPin(tab), detaching || split(for: tab) == nil else { return false }
            } else if tab.everywhere {
                guard place.group == nil else { return false }
            }
            if let group = place.group { return keptGroups.contains { $0.id == group } }
            return true
        case .open:
            guard let group = place.group else { return true }
            return prefs.usesTabGroups && tabGroups.contains { $0.id == group } && !tab.shy && !tab.bench
        }
    }

    /// Whether a group can go to `place`: at the top level of an area only,
    /// a group holding tabs alone. Above the line, an open group whose every
    /// tab can be pinned; below it, a kept group with rows in this window to
    /// make an open group of (one lasts as long as its tabs), while groups
    /// are on.
    func takes(group id: UUID, at place: ColumnPlace) -> Bool {
        guard place.group == nil, let from = area(ofGroup: id) else { return false }
        switch (from, place.area) {
        case (.open, .kept):
            let members = tabs(in: id)
            return !members.isEmpty && members.allSatisfy(canPin)
        case (.kept, .open):
            return prefs.usesTabGroups && tabs.contains { fitsKeptGroup($0) && $0.keptGroupID == id }
        case (.kept, .kept):
            return true
        case (.open, .open):
            return prefs.usesTabGroups
        }
    }

    /// A tab put at `place`, in whichever area it is now: above the line it
    /// is pinned as a row there (a square becomes one), below it unpinned
    /// there, as Unpin does — a row every space shows leaves them all. A
    /// pair goes whole below the line, and only `detaching` one half of it
    /// above. Its page, its history and whether it is asleep stay as they
    /// are. False, and nothing changed, for a place it can't go (takes).
    @discardableResult
    func move(_ tab: Tab, to place: ColumnPlace, detaching: Bool = false) -> Bool {
        guard takes(tab, at: place, detaching: detaching) else { return false }
        switch place.area {
        case .kept:
            objectWillChange.send()
            if tab.pin != nil, tab.everywhere {
                // A square every space shows made a row as Show as Row does,
                // staying every space's: among those rows.
                if !tab.listed {
                    if editingPin == tab.id { editingPin = nil }
                    tab.listed = true
                }
                return moveEverywhereRow(tab, to: place.index)
            }
            if tab.pin == nil {
                leaveSplit(tab)
                makePin(tab, listed: true)
            } else if !tab.listed {
                if editingPin == tab.id { editingPin = nil }
                tab.listed = true
            }
            let index = place.group == nil ? place.index.map { $0 - everywhereRows.count } : place.index
            applyKept(Browser.inserting([tab], into: place.group, at: index, in: ownKeptItems(without: [tab.id])))
            writeSession(now: true)
            return true
        case .open:
            if tab.pin != nil { unpin(tab) }
            placeOpen(tab, group: place.group, index: place.index, detaching: detaching)
            writeSession(now: true)
            return true
        }
    }

    /// A row every space shows, carried along those rows at the head of
    /// the kept area, or a square of theirs made one: among them, at
    /// `index`, and no further. The row put back in the pins' order: the
    /// squares, then those rows, then this space's own, then the rest.
    private func moveEverywhereRow(_ tab: Tab, to index: Int?) -> Bool {
        var head = everywhereRows.filter { $0.id != tab.id }
        head.insert(tab, at: min(max(index ?? head.count, 0), head.count))
        let ids = Set(head.map(\.id))
        let pinned = tabs.filter { $0.pin != nil && !$0.shy && !ids.contains($0.id) }
        let rest = tabs.filter { ($0.pin == nil || $0.shy) && !ids.contains($0.id) }
        rearrangeTabs(pinned.filter { !$0.listed } + head + pinned.filter(\.listed) + rest)
        writeSession(now: true)
        return true
    }

    /// A tab of the open area put at its place there: into `group` at
    /// `index` among its tabs, or at `index` among the area's items, or at
    /// the end. Out of a group, it lands in front of what stands at `index`,
    /// in one move (move(_:outOfGroupBefore:)). A pair goes whole, unless
    /// `detaching` the half carried.
    private func placeOpen(_ tab: Tab, group: UUID?, index: Int?, detaching: Bool) {
        if let group {
            let pair = detaching ? nil : split(for: tab)
            let peers = tabs(in: group).filter { standsInRow($0) && $0.id != tab.id && pair?.contains($0.id) != true }
            let at = min(max(index ?? peers.count, 0), peers.count)
            let target: GroupDropTarget
            if peers.indices.contains(at) {
                target = GroupDropTarget(group: group, member: peers[at].id)
            } else if let last = peers.last {
                target = GroupDropTarget(group: group, member: last.id, after: true)
            } else {
                target = GroupDropTarget(group: group)
            }
            move(tab, toGroup: target, detaching: detaching)
        } else if prefs.usesTabGroups {
            let items = sideItems
            if self.group(of: tab) != nil {
                let others = items.filter { $0.id != .tab(tab.id) }
                let before = index.flatMap { others.indices.contains($0) ? others[$0].id : nil }
                move(tab, outOfGroupBefore: before, detaching: detaching)
                return
            }
            guard let from = items.firstIndex(where: { $0.id == .tab(tab.id) }) else { return }
            let to = min(max(index ?? items.count - 1, 0), items.count - 1)
            if to != from { moveItem(.tab(tab.id), to: to) }
        } else {
            let loose = displayedTabs.filter { $0.pin == nil }.count
            moveDisplayedTab(tab, to: min(pinnedCount + max(index ?? loose, 0), displayedTabs.count - 1))
        }
    }

    /// A group put at `place`, at the top level of either area, its tabs in
    /// their order: carried above the line it becomes a kept group, every
    /// tab of it pinned as a row in it; below, an open group again, its
    /// rows unpinned into it, nothing asleep woken. False, and nothing
    /// changed, for a place inside a group (a group holds tabs only), a
    /// group that can't go there — an open one holding a private tab, a kept
    /// one with no row in this window to make an open group of — or an open
    /// place while groups are off.
    @discardableResult
    func move(group id: UUID, to place: ColumnPlace) -> Bool {
        guard takes(group: id, at: place), let from = area(ofGroup: id) else { return false }
        switch (from, place.area) {
        case (.open, .kept):
            return keep(group: id, at: place.index)
        case (.kept, .open):
            return open(group: id, at: place.index)
        case (.kept, .kept):
            var items = ownKeptItems()
            guard let at = items.firstIndex(where: { $0.group?.id == id }) else { return false }
            objectWillChange.send()
            let item = items.remove(at: at)
            let to = (place.index ?? items.count + everywhereRows.count) - everywhereRows.count
            items.insert(item, at: min(max(to, 0), items.count))
            applyKept(items)
            writeSession(now: true)
            return true
        case (.open, .open):
            let items = sideItems
            guard items.contains(where: { $0.id == .group(id) }) else { return false }
            moveItem(.group(id), to: min(max(place.index ?? items.count - 1, 0), items.count - 1))
            writeSession(now: true)
            return true
        }
    }

    /// An open group above the line, at `index` among the kept items.
    private func keep(group id: UUID, at index: Int?) -> Bool {
        guard let group = tabGroups.first(where: { $0.id == id }) else { return false }
        let members = tabs(in: id)
        objectWillChange.send()
        // Into the pins store first, so the rows pinned into it find it,
        // here and in every other window of the space.
        saveKeptGroups(keptGroups.filter { $0.id != id } + [group])
        for tab in members {
            leaveSplit(tab)
            // Out of the open group, which goes with its last tab.
            makePin(tab, listed: true)
            tab.keptGroupID = id
        }
        tabGroups.removeAll { $0.id == id }
        var items = ownKeptItems()
        if let at = items.firstIndex(where: { $0.group?.id == id }) {
            let item = items.remove(at: at)
            let to = (index ?? items.count + everywhereRows.count) - everywhereRows.count
            items.insert(item, at: min(max(to, 0), items.count))
        }
        applyKept(items)
        writeSession(now: true)
        return true
    }

    /// A kept group below the line, at `index` among the open items: an
    /// open group of this window's, holding this window's tabs for its rows,
    /// unpinned where they are. The other windows of the space close theirs,
    /// as when a pin is unpinned in one: open tabs are a window's own.
    private func open(group id: UUID, at index: Int?) -> Bool {
        guard let group = keptGroups.first(where: { $0.id == id }) else { return false }
        let members = tabs.filter { fitsKeptGroup($0) && $0.keptGroupID == id }
        objectWillChange.send()
        if !tabGroups.contains(where: { $0.id == id }) { tabGroups.append(group) }
        for tab in members {
            release(tab)
            tab.groupID = id
        }
        // Ordinary tabs now, still among the pins: their run goes to its
        // place among the tabs.
        let shown = displayedTabs
        var items = items(of: shown)
        if let at = items.firstIndex(where: { $0.id == .group(id) }) {
            let item = items.remove(at: at)
            items.insert(item, at: min(max(index ?? items.count, 0), items.count))
        }
        rearrangeTabs(expandingPairs(shown.filter { $0.pin != nil } + items.flatMap(\.tabs)))
        arrangeGroupedTabs()
        // The rows out of the pins, then the group out of the store.
        writeSession(now: true)
        saveKeptGroups(keptGroups.filter { $0.id != id })
        return true
    }
}
