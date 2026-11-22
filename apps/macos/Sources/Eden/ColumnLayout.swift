import CoreGraphics
import Foundation

// The column under the squares laid out in one go (#6): your other devices'
// groups, the kept area, the line, the New Tab row and the open area, each
// line where the views draw it, worked out from what is there rather than
// measured as it is drawn. The views draw from it (SideBar), and every drop
// in the column reads it: which area the hand is over, which group, and
// where in it. So a tab, a pair or a group carried anywhere in the column
// lands where the rows parted for it, above the line as under it.
//
// Pure, and the same for both areas, so the tests can hold it. Generic over
// what a line is, as ColumnTree is: a Tab in the column, a tab's id in the
// tests.
//
// It follows the views' own stacking, which is all it has to agree with: an
// area's tabs and groups a gap apart; a group on its surface, its heading,
// then its rows a gap under it, set in; a tab one line, a pair two; your
// other devices' groups a gap apart, and a gap clear of the kept area under
// them; the kept area a gap clear of what comes under it; the line, the New
// Tab row at the top and the open area, a gap apart; the New Tab row at the
// foot a gap under them all. A row carried to a gap
// elsewhere takes no room (RowGapSource), and the gap takes the height of
// what is carried (RowGapSlot).

/// How tall the column's lines are, as the views draw them.
struct ColumnMetrics: Equatable {
    /// A tab's line (Preferences.sideRow): a pair stands as two.
    var row: CGFloat
    /// A group's heading inside its surface: GroupLook.heading(row:).
    var heading: CGFloat
    /// Between one line and the next (SideBar.gap).
    var gap: CGFloat
    /// Between a group's surface and what it holds (GroupLook.inset).
    var inset: CGFloat
    /// The line between the areas (KeepLine.height).
    var line: CGFloat
}

/// What another device's group draws under its heading (DeviceGroup): the
/// one rule its view and the column's layout both read, so the two can't
/// disagree on where everything under it stands. Its pages while it is
/// opened, and while a tab carried onto it shows where it goes, folded or
/// not; then the gap at their end for that tab too.
enum DeviceRows {
    /// Whether its rows are drawn.
    static func shown(opened: Bool, carried: Bool) -> Bool { opened || carried }

    /// The lines under its heading: its pages when drawn, and the gap.
    static func lines(pages: Int, opened: Bool, carried: Bool) -> Int {
        (shown(opened: opened, carried: carried) ? pages : 0) + (carried ? 1 : 0)
    }
}

/// A run something is carried along: the top level of an area, or a group
/// in it.
struct ColumnRun: Hashable {
    var area: ColumnArea
    var group: UUID? = nil
}

/// What the column does for something carried over it, the hand where it is.
enum ColumnAim: Equatable {
    /// It is along its own run, which makes way for it as it goes (Carried).
    case along
    /// Over a run that won't take it: it holds still, and nothing parts.
    case refused
    /// The rows part for it here.
    case place(ColumnPlace)
}

/// Something carried along the column, and where it would land were it let
/// go now: the one carry for the whole column (#6). It is a tab — a pair by
/// its first page — or a group; where it would land is a place in either
/// area (ColumnPlace), at its top level or in a group, or another device's
/// group. The rows there part for it by its height (the layout's gap), its
/// own place closes behind it, and letting go ends in the column's move for
/// a tab or a group (Browser.move(_:to:), move(group:to:)). Along its own
/// run there is none: the run makes way as it goes (Carried).
struct ColumnCarry: Equatable {
    enum Target: Equatable {
        case place(ColumnPlace)
        /// At the end of another device's group (DeviceGroup), by its id as
        /// it syncs: opened there too (Sync.askToOpen), and kept here.
        case device(String)
    }

    /// What is carried: a tab, by the first page of its pair if it is one,
    /// or a group.
    let carried: SideItemID
    let target: Target
    /// The room it needs: a tab's line, a pair's two, a group's whole height.
    let height: CGFloat
    /// The whole of what was picked up, rather than a pair's half leaving
    /// it, whose other half keeps the row's place.
    var whole = true

    var place: ColumnPlace? {
        if case .place(let place) = target { return place }
        return nil
    }

    /// Another device it would be opened on.
    var device: String? {
        if case .device(let id) = target { return id }
        return nil
    }

    /// The group it would go into, in either area.
    var group: UUID? { place?.group }

    /// Whether it leaves its own place for it: not for another device,
    /// where it is opened as well as kept here.
    var moves: Bool { device == nil }

    /// Whether its own place closes behind it: not for a copy, nor for a
    /// half whose pair stays.
    var empties: Bool { moves && whole }

    /// The run it would land in, to tell when it moves into another.
    var run: String {
        switch target {
        case .place(let place): return "\(place.area):\(place.group?.uuidString ?? "top")"
        case .device(let id): return "device:" + id
        }
    }

    /// How long a carried tab rests on a folded group before it opens.
    static let spring: TimeInterval = 0.5
    /// The gap's frame among a group's (GroupDropFrames): the hand over the
    /// gap is over its group.
    static let frameKey = UUID()
}

/// Lines stacked a gap apart, as a VStack stacks them, from where `y`
/// starts: each one's top, given its height.
private struct ColumnStack {
    let gap: CGFloat
    var y: CGFloat
    /// Whether anything is stacked yet: the gap goes between lines only.
    var placed = false

    /// Where the next line would start.
    var top: CGFloat { placed ? y + gap : y }

    mutating func next(_ height: CGFloat) -> CGFloat {
        let at = top
        placed = true
        y = at + height
        return at
    }
}

/// The column under the squares, laid out.
struct ColumnLayout<Member> {
    /// What stands at a place of an area or a group: a tab or a group by its
    /// id, or the gap open for something carried there.
    enum Slot: Hashable {
        case item(SideItemID)
        case gap
    }

    /// A tab's line, or a pair's lines.
    struct Row {
        let member: Member
        let id: UUID
        let frame: CGRect
        /// Carried to a gap elsewhere: its place is closed (RowGapSource).
        let away: Bool
    }

    /// A group on its surface: its heading and what shows under it.
    struct Group {
        let group: TabGroup
        let frame: CGRect
        let heading: CGRect
        /// Its rows drawn: what it shows, or a gap opened in it folded.
        let showsRows: Bool
        /// Its rows, and the gap if one is open in it.
        let rows: [Piece]
        /// Carried to a gap in the other area: its place is closed.
        let away: Bool

        /// The rows it shows, the gap left out.
        var members: [Row] {
            rows.compactMap { if case .row(let row) = $0 { return row }; return nil }
        }
    }

    enum Piece: Identifiable {
        case row(Row)
        case group(Group)
        case gap(CGRect)

        var id: Slot {
            switch self {
            case .row(let row): .item(.tab(row.id))
            case .group(let held): .item(.group(held.group.id))
            case .gap: .gap
            }
        }

        var frame: CGRect {
            switch self {
            case .row(let row): row.frame
            case .group(let held): held.frame
            case .gap(let rect): rect
            }
        }

        var away: Bool {
            switch self {
            case .row(let row): row.away
            case .group(let held): held.away
            case .gap: false
            }
        }
    }

    /// An area: its pieces in order, and how many of its first items are
    /// rows every space shows, which keep the head of the kept area.
    struct Area {
        let area: ColumnArea
        let pieces: [Piece]
        let head: Int
    }

    /// Another device's group, under the kept area.
    struct Device {
        let id: String
        let frame: CGRect
        let gap: CGRect?
    }

    /// What there is to lay out: each area's items as they are drawn — a
    /// group with the tabs it shows, all of them, or folded only the one in
    /// front — your other devices' groups with how many pages each has and
    /// whether it is opened (what it shows of them is DeviceRows'), whether
    /// the line is drawn, and where the New Tab row goes.
    struct Shape {
        var kept: [ColumnItem<Member>] = []
        /// How many of the kept items are rows every space shows, at its head.
        var keptHead = 0
        var open: [ColumnItem<Member>] = []
        var devices: [(id: String, pages: Int, opened: Bool)] = []
        var line = false
        var newTabOnTop = false
    }

    let metrics: ColumnMetrics
    let width: CGFloat
    let kept: Area
    let devices: [Device]
    let line: CGRect?
    let open: Area
    let newTab: CGRect
    /// The whole column under the squares, to the New Tab row's foot.
    let height: CGFloat

    subscript(area: ColumnArea) -> Area {
        switch area {
        case .kept: kept
        case .open: open
        }
    }

    // MARK: - laying it out

    /// `carry`: what is carried and where it would land, if anything: a gap
    /// that tall opens there, and its own place closes. `lines`: how many
    /// lines a tab stands as, two for a pair.
    init(_ shape: Shape, metrics: ColumnMetrics, width: CGFloat, carry: ColumnCarry? = nil,
         id: (Member) -> UUID, lines: (Member) -> Int = { _ in 1 }) {
        self.metrics = metrics
        self.width = width
        let m = metrics
        let target = carry?.place
        let closed = carry?.empties == true ? carry?.carried : nil
        func rect(_ y: CGFloat, _ height: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: width, height: height) }

        /// Where in a run the gap goes, if it is open there: before the
        /// index-th of what stands there, the one carried left out of the
        /// count, or after them all.
        func gap(in run: ColumnRun, among ids: [SideItemID]) -> Int? {
            guard let target, let carry, ColumnRun(area: target.area, group: target.group) == run else { return nil }
            var counted = 0
            for (at, item) in ids.enumerated() where item != carry.carried {
                if counted == target.index { return at }
                counted += 1
            }
            return ids.count
        }

        /// A tab's line, or the place it closed carried away, which takes
        /// no room.
        func row(_ member: Member, on stack: inout ColumnStack) -> Piece {
            let rowID = id(member)
            guard closed != .tab(rowID) else {
                return .row(Row(member: member, id: rowID, frame: rect(stack.y, 0), away: true))
            }
            let height = CGFloat(max(1, lines(member))) * m.row
            return .row(Row(member: member, id: rowID, frame: rect(stack.next(height), height), away: false))
        }

        /// The gap, when it is open here.
        func opening(_ here: Bool, on stack: inout ColumnStack) -> Piece? {
            guard here, let carry else { return nil }
            return .gap(rect(stack.next(carry.height), carry.height))
        }

        func rows(_ members: [Member], run: ColumnRun, top: CGFloat) -> (pieces: [Piece], bottom: CGFloat) {
            let at = gap(in: run, among: members.map { .tab(id($0)) })
            var stack = ColumnStack(gap: m.gap, y: top)
            var pieces: [Piece] = []
            for (index, member) in members.enumerated() {
                if let gap = opening(at == index, on: &stack) { pieces.append(gap) }
                pieces.append(row(member, on: &stack))
            }
            if let gap = opening(at == members.count, on: &stack) { pieces.append(gap) }
            return (pieces, stack.y)
        }

        func group(_ held: TabGroup, _ members: [Member], area: ColumnArea, top: CGFloat) -> Group {
            let run = ColumnRun(area: area, group: held.id)
            let heading = rect(top + m.inset, m.heading)
            let opened = target.map { ColumnRun(area: $0.area, group: $0.group) == run } ?? false
            let shows = !members.isEmpty || opened
            var pieces: [Piece] = []
            var bottom = heading.maxY
            if shows {
                let laid = rows(members, run: run, top: heading.maxY + m.gap)
                pieces = laid.pieces
                bottom = laid.bottom
            }
            let away = closed == .group(held.id)
            return Group(group: held, frame: rect(top, away ? 0 : bottom + m.inset - top), heading: heading,
                         showsRows: shows, rows: pieces, away: away)
        }

        func area(_ items: [ColumnItem<Member>], _ area: ColumnArea, top: CGFloat, head: Int) -> (area: Area, bottom: CGFloat) {
            let ids: [SideItemID] = items.map { item in
                switch item {
                case .tab(let member): .tab(id(member))
                case .group(let held, _): .group(held.id)
                }
            }
            let at = gap(in: ColumnRun(area: area), among: ids)
            var stack = ColumnStack(gap: m.gap, y: top)
            var pieces: [Piece] = []
            for (index, item) in items.enumerated() {
                if let gap = opening(at == index, on: &stack) { pieces.append(gap) }
                switch item {
                case .tab(let member):
                    pieces.append(row(member, on: &stack))
                case .group(let held, let members):
                    // Laid out where it would start, then given its room;
                    // carried away, it takes none.
                    let laid = group(held, members, area: area, top: closed == .group(held.id) ? stack.y : stack.top)
                    if !laid.away { _ = stack.next(laid.frame.height) }
                    pieces.append(.group(laid))
                }
            }
            if let gap = opening(at == items.count, on: &stack) { pieces.append(gap) }
            return (Area(area: area, pieces: pieces, head: area == .kept ? head : 0), stack.y)
        }

        // Your other devices' groups first, under the squares, each folded
        // or showing its pages, as DeviceRows says it is drawn, and the gap
        // at the end of the one a tab is carried onto.
        var above = ColumnStack(gap: m.gap, y: 0)
        devices = shape.devices.map { device in
            let gap = carry?.device == device.id ? carry?.height : nil
            let carried = gap != nil
            let lines = DeviceRows.lines(pages: device.pages, opened: device.opened, carried: carried)
            let pages = lines - (carried ? 1 : 0)
            var height = m.inset * 2 + m.heading
            if DeviceRows.shown(opened: device.opened, carried: carried) {
                height += m.gap + CGFloat(pages) * m.row + (gap ?? 0) + CGFloat(max(lines - 1, 0)) * m.gap
            }
            let top = above.next(height)
            return Device(id: device.id, frame: rect(top, height), gap: gap.map { rect(top + height - m.inset - $0, $0) })
        }

        // Then the kept area, each a gap clear of what is under it while it
        // has anything to draw.
        let keptTop = above.placed ? above.y + m.gap : 0
        let keptLaid = area(shape.kept, .kept, top: keptTop, head: shape.keptHead)
        kept = keptLaid.area
        var below = ColumnStack(gap: m.gap, y: keptLaid.area.pieces.isEmpty ? keptTop : keptLaid.bottom + m.gap)
        line = shape.line ? rect(below.next(m.line), m.line) : nil
        let newTabTop = shape.newTabOnTop ? rect(below.next(m.row), m.row) : nil
        let openTop = below.placed ? below.y + m.gap : below.y
        let openLaid = area(shape.open, .open, top: openTop, head: 0)
        open = openLaid.area
        let bottom = openLaid.area.pieces.isEmpty ? below.y : openLaid.bottom
        newTab = newTabTop ?? rect(bottom + m.gap, m.row)
        height = newTabTop == nil ? newTab.maxY : bottom
    }

    // MARK: - what a drop reads

    /// The area a point `y` down the rows is over: above the line's middle
    /// the kept area — your other devices' groups at its top take a tab
    /// carried onto one first (device(at:)); anything else over them goes to
    /// the head of the kept area, under them, where a first pin or kept
    /// group goes — and under it the open area, the New Tab row with it,
    /// which takes nothing itself. With nothing kept there is no line, and
    /// the kept area is above the rows' top: a tab there is the squares'
    /// first (PinDrop), a group the first kept group.
    func area(at y: CGFloat) -> ColumnArea {
        guard let line else { return y < 0 ? .kept : .open }
        return y < line.midY ? .kept : .open
    }

    /// Another device's group under `y`: the one a carried tab is already
    /// over keeps it a little past its edges, as a group keeps a tab.
    func device(at y: CGFloat, holding: String?, margin: CGFloat = 8) -> String? {
        devices.first { device in
            let frame = device.id == holding ? device.frame.insetBy(dx: 0, dy: -margin) : device.frame
            return y >= frame.minY && y <= frame.maxY
        }?.id
    }

    /// An area's groups, in order, as they are drawn.
    func groups(in area: ColumnArea) -> [TabGroup] {
        self[area].pieces.compactMap { piece in
            if case .group(let held) = piece, !held.away { return held.group }
            return nil
        }
    }

    /// The frames GroupDropFrames reads for an area's groups: each group's
    /// heading, its rows, and the gap open in it, which is part of it while
    /// the hand is over it. A heading takes its surface's edge above it, to
    /// the middle of the gap there, and a group showing nothing under it
    /// its whole surface, down to the middle of the gap under it: a tab
    /// carried up to a folded group along the tabs under it passes it,
    /// making way as it goes, once its top edge is past the group's middle,
    /// and the hand, at the middle of the tab, is then at the group's foot.
    /// The column's whole width: only how far down the hand is matters, the
    /// column itself saying how far beside it may be.
    func dropFrames(in area: ColumnArea) -> [UUID: GroupDropFrame] {
        var frames: [UUID: GroupDropFrame] = [:]
        let half = metrics.gap / 2
        for case .group(let held) in self[area].pieces where !held.away {
            let group = held.group.id
            let top = held.frame.minY - half
            let foot = held.rows.isEmpty ? held.frame.maxY + half : held.heading.maxY
            frames[group] = GroupDropFrame(group: group, rect: CGRect(x: held.heading.minX, y: top,
                                                                      width: held.heading.width, height: foot - top))
            for piece in held.rows {
                switch piece {
                case .row(let row) where !row.away:
                    frames[row.id] = GroupDropFrame(group: group, tab: row.id, rect: row.frame)
                case .gap(let rect):
                    frames[ColumnCarry.frameKey] = GroupDropFrame(group: group, rect: rect)
                default:
                    break
                }
            }
        }
        return frames
    }

    /// The steps Carried moves by along an area's top level: each item's
    /// height and the gap after it, the gap left out.
    func steps(in area: ColumnArea) -> [CGFloat] {
        self[area].pieces.compactMap { piece in
            if case .gap = piece { return nil }
            return piece.frame.height + metrics.gap
        }
    }

    /// The same along a group's rows.
    func steps(of held: Group) -> [CGFloat] {
        held.members.map { $0.frame.height + metrics.gap }
    }

    /// The place at the top level of `area` for something let go at `y`:
    /// before the first tab in no group whose middle is under it, or the
    /// first group whose heading would take a tab under it (GroupDropFrames.
    /// entry), or at the end; never among the rows every space shows, which
    /// keep the head — or, for one of them (`heading`), never past them.
    /// Nil while `y` is still on `keeping` — the group a tab is carried out
    /// of, the top of its heading included, which keeps it.
    func topLevel(at y: CGFloat, in area: ColumnArea, carrying: SideItemID, keeping: UUID? = nil,
                  heading: Bool = false) -> ColumnPlace? {
        let laid = self[area]
        var index = 0
        func place(_ at: Int?) -> ColumnPlace {
            guard heading else { return ColumnPlace(area: area, group: nil, index: at.map { max($0, laid.head) }) }
            return ColumnPlace(area: area, group: nil, index: min(at ?? laid.head, laid.head))
        }
        for piece in laid.pieces {
            switch piece {
            case .gap:
                continue
            case .row(let row):
                guard SideItemID.tab(row.id) != carrying else { continue }
                if y < row.frame.midY { return place(index) }
            case .group(let held):
                guard SideItemID.group(held.group.id) != carrying else { continue }
                if held.group.id == keeping {
                    let foot = held.rows.filter { !$0.away }.last?.frame.maxY ?? held.heading.maxY
                    if y >= held.heading.minY && y <= max(foot, held.heading.maxY) { return nil }
                    if y < held.heading.minY { return place(index) }
                } else if y < GroupDropFrames.entry(of: held.heading) {
                    return place(index)
                }
            }
            index += 1
        }
        return place(nil)
    }

    /// The place in a group a target found by GroupDropFrames stands for:
    /// before the tab it names, or after it; on the heading, the top of an
    /// open group, the end of a folded one.
    func place(of hit: GroupDropTarget, in area: ColumnArea, carrying: UUID) -> ColumnPlace {
        let held = self[area].pieces.lazy.compactMap { piece -> Group? in
            if case .group(let held) = piece, held.group.id == hit.group { return held }
            return nil
        }.first
        let others = (held?.members ?? []).map(\.id).filter { $0 != carrying }
        if let member = hit.member, let at = others.firstIndex(of: member) {
            let index = hit.after ? at + 1 : at
            return ColumnPlace(area: area, group: hit.group, index: index < others.count ? index : nil)
        }
        let top = held.map { !$0.group.collapsed } == true && !others.isEmpty
        return ColumnPlace(area: area, group: hit.group, index: top ? 0 : nil)
    }

    /// What the column does for `carried` with the hand at `point`, in the
    /// rows' space: along its own run (`own`: nil for a square, which has
    /// none in the rows), nothing (a run that won't take it, by `takes`),
    /// or the place the rows part at. A tab goes into the group it is over
    /// (GroupDropFrames.resolve, `holding` the place the gap is open at
    /// now, so the hand on the line between two groups doesn't flick
    /// between them), else to a place at its area's top level; a group, a
    /// group holding tabs only, always to the top level. The New Tab row
    /// is never in a group, whatever margin the group the hand was over
    /// keeps: over it, the hand is at the head of your tabs or at their end
    /// (topLevel). `heading`: a pin every space shows, which goes among the
    /// rows at the head and no further.
    func aim(for carried: SideItemID, from own: ColumnRun?, at point: CGPoint, holding: ColumnPlace?,
             heading: Bool = false, takes: (ColumnPlace) -> Bool) -> ColumnAim {
        let area = self.area(at: point.y)
        let keeping = own?.area == area ? own?.group : nil
        switch carried {
        case .tab(let id):
            let held = holding.flatMap { $0.area == area ? $0.group : nil } ?? keeping
            let here = CGPoint(x: width / 2, y: point.y)
            let overNewTab = area == .open && point.y >= newTab.minY && point.y <= newTab.maxY
            if !overNewTab, let hit = GroupDropFrames.resolve(here, frames: dropFrames(in: area), groups: groups(in: area),
                                                              excluding: id, holding: held) {
                if own == ColumnRun(area: area, group: hit.group) { return .along }
                let place = place(of: hit, in: area, carrying: id)
                return takes(place) ? .place(place) : .refused
            }
            if own == ColumnRun(area: area) { return .along }
            guard let place = topLevel(at: point.y, in: area, carrying: carried, keeping: keeping,
                                       heading: heading && area == .kept) else { return .along }
            return takes(place) ? .place(place) : .refused
        case .group:
            if own?.area == area { return .along }
            guard let place = topLevel(at: point.y, in: area, carrying: carried) else { return .along }
            return takes(place) ? .place(place) : .refused
        }
    }

    /// The kept area's lines as drawn, for the bench and the tests.
    var keptLines: [ColumnLine<Member>] {
        kept.pieces.flatMap { piece -> [ColumnLine<Member>] in
            switch piece {
            case .row(let row): return [.tab(row.member, group: nil)]
            case .group(let held): return [.heading(held.group)] + held.members.map { .tab($0.member, group: held.group.id) }
            case .gap: return []
            }
        }
    }
}
