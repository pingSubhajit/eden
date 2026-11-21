import SwiftUI
import AppKit

/// Unshifted heading and member frames in the layout's named coordinate space.
struct GroupDropFrame: Equatable {
    let group: UUID
    var tab: UUID? = nil
    let rect: CGRect
}

struct GroupDropTarget: Equatable {
    let group: UUID
    var member: UUID? = nil
    var after = false
}

struct GroupDropFrames: PreferenceKey {
    static var defaultValue: [UUID: GroupDropFrame] = [:]

    static func reduce(value: inout [UUID: GroupDropFrame], nextValue: () -> [UUID: GroupDropFrame]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }

    /// `holding`: the group the carried tab is in, or has a gap open in
    /// (ColumnCarry): it keeps the tab until the hand is `margin` past its edge,
    /// so a hand on the line between two groups doesn't flick between them.
    static func resolve(_ point: CGPoint, frames: [UUID: GroupDropFrame],
                        groups: [TabGroup], excluding source: UUID, vertical: Bool,
                        holding: UUID? = nil, margin: CGFloat = 8) -> GroupDropTarget? {
        // Model group order gives overlapping regions a deterministic priority,
        // after the group holding the tab.
        let ordered = groups.filter { $0.id == holding } + groups.filter { $0.id != holding }
        for group in ordered {
            let heading = frames[group.id]?.rect
            let members = frames.values.filter { $0.group == group.id && $0.tab != nil && $0.tab != source }
                .sorted { vertical ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
            // Everything drawn for it: its heading, its tabs, and a gap
            // open in it, which is part of it while the hand is over it.
            var extent = frames.values.filter { $0.group == group.id && $0.tab != source }
                .reduce(CGRect.null) { $0.union($1.rect) }
            if group.id == holding, !extent.isNull {
                extent = vertical ? extent.insetBy(dx: 0, dy: -margin) : extent.insetBy(dx: -margin, dy: 0)
            }
            guard extent.contains(point) else { continue }
            // The top of its heading is the place before it, among the tabs
            // in no group (`leaving`); in it, for the group holding the tab.
            if group.id != holding, let heading, (vertical ? point.y : point.x) < entry(of: heading, vertical: vertical) {
                continue
            }
            if heading?.contains(point) == true || group.collapsed || members.isEmpty {
                return GroupDropTarget(group: group.id)
            }
            let position = vertical ? point.y : point.x
            if let next = members.first(where: { position < (vertical ? $0.rect.midY : $0.rect.midX) }) {
                return GroupDropTarget(group: group.id, member: next.tab)
            }
            return GroupDropTarget(group: group.id, member: members.last?.tab, after: true)
        }
        return nil
    }
}

/// Where each tab in no group is drawn, in the row's space, for where a tab
/// carried out of its group lands among them (#1009). Written as the rows
/// are laid out and read once, when the tab is let go: a box rather than a
/// preference, so a row that moves redraws nothing (see ColumnFrames).
final class LooseFrames {
    var rects: [UUID: CGRect] = [:]
}

/// A tab of a group let go outside every group: in front of the tab in no
/// group, or the group, it lands before, or after them all.
struct LooseDrop: Equatable {
    var before: SideItemID? = nil
}

extension GroupDropFrames {
    /// Where on a heading its group begins taking a tab: above it, the
    /// place before the group, among the tabs in no group.
    static func entry(of heading: CGRect, vertical: Bool) -> CGFloat {
        vertical ? heading.minY + heading.height * 0.4 : heading.minX + heading.width * 0.4
    }

    /// Where a tab carried out of its group lands, or nil when it stays:
    /// let go anywhere along its own group's run, its own place included
    /// (a hand that barely moved leaves nothing), in another group's, or off
    /// to the side of the row. Otherwise before the tab in no group, or the
    /// group, it hasn't passed: a tab's middle, the top of a group's heading.
    /// `loose` is the tabs in no group, by where they are drawn.
    static func leaving(_ point: CGPoint, frames: [UUID: GroupDropFrame], loose: [UUID: CGRect],
                        groups: [TabGroup], source: UUID, vertical: Bool) -> LooseDrop? {
        guard frames[source]?.tab == source else { return nil }
        let drawn = frames.values.map(\.rect) + Array(loose.values)
        let row = drawn.reduce(CGRect.null) { $0.union($1) }
        guard !row.isNull,
              vertical ? (row.minX...row.maxX).contains(point.x) : (row.minY...row.maxY).contains(point.y)
        else { return nil }
        let position = vertical ? point.y : point.x
        var places: [(item: SideItemID, edge: CGFloat)] = loose.map { (.tab($0.key), vertical ? $0.value.midY : $0.value.midX) }
        let own = frames[source]?.group
        for group in groups {
            let run = frames.values.filter { $0.group == group.id }.reduce(CGRect.null) { $0.union($1.rect) }
            guard !run.isNull else { continue }
            // Its own group's run keeps it whole, the top of its heading too.
            let entry = group.id == own ? (vertical ? run.minY : run.minX) : entry(of: frames[group.id]?.rect ?? run, vertical: vertical)
            if position >= entry, position <= (vertical ? run.maxY : run.maxX) { return nil }
            places.append((.group(group.id), entry))
        }
        let next = places.filter { position < $0.edge }.min { $0.edge < $1.edge }
        return LooseDrop(before: next?.item)
    }
}

/// A group's heading, in either area of the column (Column.swift): one
/// heading for both. In the column, after Dia's: its icon, its name in its colour and
/// the chevron after it, on the group's surface (GroupLook.swift); across
/// the top, where only tab groups go, a quiet name, as before.
struct GroupHeading: View {
    @Environment(\.greys) private var greys
    @Environment(\.tabShortcutNumbers) private var shortcutNumbers
    @ObservedObject var browser: Browser
    /// What it heads: a group above the line or under it.
    let group: TabGroup
    var horizontal = false
    var dragSpace: String? = nil
    /// In the column of icons (SideIcons.swift): the name's first letter in
    /// a short heading, the name itself in its tooltip.
    var compact = false
    /// Its group carried along the column by hand, as a tab is (Carried),
    /// rather than picked up and dropped on another heading.
    var carriedByHand = false
    /// Not to be pressed: another space's column passing in a swipe. No
    /// card comes up for it, and its name is never typed there.
    var interactive = true
    /// Told while something dragged in from elsewhere is over it, for the
    /// group's surface to light (GroupSurface).
    var targeted: (Bool) -> Void = { _ in }

    @State private var draft = ""
    @State private var hovering = false
    @State private var dropping = false
    @FocusState private var focused: Bool

    private var editing: Bool { interactive && browser.editingGroupID == group.id }

    /// Above the line: a kept group (Column.swift), which says so only in
    /// its words, what stands for its icon and what it leaves out.
    private var kept: Bool { browser.area(ofGroup: group.id) == .kept }

    /// Its height in the column, a little under a tab's.
    static let height: CGFloat = 24
    /// And in the column of icons.
    static let compactHeight: CGFloat = 18

    /// Measured once a name: the row asks for every heading's on every redraw.
    private static var measured: [String: CGFloat] = [:]
    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    static func width(for name: String, numbered: Bool = false) -> CGFloat {
        let text: CGFloat
        if let known = measured[name] {
            text = known
        } else {
            text = ceil((name as NSString).size(withAttributes: [.font: font]).width)
            if measured.count > 500 { measured.removeAll() }
            measured[name] = text
        }
        return text + 20 + (numbered ? 23 : 0)
    }

    var body: some View {
        if compact { short } else { long }
    }

    /// What it is called while its name is typed.
    private var placeholder: String { kept ? "Folder name" : "Group name" }

    private func toggle() { browser.toggleTabGroup(group.id) }

    private func stopRenaming() { browser.editingGroupID = nil }

    /// Its tint: none while folded with nothing showing under it, as its
    /// surface has none (GroupSurface), until the pointer or something
    /// carried is on it.
    private var shortFill: Color {
        if dropping || hovering { return group.colour.lit }
        return group.collapsed && browser.visibleTabs(in: group).isEmpty ? .clear : group.colour.fill
    }

    /// The column of icons' heading: the letter, a fold mark beside it.
    private var short: some View {
        HStack(spacing: 2) {
            Text(group.name.first.map { String($0).uppercased() } ?? "•")
                .font(.system(size: 9.5, weight: .semibold))
            Image(systemName: "chevron.down")
                .font(.system(size: 6.5, weight: .bold))
                .rotationEffect(.degrees(group.collapsed ? -90 : 0))
        }
        .foregroundStyle(group.colour.ink)
        .frame(maxWidth: .infinity)
        .frame(height: Self.compactHeight)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(shortFill))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture { withAnimation(GroupLook.fold) { toggle() } }
        .modifier(GroupHeadingShared(browser: browser, group: group, dragSpace: dragSpace,
                                       carriedByHand: carriedByHand, dropping: $dropping,
                                       iconEdge: besideColumn, targeted: targeted))
        .onHover { hovering = $0 }
        .help(group.collapsed ? "\(group.name) — folded" : group.name)
        .groupAccessibility(name: group.name, collapsed: group.collapsed, toggle: toggle)
        .accessibilityAction(named: "Show Menu") { GroupMenu.show(for: group, in: browser) }
        // Rename: no room for the name here, so it is typed beside.
        .popover(isPresented: Binding(get: { editing }, set: { if !$0 { stopRenaming() } }),
                 arrowEdge: browser.prefs.sidePosition == .right ? .leading : .trailing) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 160)
                .padding(10)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { stopRenaming() }
                .onAppear {
                    draft = group.name
                    DispatchQueue.main.async { focused = true }
                }
        }
    }

    /// Pickers beside the column open away from the window's edge.
    private var besideColumn: Edge { browser.prefs.sidePosition == .right ? .leading : .trailing }

    private var long: some View {
        horizontal ? AnyView(strip) : AnyView(column)
    }

    /// What stands for its icon until one is chosen: an open group's first
    /// tab's site icon, else a stack of cards; a kept group's folder, open
    /// while it is.
    @ViewBuilder
    private var standIn: some View {
        let prefs = browser.prefs
        if kept {
            PinFolderIcon(open: !group.collapsed, ink: group.colour.ink, size: prefs.sideMark)
        } else if let first = browser.tabs(in: group.id).first {
            // The tab's own mark, as its row draws it.
            Mark(icon: prefs.glyph != .icons ? nil : first.icon, letter: first.monogram, size: prefs.sideMark)
        } else {
            Image(systemName: "square.on.square.fill")
                .font(.system(size: prefs.sideMark * 0.68, weight: .semibold))
                .foregroundStyle(group.colour.ink)
        }
    }

    /// The column's heading: on the group's surface, in its colour.
    private var column: some View {
        let prefs = browser.prefs
        return GroupLabel(row: prefs.sideRow, toggle: editing ? nil : toggle) {
            GroupIconView(icon: group.icon, colour: group.colour, size: prefs.sideMark) { standIn }
        } title: {
            if editing {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: prefs.sideTitle, weight: .semibold))
                    .foregroundStyle(group.colour.ink)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { stopRenaming() }
            } else {
                GroupName(name: group.name, ink: group.colour.ink, collapsed: group.collapsed, size: prefs.sideTitle)
            }
        } end: {
            // Folded, its place among ⌘1–⌘9, in either area.
            if !editing, group.collapsed, let number = shortcutNumbers[group.id] {
                TabShortcutNumber(number: number)
            }
            // Closes the group and its tabs, as its menu's Close Group does;
            // there while the pointer is on the heading. Not a kept group's:
            // its pins are kept, not closed in passing.
            if !kept {
                if !editing, hovering {
                    Button { browser.closeTabGroup(group.id) } label: {
                        RowCross(height: prefs.sideRow)
                    }
                    .buttonStyle(.plain)
                    .help("Close Group")
                    .accessibilityLabel("Close \(group.name)")
                    .transition(.opacity)
                }
            }
        }
        .modifier(GroupHeadingShared(browser: browser, group: group, dragSpace: dragSpace,
                                       carriedByHand: carriedByHand, dropping: $dropping,
                                       iconEdge: besideColumn, targeted: targeted))
        // At once, as a tab's cross is.
        .onHover { hovering = $0 }
        // Its tabs at a glance, folded or not: only in the live column, not
        // another space's passing by in a swipe.
        .groupHoverCard(group, in: browser, enabled: !editing && interactive)
        .groupAccessibility(name: group.name, collapsed: group.collapsed, toggle: toggle)
        .accessibilityAction(named: "Show Menu") { GroupMenu.show(for: group, in: browser) }
        .onChange(of: editing) { _, now in
            if now {
                draft = group.name
                DispatchQueue.main.async { focused = true }
            }
        }
        .onAppear {
            if editing {
                draft = group.name
                DispatchQueue.main.async { focused = true }
            }
        }
    }

    /// Across the top: a quiet name, as before, until the strip goes.
    private var strip: some View {
        HStack(spacing: 8) {
            if editing {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: max(60, Self.width(for: group.name) - 20))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { stopRenaming() }
            } else {
                Text(group.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !editing, group.collapsed {
                if let number = shortcutNumbers[group.id] {
                    TabShortcutNumber(number: number)
                } else if browser.prefs.showsTabShortcuts {
                    Color.clear.frame(width: 15, height: 15)
                }
            }
        }
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(dropping ? greys.wash : (hovering ? greys.hover : .clear)))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { if !editing { toggle() } }
        .accessibilityAction(named: "Show Menu") { GroupMenu.show(for: group, in: browser) }
        .modifier(GroupHeadingShared(browser: browser, group: group, dragSpace: dragSpace,
                                       carriedByHand: carriedByHand, dropping: $dropping,
                                       iconEdge: .bottom, targeted: targeted))
        .onHover { hovering = $0 }
        .onChange(of: editing) { _, now in
            if now {
                draft = group.name
                DispatchQueue.main.async { focused = true }
            }
        }
        .onAppear {
            if editing {
                draft = group.name
                DispatchQueue.main.async { focused = true }
            }
        }
    }

    private func commit() {
        browser.renameTabGroup(group.id, to: draft)
        stopRenaming()
    }
}

/// What every heading answers to: across the top, its place for a drop
/// and a heading let go on it, and being picked up; everywhere, its menu
/// and its icon's picker. In the column, above the line and under it, a
/// heading is carried by hand with its group, and a tab carried onto it
/// goes in by the column's layout (ColumnLayout), so it measures nothing.
private struct GroupHeadingShared: ViewModifier {
    @ObservedObject var browser: Browser
    let group: TabGroup
    let dragSpace: String?
    /// Carried along the column by hand (Carried): no drag of AppKit's to
    /// pick it up, nor a drop on it to take another heading.
    let carriedByHand: Bool
    @Binding var dropping: Bool
    /// Where Add Icon's picker points from.
    let iconEdge: Edge
    let targeted: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .background {
                if let dragSpace {
                    GeometryReader { geometry in
                        Color.clear.preference(key: GroupDropFrames.self,
                                               value: [group.id: GroupDropFrame(group: group.id, rect: geometry.frame(in: .named(dragSpace)))])
                    }
                }
            }
            .modifier(HeadingDrop(browser: browser, group: group.id, on: !carriedByHand, dropping: $dropping))
            // The group's menu: its colours in a row at the top, then what
            // can be done to it (GroupMenu).
            .overlay { GroupMenuArea { GroupMenu.make(for: group, in: browser) } }
            .onChange(of: dropping) { _, now in targeted(now) }
            .popover(isPresented: Binding(get: { browser.iconGroupID == group.id }, set: { if !$0 { browser.iconGroupID = nil } }),
                     arrowEdge: iconEdge) {
                GroupIconPicker(browser: browser, group: group)
            }
    }
}

/// A heading picked up, and another heading taking it, across the top:
/// the group goes to that group's place. Not in the column, where it is
/// carried by hand.
private struct HeadingDrop: ViewModifier {
    @ObservedObject var browser: Browser
    let group: UUID
    let on: Bool
    @Binding var dropping: Bool

    func body(content: Content) -> some View {
        if on {
            content
            .onDrop(of: [.text], isTargeted: $dropping) { providers in
                guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
                _ = provider.loadObject(ofClass: String.self) { value, _ in
                    guard let value else { return }
                    DispatchQueue.main.async {
                        if value.hasPrefix("eden-group:"),
                           let id = UUID(uuidString: String(value.dropFirst("eden-group:".count))),
                           let index = browser.tabGroups.firstIndex(where: { $0.id == group }) {
                            browser.moveTabGroup(id, to: index)
                        }
                    }
                }
                return true
            }
            .onDrag { NSItemProvider(object: "eden-group:\(group.uuidString)" as NSString) }
        } else {
            content
        }
    }
}
