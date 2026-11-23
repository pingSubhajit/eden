import EdenCore
import Foundation

// Pinned rows a window holds as data rather than as tabs (#9). Every pinned
// row was a tab in every window's row, asleep or not, a folded folder's
// too: fifteen hundred bookmarks brought in as pins were fifteen hundred
// tabs, each with its web view's settings made, wired to the window, matched
// on every change to the pins and written into every session. A row in a
// folded folder isn't on screen, so it needn't be a tab: a window keeps it
// as its pin (PinDef, in the pins store) until its folder is unfolded or it
// is opened, and makes its tab then (Browser.reconcilePins). One shown and
// left asleep at its page again, holding nothing its pin doesn't
// (Tab.holdsNothing), goes back to being data the next time the pins are
// read; one with a page of its own, a history or its sound turned off stays
// a tab, as an open tab does.
//
// A pin held so is still every bit a pin: the pins store has it, sync
// carries it, chrome.bookmarks reads and changes it (PinShelf works on the
// store), the address field finds it (Browser.openPages), Copy All Links
// copies it, and a folder of them still counts for ⌘1–9.
//
// What a window must keep for the rows it holds is where they stand, for it
// writes the space's pins from its row (Browser.writeSession). A held row
// is always in a folded group, and a group's rows stand together, so that
// is where each such group stands: among the rows the window has tabs for,
// where its own tabs put it, or, while it has none, after the row it
// follows (HeldGroup.stands). The kept area is drawn (items), carried
// around (standing) and written (merged) from that, the same way each time.

/// A folded kept group whose rows, some or all, a window holds as data.
struct HeldGroup: Equatable {
    /// The kept group.
    let id: UUID
    /// Every row of the group in its order, as the window last read the
    /// pins: those held and those it has a tab for, so a row opened out of
    /// the folder keeps its place in it.
    var rows: [UUID]
    /// Those of `rows` held as data.
    var held: Set<UUID>
    /// Where the group stands while the window has a tab for none of its
    /// rows. Nil while it has one: the group stands where that tab does.
    var stands: Stand?

    enum Stand: Equatable {
        /// First of the space's own rows and groups.
        case first
        /// After the row of this pin, and the group that row is in.
        case after(UUID)
    }
}

/// The kept area's own rows, with the groups held as data put back where
/// they stand: what HeldPins works out each thing from.
enum HeldSlot<Member> {
    case row(Member)
    case held(HeldGroup)
}

@MainActor
enum HeldPins {
    /// The groups a window holds rows of, and where each stands, from the
    /// space's own rows as the pins store has them and the space's kept
    /// groups. `shown`: whether the window has (or is making) a tab for a
    /// row. Only a folded group's rows can be held. In the order drawn.
    static func hold(_ rows: [PinDef], groups: [TabGroup], shown: (PinDef) -> Bool) -> [HeldGroup] {
        var out: [HeldGroup] = []
        var last: UUID?
        for item in ColumnTree.items(rows, group: \.group, groups: groups, keepingEmpty: false) {
            switch item {
            case .tab(let row):
                if shown(row) { last = row.id }
            case .group(let group, let members):
                let showing = group.collapsed ? members.filter(shown) : members
                if showing.count < members.count {
                    let shownIDs = Set(showing.map(\.id))
                    let stands: HeldGroup.Stand? = showing.isEmpty ? last.map(HeldGroup.Stand.after) ?? .first : nil
                    out.append(HeldGroup(id: group.id, rows: members.map(\.id),
                                         held: Set(members.map(\.id).filter { !shownIDs.contains($0) }), stands: stands))
                }
                if let row = showing.last { last = row.id }
            }
        }
        return out
    }

    /// The kept area's own items, the groups held as data where they stand:
    /// `rows` the own rows the window has tabs for, in its order, each with
    /// its pin's id (`pin`) and its group (`group`).
    static func slots<Member>(_ rows: [Member], pin: (Member) -> UUID?, group: (Member) -> UUID?,
                              groups: [TabGroup], held: [HeldGroup]) -> [ColumnItem<HeldSlot<Member>>] {
        let standing = held.filter { $0.stands != nil }
        let placed = Set(standing.map(\.id))
        // A standing group's rows that have a tab now (one dropped into the
        // folder, or brought back into it) are drawn where it stands.
        var joined: [UUID: [Member]] = [:]
        var rest: [Member] = []
        for row in rows {
            if let id = group(row), placed.contains(id) { joined[id, default: []].append(row) } else { rest.append(row) }
        }
        let present = Set(rows.compactMap(pin))
        var first: [HeldGroup] = []
        var after: [UUID: [HeldGroup]] = [:]
        for held in standing {
            switch held.stands {
            case .after(let id)? where present.contains(id): after[id, default: []].append(held)
            default: first.append(held)
            }
        }
        var out: [HeldSlot<Member>] = []
        func put(_ held: HeldGroup) {
            out.append(.held(held))
            (joined[held.id] ?? []).forEach(emit)
        }
        func emit(_ row: Member) {
            out.append(.row(row))
            if let id = pin(row) { after.removeValue(forKey: id)?.forEach(put) }
        }
        first.forEach(put)
        rest.forEach(emit)
        let partly = Dictionary(held.filter { $0.stands == nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ColumnTree.items(out, group: { slot in
            switch slot {
            case .row(let row): group(row)
            case .held(let held): held.id
            }
        }, groups: groups, keepingEmpty: true).map { item in
            // A group partly held is drawn where its tabs are; its held rows
            // go with it when it is written (merged).
            guard case .group(let group, let members) = item, let held = partly[group.id] else { return item }
            return .group(group, members + [.held(held)])
        }
    }

    /// The kept area's own items as drawn: the groups held as data where
    /// they stand, showing only the rows the window has tabs for.
    static func items<Member>(_ rows: [Member], pin: (Member) -> UUID?, group: (Member) -> UUID?,
                              groups: [TabGroup], held: [HeldGroup]) -> [ColumnItem<Member>] {
        guard !held.isEmpty else { return ColumnTree.items(rows, group: group, groups: groups, keepingEmpty: true) }
        return slots(rows, pin: pin, group: group, groups: groups, held: held).compactMap { item in
            switch item {
            case .tab(.row(let row)): return .tab(row)
            // Its group gone: nothing of it to draw until the pins are read
            // again, and its rows made tabs at the top (merged keeps them).
            case .tab(.held): return nil
            case .group(let group, let slots):
                return .group(group, slots.compactMap { slot in
                    if case .row(let row) = slot { return row }
                    return nil
                })
            }
        }
    }

    /// The held groups as `items` now stand, after the kept area was
    /// changed around them (Browser.applyKept): each with no tab among its
    /// rows stands after the row now before it, and they are in the order
    /// drawn.
    static func standing<Member>(_ items: [ColumnItem<Member>], pin: (Member) -> UUID?, held: [HeldGroup]) -> [HeldGroup] {
        guard !held.isEmpty else { return held }
        var left = Dictionary(held.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [HeldGroup] = []
        var last: UUID?
        for item in items {
            switch item {
            case .tab(let row):
                if let id = pin(row) { last = id }
            case .group(let group, let members):
                if var held = left.removeValue(forKey: group.id) {
                    if held.stands != nil || members.isEmpty { held.stands = last.map(HeldGroup.Stand.after) ?? .first }
                    out.append(held)
                }
                if let id = members.last.flatMap(pin) { last = id }
            }
        }
        // Not among the items (its group gone): kept, for its rows are.
        return out + held.filter { left[$0.id] != nil }
    }

    /// Each group whose place is lost put back where the pins store has it:
    /// one that stands after a row no longer among `present` (the rows the
    /// window has tabs for), or that stood by its tabs and has none left in
    /// it (`folders`: the folder each of those rows is in, if any), stands
    /// after the nearest row before it that is, in the order `stored` (the
    /// space's own pins, asked only when needed) has them. A row taken out
    /// of the folder is no tab of the folder's: counted as one, the folder
    /// had no place, and went where an empty one does.
    static func resolved(_ held: [HeldGroup], present: Set<UUID>, folders: [UUID: UUID], groups: [TabGroup],
                         stored: () -> [PinDef]) -> [HeldGroup] {
        func lost(_ held: HeldGroup) -> Bool {
            switch held.stands {
            case .after(let id)?: !present.contains(id)
            case .first?: false
            case nil: !held.rows.contains { folders[$0] == held.id }
            }
        }
        guard held.contains(where: lost) else { return held }
        let order = ColumnTree.ordered(stored().filter { $0.listed == true }, group: \.group, groups: groups).map(\.id)
        let place = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return held.map { held in
            guard lost(held) else { return held }
            var held = held
            let after: UUID? = if case .after(let id)? = held.stands { id } else { nil }
            let from = after.flatMap { place[$0] } ?? held.rows.compactMap { place[$0] }.min() ?? 0
            let before = order[..<min(from, order.count)].last { present.contains($0) }
            held.stands = before.map(HeldGroup.Stand.after) ?? .first
            return held
        }
    }

    /// The folder each of `rows` is in, by its pin, for those in one.
    static func folders<Member>(_ rows: [Member], pin: (Member) -> UUID?, group: (Member) -> UUID?) -> [UUID: UUID] {
        var out: [UUID: UUID] = [:]
        for row in rows { if let id = pin(row), let folder = group(row) { out[id] = folder } }
        return out
    }

    /// The space's own pins as a window writes them (Browser.writeSession):
    /// `own` those it has tabs for, squares and rows, in its order, and the
    /// rows it holds as data back in their groups, as the pins store has
    /// them now (`stored`), each group where it stands. A held row the store
    /// no longer has is gone, taken out elsewhere; one whose group has gone
    /// meanwhile stays, where the group stood. Returns the held groups too,
    /// each standing after a row that is still there.
    static func merged(_ own: [PinDef], held: [HeldGroup], stored: [PinDef], groups: [TabGroup])
        -> (pins: [PinDef], held: [HeldGroup]) {
        guard !held.isEmpty else { return (own, held) }
        let squares = own.filter { $0.listed != true }
        let rows = own.filter { $0.listed == true }
        let held = resolved(held, present: Set(rows.map(\.id)), folders: HeldPins.folders(rows, pin: \.id, group: \.group),
                            groups: groups, stored: { stored })
        let kept = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let written = Set(rows.map(\.id))
        // The folder's tabs in the window's order, so a move among them, or
        // a row moved in among them, stands, and each run of its held rows
        // right after the row it followed (nil: the head of the folder):
        // walking the folder's old rows for its tabs too put them back in
        // the order the folder had, and undid the move.
        func block(_ held: HeldGroup, among members: [PinDef]) -> [PinDef] {
            let present = Set(members.map(\.id))
            var after: [UUID?: [UUID]] = [:]
            var last: UUID?
            for id in held.rows {
                if present.contains(id) {
                    last = id
                } else if held.held.contains(id) {
                    after[last, default: []].append(id)
                }
            }
            var out: [PinDef] = []
            func run(_ id: UUID?) {
                for row in after.removeValue(forKey: id) ?? [] where !written.contains(row) { if let def = kept[row] { out.append(def) } }
            }
            run(nil)
            for member in members {
                out.append(member)
                run(member.id)
            }
            return out
        }
        var out = squares
        for item in slots(rows, pin: \.id, group: \.group, groups: groups, held: held) {
            switch item {
            case .tab(.row(let row)):
                out.append(row)
            case .tab(.held(let held)):
                out += block(held, among: [])
            case .group(_, let slots):
                let members = slots.compactMap { slot -> PinDef? in
                    if case .row(let row) = slot { return row }
                    return nil
                }
                let found = slots.lazy.compactMap { slot -> HeldGroup? in
                    if case .held(let held) = slot { return held }
                    return nil
                }.first
                out += found.map { block($0, among: members) } ?? members
            }
        }
        return (out, held)
    }
}

/// A window's pinned tabs, found for each pin in one walk of the row, as
/// Browser.reconcilePins looks for them: by the pin's id; else a tab whose
/// pin was merged into this one on another device, by its page; else one
/// from before pins had ids, by letter and page, then by place. Each way is
/// indexed once, so a row with pins held as data among its tabs, every one
/// of them looked for and not found, costs one walk rather than one a pin.
@MainActor
struct PinnedTabs {
    private var byID: [UUID: Tab] = [:]
    /// Each list in reverse, so its first in the row is its last.
    private var merged: [String: [Tab]] = [:]
    private var lettered: [String: [Tab]] = [:]
    private var unnamed: [Tab] = []
    private var taken = Set<ObjectIdentifier>()
    private let row: [Tab]

    /// `live`: the pins the row is made from; a tab whose pin isn't among
    /// them was merged into another.
    init(_ row: [Tab], live: Set<UUID>) {
        self.row = row
        for tab in row.reversed() {
            if let id = tab.pinID {
                byID[id] = tab
                if !live.contains(id), let home = tab.home { merged[PinDef.page(home), default: []].append(tab) }
            } else {
                lettered[Self.key(tab.pin, tab.home?.absoluteString ?? ""), default: []].append(tab)
                unnamed.append(tab)
            }
        }
    }

    /// The tab for `def`, taken so no other pin has it.
    mutating func take(for def: PinDef, home: URL?) -> Tab? {
        var found = byID[def.id].flatMap { taken.contains(ObjectIdentifier($0)) ? nil : $0 }
        if found == nil, let home { found = Self.first(&merged[PinDef.page(home), default: []], skipping: taken) }
        if found == nil { found = Self.first(&lettered[Self.key(def.letter, def.home), default: []], skipping: taken) }
        if found == nil { found = Self.first(&unnamed, skipping: taken) }
        if let found { taken.insert(ObjectIdentifier(found)) }
        return found
    }

    /// The tabs no pin took.
    var left: [Tab] { row.filter { !taken.contains(ObjectIdentifier($0)) } }

    private static func key(_ letter: String?, _ home: String) -> String { (letter ?? "") + "\u{0}" + home }

    private static func first(_ list: inout [Tab], skipping taken: Set<ObjectIdentifier>) -> Tab? {
        while let last = list.last, taken.contains(ObjectIdentifier(last)) { list.removeLast() }
        return list.popLast()
    }
}

/// A place in a window's row as extensions see it (Extensions.swift): a
/// tab, or a pinned row held as data, by the id its tab has in that window
/// (Browser.pinTabID), the same before and after it is held.
enum RowPlace {
    case tab(Tab)
    case held(pin: UUID, id: Tab.ID)

    var id: Tab.ID {
        switch self {
        case .tab(let tab): tab.id
        case .held(_, let id): id
        }
    }
}

extension Browser {
    /// The pins of a space's own rows held as data when their tab holds
    /// nothing: every row in a folded kept group. Not those every space
    /// shows, which are in no group.
    func holdable(in space: UUID) -> Set<UUID> {
        let folded = Set(Pins.groups(space).filter(\.collapsed).map(\.id))
        guard !folded.isEmpty else { return [] }
        let everywhere = prefs.showsSharedPins ? Set(Pins.shared(profileID).map(\.id)) : []
        return Set(Pins.defs(space).filter { def in
            def.listed == true && !everywhere.contains(def.id) && def.group.map(folded.contains) == true
        }.map(\.id))
    }

    // MARK: - which rows are held

    /// Whether `pin` is a row of `space` (the one on screen unless named)
    /// held as data.
    func holds(pin id: UUID, in space: UUID? = nil) -> Bool {
        heldPins[space ?? spaceID]?.contains { $0.held.contains(id) } == true
    }

    /// The pin of the row held as data in the space on screen whose tab,
    /// made again, would be `id` (pinTabID).
    func heldPin(tab id: Tab.ID) -> UUID? {
        guard let pin = pinOfTabID[id], holds(pin: pin) else { return nil }
        return pin
    }

    /// The pins held as data in `space`, folder by folder.
    func heldPinIDs(in space: UUID) -> [UUID] {
        (heldPins[space] ?? []).flatMap { group in group.rows.filter(group.held.contains) }
    }

    /// Every row held as data in the space on screen, folder by folder.
    var heldRows: [PinDef] { heldPinIDs(in: spaceID).compactMap(Pins.def(_:)) }

    /// A kept group's rows held as data in the space on screen, in order.
    func heldRows(ofGroup id: UUID) -> [PinDef] {
        guard let group = heldPins[spaceID]?.first(where: { $0.id == id }) else { return [] }
        return group.rows.filter(group.held.contains).compactMap(Pins.def(_:))
    }

    // MARK: - the tab a held row has when it is made one

    /// The id the tab of one of a space's own pinned rows has in this
    /// window: the same each time it is made again after being held, so
    /// what knew the tab by it — an extension, the address field, a card —
    /// finds it again.
    func pinTabID(_ pin: UUID) -> Tab.ID {
        if let id = pinTabIDs[pin] { return id }
        let id = UUID()
        keepTabID(id, forPin: pin)
        return id
    }

    // MARK: - made tabs

    /// A row held as data made a tab, where it stands in its folder, which
    /// stays folded, to be gone to: from the address field, a number key, or
    /// its folder's card. Its tab, if it already has one; nil for a pin the
    /// space on screen doesn't have.
    @discardableResult
    func showHeld(_ pin: UUID) -> Tab? {
        if let tab = tabs.first(where: { $0.pin != nil && $0.pinID == pin }) { return tab }
        guard holds(pin: pin) else { return nil }
        pinsChanged(in: spaceID, opening: [pin])
        return tabs.first { $0.pin != nil && $0.pinID == pin }
    }

    /// `body` run with the rows of `pins` kept tabs throughout, whatever
    /// reads the pins again meanwhile (keptOpen); after, those that hold
    /// nothing their pins don't, in a folded folder, go back to data.
    func keepingOpen<T>(_ pins: [UUID], _ body: () throws -> T) rethrows -> T {
        for pin in pins { keptOpen[pin, default: 0] += 1 }
        defer {
            var released = false
            for pin in pins {
                guard let count = keptOpen[pin] else { continue }
                keptOpen[pin] = count > 1 ? count - 1 : nil
                released = released || count == 1
            }
            if released, !holdable(in: spaceID).isDisjoint(with: pins) { pinsChanged(in: spaceID) }
        }
        return try body()
    }

    /// Every row of a folder held as data made a tab, for what takes the
    /// folder's rows out of it or acts on them all.
    func showHeld(group id: UUID) {
        let rows = heldRows(ofGroup: id)
        guard !rows.isEmpty else { return }
        pinsChanged(in: spaceID, opening: Set(rows.map(\.id)))
    }

    /// The tab of `id`, or the tab made for the row held as data whose tab
    /// it would be (heldPin(tab:)), as the address field, the launcher and
    /// an extension offer such a row.
    func openTab(_ id: Tab.ID) -> Tab? {
        tabs.first { $0.id == id } ?? heldPin(tab: id).flatMap(showHeld)
    }

    /// Whether `id` is a tab of this window, or a row held as data in its
    /// space on screen that would be made one by that id.
    func hasTab(_ id: Tab.ID) -> Bool {
        tabs.contains { $0.id == id } || heldPin(tab: id) != nil
    }

    // MARK: - when each was last looked at

    /// When a row held as data was last looked at, as its tab had it before
    /// it was let go, or the session (heldLooks); nil when it never was.
    func lookedAt(heldPin pin: UUID) -> Date? { heldLooks[pin] }

    /// A folded folder's row held as data looked at last, or its first when
    /// none was, for what goes to the row of a folder you were in last.
    func lastLooked(heldOf group: UUID) -> PinDef? {
        heldPins[spaceID]?.first { $0.id == group }.flatMap(lastLooked(in:))
    }

    /// The same for a held group in hand: ⌘1–9's targets look it up once
    /// for every folder (tabShortcutTargets), where looking for each among
    /// the held groups made 750 folded folders 31 ms a look, and a look
    /// each time ⌘ is held for the hints.
    func lastLooked(in group: HeldGroup) -> PinDef? {
        var best: (def: PinDef, at: Date)?
        var first: PinDef?
        for pin in group.rows where group.held.contains(pin) {
            guard let def = Pins.def(pin) else { continue }
            if first == nil { first = def }
            guard let at = heldLooks[pin] else { continue }
            if best.map({ at > $0.at }) ?? true { best = (def, at) }
        }
        return best?.def ?? first
    }

    // MARK: - by their pages

    /// The rows held as data in `space`, by their pages (History.identity):
    /// worked out once each time the rows held change.
    func heldPages(in space: UUID) -> [String: UUID] {
        if let known = heldPageCache[space] { return known }
        var pages: [String: UUID] = [:]
        for pin in heldPinIDs(in: space) {
            guard let home = Pins.def(pin).flatMap({ URL(string: $0.home) }) else { continue }
            let identity = History.identity(for: home)
            if pages[identity] == nil { pages[identity] = pin }
        }
        heldPageCache[space] = pages
        return pages
    }

    /// The row held as data in the space on screen at the same page as
    /// `url`, as a tab at its home matches it (Browser.samePage).
    func heldPin(at url: URL) -> PinDef? {
        let page = PinDef.page(url)
        return heldRows.first { URL(string: $0.home).map(PinDef.page) == page }
    }

    // MARK: - the address field

    /// The rows held as data whose name or page holds `needle` (lowercased),
    /// with when each was last looked at, offered in the address field as
    /// open pages are, by the id their tab will have (pinTabID). With
    /// nothing typed, only those that have been looked at: the rest were
    /// never open.
    func heldOffers(matching needle: String) -> [(at: Date?, offer: Suggestion)] {
        guard let held = heldPins[spaceID] else { return [] }
        var out: [(at: Date?, offer: Suggestion)] = []
        for group in held {
            for id in group.rows where group.held.contains(id) {
                let at = heldLooks[id]
                if needle.isEmpty, at == nil { continue }
                guard let def = Pins.def(id), let url = URL(string: def.home) else { continue }
                let address = Address.pretty(url)
                let label = def.name.flatMap { $0.isEmpty ? nil : $0 } ?? (def.title.isEmpty ? address : def.title)
                guard needle.isEmpty || label.lowercased().contains(needle) || address.contains(needle) else { continue }
                out.append((at, Suggestion(key: label, title: address, url: url, kind: .open, tab: pinTabID(id))))
            }
        }
        return out
    }

    // MARK: - the row, as extensions see it

    /// The row of the space on screen with its rows held as data in their
    /// places among its tabs, as written (HeldPins.merged): what extensions
    /// are shown, a held row as a tab at rest by the id its tab will have.
    /// The row itself while nothing is held.
    var placesInRow: [RowPlace] {
        guard let held = heldPins[spaceID], !held.isEmpty else { return tabs.map(RowPlace.tab) }
        let own = tabs.filter(fitsKeptGroup)
        let ownIDs = Set(own.map(\.id))
        let resolved = HeldPins.resolved(held, present: Set(own.compactMap(\.pinID)),
                                         folders: HeldPins.folders(own, pin: \.pinID, group: \.keptGroupID), groups: keptGroups) {
            Pins.defs(spaceID)
        }
        // As merged writes the folder: its tabs in the row's order, each
        // run of its held rows after the row it followed.
        func rows(of held: HeldGroup, among members: [Tab]) -> [RowPlace] {
            let present = Set(members.compactMap(\.pinID))
            var after: [UUID?: [UUID]] = [:]
            var last: UUID?
            for pin in held.rows {
                if present.contains(pin) {
                    last = pin
                } else if held.held.contains(pin) {
                    after[last, default: []].append(pin)
                }
            }
            var out: [RowPlace] = []
            func run(_ pin: UUID?) { out += (after.removeValue(forKey: pin) ?? []).map { .held(pin: $0, id: pinTabID($0)) } }
            run(nil)
            for tab in members {
                out.append(.tab(tab))
                run(tab.pinID)
            }
            return out
        }
        var ownPlaces: [RowPlace] = []
        for item in HeldPins.slots(own, pin: \.pinID, group: \.keptGroupID, groups: keptGroups, held: resolved) {
            switch item {
            case .tab(.row(let tab)): ownPlaces.append(.tab(tab))
            case .tab(.held(let held)): ownPlaces += rows(of: held, among: [])
            case .group(_, let slots):
                let members = slots.compactMap { slot -> Tab? in
                    if case .row(let tab) = slot { return tab }
                    return nil
                }
                let found = slots.lazy.compactMap { slot -> HeldGroup? in
                    if case .held(let held) = slot { return held }
                    return nil
                }.first
                ownPlaces += found.map { rows(of: $0, among: members) } ?? members.map(RowPlace.tab)
            }
        }
        // The own rows go where the first of them stands in the row: after
        // the squares and the rows every space shows.
        var out: [RowPlace] = []
        var placed = false
        for tab in tabs {
            if ownIDs.contains(tab.id) {
                if !placed { out += ownPlaces; placed = true }
            } else {
                if !placed, tab.pin == nil || tab.shy { out += ownPlaces; placed = true }
                out.append(.tab(tab))
            }
        }
        if !placed { out += ownPlaces }
        return out
    }
}
