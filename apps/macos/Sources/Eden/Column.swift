import EdenCore
import Foundation

// The column under the squares is one tree in two areas: the kept area above
// the line, and the open area under it (#6). Each is an ordered list of
// items, a tab in no group or a group holding tabs, one level deep; a group
// is the same TabGroup in both. What sets them apart is where their things
// are kept, and nothing else:
//
// - Kept: a tab is a pinned row (Tab.listed, a PinDef with listed true), its
//   group the kept group's id (Tab.keptGroupID, PinDef.group), and the
//   groups themselves are kept with the pins (Pins.groups), per space,
//   shared by every window of it.
// - Open: a tab is an ordinary tab, its group Tab.groupID, and the groups
//   are the window's own (Browser.tabGroups), in its session.
//
// So which area a group is in is never a flag on it: it is in the kept area
// while the pins store holds it, and in the open area otherwise (see
// Browser.area(ofGroup:)). Moving a tab or a group across the line pins or
// unpins, and moves the group from one store to the other
// (BrowserColumn.swift).
//
// The order of an area is the order of its tabs, as the open area's always
// was: a group stands where its first tab stands, its tabs together. A kept
// group can be empty (made with nothing in it, or emptied), with no tab to
// stand by: it stands right after the group before it in the kept groups'
// own order, or first. That order is kept following what is drawn
// (Browser.arrangeKept), so an empty group stays where it was put, give or
// take the tabs in no group around it.

/// The two areas of the column under the squares.
enum ColumnArea: Equatable {
    case kept
    case open
}

/// One place in an area: a tab in no group, or a group with its tabs, all
/// of them, folded or not. `Member` is a tab, or a tab's id where only the
/// shape is worked out (ColumnTree).
enum ColumnItem<Member> {
    case tab(Member)
    case group(TabGroup, [Member])

    /// Its tabs, in order.
    var tabs: [Member] {
        switch self {
        case .tab(let tab): return [tab]
        case .group(_, let members): return members
        }
    }

    /// The group it is, if it is one.
    var group: TabGroup? {
        if case .group(let group, _) = self { return group }
        return nil
    }
}

extension ColumnItem: Equatable where Member: Equatable {}

/// The place in the run under the pins, as the column has always drawn
/// it (Browser.sideItems), and the kept area's the same way
/// (Browser.keptItems).
typealias SideItem = ColumnItem<Tab>

extension ColumnItem: Identifiable where Member == Tab {
    var id: SideItemID {
        switch self {
        case .tab(let tab): return .tab(tab.id)
        case .group(let group, _): return .group(group.id)
        }
    }
}

/// A place in an area by what stands there.
enum SideItemID: Hashable {
    case tab(UUID)
    case group(UUID)
}

/// One line of an area as drawn: a group's heading, or a tab, at the top of
/// the area or in a group.
enum ColumnLine<Member> {
    case heading(TabGroup)
    case tab(Member, group: UUID?)
}

extension ColumnLine: Equatable where Member: Equatable {}

extension ColumnLine: Identifiable where Member == Tab {
    var id: UUID {
        switch self {
        case .heading(let group): group.id
        case .tab(let tab, _): tab.id
        }
    }

    /// For the bench: what it is, how far in (1 in a group), and what it
    /// says. A kept group's heading still answers "folder", as the tests
    /// that read the column have always had it.
    @MainActor var described: [Any] {
        switch self {
        case .heading(let group): ["folder", 0, group.name, group.collapsed]
        case .tab(let tab, let group): ["pin", group == nil ? 0 : 1, tab.name ?? tab.title, false]
        }
    }
}

/// Where something carried along the column goes: an area, a group in it
/// (nil: the area's top level), and the index there, counted among what is
/// there with the thing carried taken out (nil: the end). At the top of the
/// kept area the index counts the rows every space shows, which keep the
/// head of it (Browser.keepBlocks); a space's own tab or group goes no
/// higher than after them.
struct ColumnPlace: Equatable {
    var area: ColumnArea
    var group: UUID? = nil
    var index: Int? = nil
}

/// The shape of an area worked out from its tabs and its groups: pure, the
/// same for both areas, so the tests can hold it.
enum ColumnTree {
    /// The area's items in order: each group where its first tab stands,
    /// with all its tabs, and each tab in no group. A tab whose group isn't
    /// among `groups` is in none. With `keepingEmpty`, a group with no tab
    /// stands right after the group before it in `groups`, or first; the
    /// open area has none (a group goes with its last tab), the kept area
    /// keeps them.
    static func items<Member>(_ members: [Member], group: (Member) -> UUID?, groups: [TabGroup],
                              keepingEmpty: Bool) -> [ColumnItem<Member>] {
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func home(_ member: Member) -> UUID? { group(member).flatMap { byID[$0] == nil ? nil : $0 } }
        var buckets: [UUID: [Member]] = [:]
        for member in members { if let id = home(member) { buckets[id, default: []].append(member) } }
        var seen = Set<UUID>()
        var out: [ColumnItem<Member>] = []
        for member in members {
            guard let id = home(member), let held = byID[id] else {
                out.append(.tab(member))
                continue
            }
            if seen.insert(id).inserted { out.append(.group(held, buckets[id] ?? [])) }
        }
        guard keepingEmpty else { return out }
        // Each empty group noted under the group before it, then put in as
        // the items are laid down again: looked for in `out` one by one,
        // a window's pins in 750 folded folders, none of them with a tab,
        // took 88 ms in a test build on every change to a pin.
        var after: [UUID?: [TabGroup]] = [:]
        var before: UUID?
        for held in groups {
            if seen.insert(held.id).inserted { after[before, default: []].append(held) }
            before = held.id
        }
        guard !after.isEmpty else { return out }
        var laid: [ColumnItem<Member>] = []
        laid.reserveCapacity(out.count + after.values.reduce(0) { $0 + $1.count })
        // Right after the group it follows, and the groups following it
        // right after it in turn; of two put after the same group, the
        // later one first, as inserting each there in turn had them.
        func lay(after id: UUID?) {
            var next = after[id] ?? []
            while let group = next.popLast() {
                laid.append(.group(group, []))
                next += after[group.id] ?? []
            }
        }
        lay(after: nil)
        for item in out {
            laid.append(item)
            if let id = item.group?.id { lay(after: id) }
        }
        return laid
    }

    /// The items laid flat again: every tab in order with the group it is
    /// in, and the groups in the order they stand, the empty ones too.
    static func flattened<Member>(_ items: [ColumnItem<Member>]) -> (members: [(member: Member, group: UUID?)], groups: [TabGroup]) {
        var members: [(member: Member, group: UUID?)] = []
        var groups: [TabGroup] = []
        var seen = Set<UUID>()
        for item in items {
            switch item {
            case .tab(let member):
                members.append((member, nil))
            case .group(let group, let held):
                guard seen.insert(group.id).inserted else { continue }
                groups.append(group)
                members += held.map { ($0, group.id) }
            }
        }
        return (members, groups)
    }

    /// The tabs in the order the area draws them, each group's together.
    static func ordered<Member>(_ members: [Member], group: (Member) -> UUID?, groups: [TabGroup]) -> [Member] {
        flattened(items(members, group: group, groups: groups, keepingEmpty: true)).members.map(\.member)
    }

    /// The lines drawn: each group's heading, then the tabs it shows —
    /// all of them, or folded only the one `showing` picks out, as a
    /// folded group keeps the tab you are on in sight — and each tab in
    /// no group.
    static func lines<Member>(_ items: [ColumnItem<Member>], showing: (Member) -> Bool = { _ in false }) -> [ColumnLine<Member>] {
        items.flatMap { item -> [ColumnLine<Member>] in
            switch item {
            case .tab(let member):
                return [.tab(member, group: nil)]
            case .group(let group, let members):
                let shown = group.collapsed ? members.filter(showing) : members
                return [.heading(group)] + shown.map { .tab($0, group: group.id) }
            }
        }
    }

    /// The groups less any not in `keeping` that hold nothing: an import
    /// that found every page of a folder already pinned makes no empty
    /// group for it.
    static func withoutEmpty(_ groups: [TabGroup], keeping: Set<UUID>, pins: [PinDef]) -> [TabGroup] {
        let holding = Set(pins.compactMap(\.group))
        return groups.filter { keeping.contains($0.id) || holding.contains($0.id) }
    }

    // MARK: - Arc's pinned list

    /// Arc's pinned list as kept rows in groups: each of its folders at the
    /// top a kept group here, unless one of the same name is already there,
    /// which is filled instead; the pages in its folders inside it go into
    /// it too, in the order they come, a group being one level deep.
    /// Returns the groups as they now are and each page with the group it
    /// goes in.
    static func fromArc(_ nodes: [ArcSidebar.Node], into groups: [TabGroup])
        -> (groups: [TabGroup], pages: [(item: ArcSidebar.Item, group: UUID?)]) {
        var groups = groups
        var pages: [(item: ArcSidebar.Item, group: UUID?)] = []
        func items(_ nodes: [ArcSidebar.Node]) -> [ArcSidebar.Item] {
            nodes.flatMap { node -> [ArcSidebar.Item] in
                switch node {
                case .item(let item): return [item]
                case .folder(let inner): return items(inner.items)
                }
            }
        }
        for node in nodes {
            switch node {
            case .item(let item):
                pages.append((item, nil))
            case .folder(let inner):
                let id: UUID
                if let same = groups.first(where: { $0.name.localizedCaseInsensitiveCompare(inner.title) == .orderedSame }) {
                    id = same.id
                } else {
                    id = UUID()
                    groups.append(TabGroup(id: id, name: inner.title, collapsed: false))
                }
                pages += items(inner.items).map { ($0, id) }
            }
        }
        return (groups, pages)
    }
}
