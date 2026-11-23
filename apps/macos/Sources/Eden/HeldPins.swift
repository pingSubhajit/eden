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

    /// Whether `pin` is a row of the space on screen held as data.
    func holds(pin id: UUID) -> Bool {
        heldPins[spaceID]?.contains { $0.held.contains(id) } == true
    }

    /// Every row held as data in the space on screen, folder by folder.
    var heldRows: [PinDef] {
        (heldPins[spaceID] ?? []).flatMap { group in group.rows.filter(group.held.contains).compactMap(Pins.def(_:)) }
    }

    /// A kept group's rows held as data in the space on screen, in order.
    func heldRows(ofGroup id: UUID) -> [PinDef] {
        guard let group = heldPins[spaceID]?.first(where: { $0.id == id }) else { return [] }
        return group.rows.filter(group.held.contains).compactMap(Pins.def(_:))
    }

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

    /// Every row of a folder held as data made a tab, for what takes the
    /// folder's rows out of it or acts on them all.
    func showHeld(group id: UUID) {
        let rows = heldRows(ofGroup: id)
        guard !rows.isEmpty else { return }
        pinsChanged(in: spaceID, opening: Set(rows.map(\.id)))
    }

    /// The tab of `id`, or, for a row held as data, which the address field
    /// offers by its pin (heldOffers), the tab made for it.
    func openTab(_ id: UUID) -> Tab? {
        tabs.first { $0.id == id } ?? showHeld(id)
    }

    /// The rows held as data whose name or page holds `needle` (lowercased),
    /// offered in the address field as open pages are, by their pin.
    func heldOffers(matching needle: String, limit: Int) -> [Suggestion] {
        guard limit > 0, let held = heldPins[spaceID] else { return [] }
        var out: [Suggestion] = []
        for group in held {
            for id in group.rows where group.held.contains(id) {
                guard let def = Pins.def(id), let url = URL(string: def.home) else { continue }
                let address = Address.pretty(url)
                let label = def.name.flatMap { $0.isEmpty ? nil : $0 } ?? (def.title.isEmpty ? address : def.title)
                guard label.lowercased().contains(needle) || address.contains(needle) else { continue }
                out.append(Suggestion(key: label, title: address, url: url, kind: .open, tab: id))
                if out.count == limit { return out }
            }
        }
        return out
    }
}
