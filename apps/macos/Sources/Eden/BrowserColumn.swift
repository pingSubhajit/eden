import EdenCore
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
    /// and the empty ones after the group before them. A folded group whose
    /// rows are held as data stands where it stood (HeldPins.swift).
    func keptItems() -> [SideItem] {
        keptItems(listedPins, space: spaceID)
    }

    /// The same for any space's rows and kept groups: another space's,
    /// passing in a swipe, too.
    func keptItems(_ rows: [Tab], space: UUID) -> [SideItem] {
        let everywhere = rows.filter(\.everywhere).map(SideItem.tab)
        let own = rows.filter { !$0.everywhere && !$0.shy }
        return everywhere + ownItems(own, space: space)
    }

    /// A space's own rows as the kept area draws them, with the groups
    /// held as data where they stand.
    private func ownItems(_ own: [Tab], space: UUID) -> [SideItem] {
        let groups = Pins.groups(space)
        let held = HeldPins.resolved(heldPins[space] ?? [], present: Set(own.compactMap(\.pinID)),
                                     folders: HeldPins.folders(own, pin: \.pinID, group: \.keptGroupID), groups: groups) {
            Pins.defs(space)
        }
        return HeldPins.items(own, pin: \.pinID, group: \.keptGroupID, groups: groups, held: held)
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
        // Out of the folder, its rows are on show: made tabs first, where
        // they stand (HeldPins.swift).
        showHeld(group: id)
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
        ownItems(tabs.filter { fitsKeptGroup($0) && !leaving.contains($0.id) }, space: spaceID)
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
        // The groups held as data stay where `items` has them, for the row
        // to be written with them there (HeldPins.swift).
        if let held = heldPins[spaceID] { heldPins[spaceID] = HeldPins.standing(items, pin: \.pinID, held: held) }
        // Each group found by its id: looked for along the others, and each
        // not drawn looked for along the order, a folder moved among 750
        // folded ones took 40 ms in a test build.
        let kept = keptGroups
        let order = flat.groups.map(\.id)
        let byID = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let drawn = Set(order)
        let standing = order.compactMap { byID[$0] } + kept.filter { !drawn.contains($0.id) }
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
            return prefs.usesTabGroups
                && (tabs.contains { fitsKeptGroup($0) && $0.keptGroupID == id } || !heldRows(ofGroup: id).isEmpty)
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
        noteMoved([tab.id])
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

    /// A pinned row of this space's own moved to where another stands
    /// (`target`, a tab's id or a row's held as data, by the id its tab
    /// has), as chrome.tabs.move asks: into the target's folder, or the top
    /// level, at its place — after it when moving down the row (`forward`),
    /// before it moving up — as the column's carry puts a row there
    /// (move(_:to:)). The target's folder, if any of its rows are held as
    /// data, has them made tabs for the move, whether the target is one of
    /// them or not, so it lands among them exactly, as the extension sees
    /// the row, and they go back to data after. The row moved is kept a tab
    /// meanwhile (keepingOpen): one made a tab for the move, holding
    /// nothing yet, was let go to data again as the target's folder was
    /// made tabs, and the move had nothing to move. False, and nothing
    /// moved, unless both are such rows.
    @discardableResult
    func moveRow(_ tab: Tab, toRowOf target: Tab.ID, forward: Bool) -> Bool {
        guard fitsKeptGroup(tab), tabs.contains(where: { $0 === tab }) else { return false }
        return keepingOpen([tab.pinID].compactMap { $0 }) {
            let folder = heldPin(tab: target).flatMap { Pins.def($0)?.group } ?? tabs.first { $0.id == target }?.keptGroupID
            if let folder { showHeld(group: folder) }
            guard tabs.contains(where: { $0 === tab }), let anchor = tabs.first(where: { $0.id == target }), anchor !== tab,
                  fitsKeptGroup(anchor) else { return false }
            let group = keptGroup(of: anchor)
            let index: Int
            if let group {
                let members = members(ofGroup: group).filter { $0 !== tab }
                guard let at = members.firstIndex(where: { $0 === anchor }) else { return false }
                index = at + (forward ? 1 : 0)
            } else {
                let items = ownKeptItems(without: [tab.id])
                guard let at = items.firstIndex(where: { $0.id == .tab(anchor.id) }) else { return false }
                index = everywhereRows.count + at + (forward ? 1 : 0)
            }
            let moved = move(tab, to: ColumnPlace(area: .kept, group: group, index: index))
            // The rows made tabs for it, back to data.
            pinsChanged(in: spaceID)
            return moved
        }
    }

    /// What is carried with `tab` put at `place` (the column's carry): the
    /// tab alone, or with its pair, as move(_:to:detaching:) puts it; with
    /// several picked, everything picked that can stand there, pins of
    /// either kind and tabs alike (travelling), in their order. Tabs under
    /// the line alone carried into a group there, or out of one, are
    /// already carried together by those moves (carried(with:)).
    @discardableResult
    func move(carrying tab: Tab, to place: ColumnPlace, detaching: Bool = false) -> Bool {
        let moving = travelling(with: tab)
        guard !detaching, isPickedAmongOthers(tab), moving.count > 1,
              !(place.area == .open && moving.allSatisfy { $0.pin == nil }) else {
            return move(tab, to: place, detaching: detaching)
        }
        return move(together: moving, carrying: tab, to: place)
    }

    /// Several tabs, picked together, put at `place` as one, in their order:
    /// above the line pinned rows there, whatever they were — a row moved,
    /// a square made one, a tab pinned — and under it tabs there, pins
    /// unpinned. Those that can't go (takes) stay where they are: above
    /// the line, no pair. `carried`, the one in hand: its own place in the
    /// run was closed while it was carried, so `place.index` counts the run
    /// without it. They land in front of what stood there, the first place
    /// from it that stays, or at the end.
    private func move(together moving: [Tab], carrying carried: Tab, to place: ColumnPlace) -> Bool {
        let going = moving.filter { takes($0, at: place) }
        guard !going.isEmpty else { return false }
        noteMoved(going.map(\.id))
        let ids = Set(going.map(\.id))
        func stays(_ item: SideItem) -> Bool { item.tabs.contains { !ids.contains($0.id) } }
        objectWillChange.send()
        switch place.area {
        case .kept:
            // Among the rows every space shows, those that are theirs, as
            // move(_:to:) puts one; the rest in one go.
            let shared = going.filter { $0.pin != nil && $0.everywhere }
            let own = going.filter { tab in !shared.contains { $0 === tab } }
            // Where they land, found before anything moves.
            let run: [SideItem] = place.group.map { group in
                ownKeptItems().first { $0.group?.id == group }?.tabs.map(SideItem.tab) ?? []
            } ?? everywhereRows.map(SideItem.tab) + ownKeptItems()
            let places = run.filter { $0.id != .tab(carried.id) }
            let anchor = place.index.flatMap { at in places.indices.contains(at) ? places[at...].first(where: stays) : nil }
            if !own.isEmpty {
                for tab in own {
                    if tab.pin == nil {
                        leaveSplit(tab)
                        makePin(tab, listed: true)
                    } else if !tab.listed {
                        if editingPin == tab.id { editingPin = nil }
                        tab.listed = true
                    }
                }
                let items = ownKeptItems(without: ids)
                let index: Int? = anchor.map { anchor in
                    if place.group != nil {
                        let members = items.first { $0.group?.id == place.group }?.tabs ?? []
                        return members.firstIndex { SideItemID.tab($0.id) == anchor.id } ?? members.count
                    }
                    // Before a row every space shows: the head of this
                    // space's own.
                    return items.firstIndex { $0.id == anchor.id } ?? 0
                }
                applyKept(Browser.inserting(own, into: place.group, at: index, in: items))
            }
            // Each at the same place, the last first: they stand in order.
            for tab in shared.reversed() {
                if !tab.listed {
                    if editingPin == tab.id { editingPin = nil }
                    tab.listed = true
                }
                _ = moveEverywhereRow(tab, to: place.index)
            }
        case .open:
            // Where they land, found before anything moves: in the group, in
            // front of a tab of it; at the top of the area, in front of a
            // tab in no group or of a group.
            let anchor: Tab?
            if let group = place.group {
                let pair = split(for: carried)
                let peers = tabs(in: group).filter { standsInRow($0) && $0.id != carried.id && pair?.contains($0.id) != true }
                anchor = place.index.flatMap { at in peers.indices.contains(at) ? peers[at...].first { !ids.contains($0.id) } : nil }
            } else {
                let shown = prefs.usesTabGroups ? sideItems : displayedTabs.filter { $0.pin == nil }.map(SideItem.tab)
                let own = split(for: carried)?.left ?? carried.id
                let places = shown.filter { $0.id != .tab(own) }
                let item = place.index.flatMap { at in places.indices.contains(at) ? places[at...].first(where: stays) : nil }
                anchor = item?.tabs.first { !ids.contains($0.id) }
            }
            for tab in going where tab.pin != nil { unpin(tab) }
            let previous = Set(going.compactMap(\.groupID))
            for tab in going { tab.groupID = place.group }
            var row = tabs.filter { !ids.contains($0.id) }
            let before = anchor.map { split(for: $0)?.left ?? $0.id }
            let at = before.flatMap { id in row.firstIndex { $0.id == id } }
                ?? place.group.flatMap { group in row.lastIndex { $0.groupID == group }.map { $0 + 1 } }
                ?? row.count
            row.insert(contentsOf: going, at: min(max(at, 0), row.count))
            rearrangeTabs(row)
            if let group = place.group, let index = tabGroups.firstIndex(where: { $0.id == group }) {
                tabGroups[index].collapsed = false
            }
            for id in previous where id != place.group { removeEmptyGroup(id) }
        }
        writeSession(now: true)
        return true
    }

    /// Carried onto the squares (Browser.square), with the tabs picked with
    /// it, pins of either kind and tabs alike (travelling): each that can be
    /// one made a square there, in their order, in front of the square
    /// that stood at `slot`, or after them all.
    @discardableResult
    func square(carrying tab: Tab, at slot: Int) -> Bool {
        let moving = travelling(with: tab)
        guard isPickedAmongOthers(tab), moving.count > 1 else { return square(tab, at: slot) }
        let going = moving.filter { $0.pin == nil ? pinsByDrag($0) : true }
        guard !going.isEmpty else { return false }
        let ids = Set(going.map(\.id))
        // Where they land, found before anything moves.
        let squares = tabs.filter { $0.pin != nil && !$0.listed && $0.id != tab.id }
        let anchor = squares.indices.contains(slot) ? squares[slot...].first { !ids.contains($0.id) } : nil
        for each in going {
            if each.pin == nil { pin(each, listed: false) } else if each.listed { setListed(each, false) }
        }
        let made = going.filter { $0.pin != nil && !$0.listed }
        guard !made.isEmpty else { return false }
        let pins = tabs.filter { $0.pin != nil }
        var row = pins.filter { !$0.listed && !ids.contains($0.id) }
        let at = anchor.flatMap { anchor in row.firstIndex { $0.id == anchor.id } } ?? row.count
        row.insert(contentsOf: made, at: min(max(at, 0), row.count))
        // The squares every space shows keep the head of the squares, as
        // they always do (keepBlocks): those of the batch go among them,
        // the space's own after them, each in their order. Placed by
        // pinSlot, which counts the squares as they stand, mid-move, a
        // shared one just made a square was counted where nothing stood.
        row = row.filter(\.everywhere) + row.filter { !$0.everywhere }
        rearrangeTabs(row + pins.filter(\.listed) + tabs.filter { $0.pin == nil })
        writeSession(now: true)
        return true
    }

    /// The column as it stands, and what puts it back so: the row's order
    /// and each tab's group, in either area, and the groups under the line.
    /// For a carry that moved tabs on its way and is then kept where it
    /// was (Carried.keep): picked tabs moved with the one in hand, and one
    /// move back of that one alone left them where they went. False, and
    /// nothing changed, when a tab has come or gone since.
    func arrangement() -> () -> Bool {
        let order = tabs.map(\.id)
        let groups = Dictionary(tabs.map { ($0.id, ($0.groupID, $0.keptGroupID)) }, uniquingKeysWith: { first, _ in first })
        let open = tabGroups
        return { [weak self] in
            guard let self else { return false }
            let byID = Dictionary(self.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let row = order.compactMap { byID[$0] }
            guard row.count == self.tabs.count else { return false }
            for tab in row {
                guard let (group, kept) = groups[tab.id] else { continue }
                if tab.groupID != group { tab.groupID = group }
                if tab.keptGroupID != kept { tab.keptGroupID = kept }
            }
            if self.tabGroups != open { self.tabGroups = open }
            self.rearrangeTabs(row)
            self.writeSession(now: true)
            return true
        }
    }

    /// A pinned row carried along its run of the kept area — its folder, or
    /// the top of the area — to `index` there, the others making way (the
    /// column's carry): with the rows picked with it, all of them as one
    /// block in their order, as tabs under the line move (moveItem). It
    /// lands beside the nearest place passed that stays: the block's own
    /// rows aren't places to land by. Rows picked in another folder come
    /// into this run with it. Rows every space shows keep the head of the
    /// area, so with one of them in hand it moves alone (move(_:to:)).
    func moveKept(carrying tab: Tab, in group: UUID?, to index: Int) {
        let moving = carried(with: tab)
        noteMoved(moving.map(\.id))
        guard isPickedAmongOthers(tab), moving.count > 1, tab.listed, !moving.contains(where: \.everywhere) else {
            move(tab, to: ColumnPlace(area: .kept, group: group, index: index))
            return
        }
        let ids = Set(moving.map(\.id))
        var items = ownKeptItems()
        let run: [SideItem]
        if let group {
            run = items.first { $0.group?.id == group }?.tabs.map(SideItem.tab) ?? []
        } else {
            run = everywhereRows.map(SideItem.tab) + items
        }
        guard let from = run.firstIndex(where: { $0.id == .tab(tab.id) }), run.indices.contains(index), from != index else { return }
        func stays(_ item: SideItem) -> Bool {
            if case .tab(let other) = item { return !ids.contains(other.id) }
            return true
        }
        let down = from < index
        let passed = down ? Array(run[(from + 1)...index].reversed()) : Array(run[index..<from])
        guard let anchor = passed.first(where: stays) else { return }
        // Out of wherever they stand, a folder emptied by it staying.
        items = items.map { item in
            guard case .group(let held, let members) = item else { return item }
            return .group(held, members.filter { !ids.contains($0.id) })
        }.filter(stays)
        if let group, let at = items.firstIndex(where: { $0.group?.id == group }), case .group(let held, var members) = items[at] {
            let place = members.firstIndex { SideItemID.tab($0.id) == anchor.id }.map { down ? $0 + 1 : $0 } ?? members.count
            members.insert(contentsOf: moving, at: min(max(place, 0), members.count))
            items[at] = .group(held, members)
        } else {
            // Past a row every space shows: the head of this space's own.
            let place = items.firstIndex { $0.id == anchor.id }.map { down ? $0 + 1 : $0 } ?? 0
            items.insert(contentsOf: moving.map(SideItem.tab), at: min(max(place, 0), items.count))
        }
        objectWillChange.send()
        applyKept(items)
        writeSession(now: true)
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

    /// A group's rows as extensions have them, for telling which moved:
    /// its tabs, and its rows held as data by the ids they have to
    /// extensions (pinTabID). Its tabs alone left those out, and of a
    /// folded folder moved past a row the row was told as moved instead.
    private func rowIDs(ofGroup id: UUID) -> [Tab.ID] {
        guard rowFollowed else { return [] }
        let held = heldPins[spaceID]?.first { $0.id == id }
        return members(ofGroup: id).map(\.id) + (held.map { group in group.rows.filter(group.held.contains) } ?? []).map(pinTabID)
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
        noteMoved(rowIDs(ofGroup: id))
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
        // Its rows held as data made tabs first, to be this window's open
        // tabs (HeldPins.swift).
        showHeld(group: id)
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
