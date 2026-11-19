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

    static func resolve(_ point: CGPoint, frames: [UUID: GroupDropFrame],
                        groups: [TabGroup], excluding source: UUID, vertical: Bool) -> GroupDropTarget? {
        // Model group order gives overlapping regions a deterministic priority.
        for group in groups {
            let heading = frames[group.id]?.rect
            let members = frames.values.filter { $0.group == group.id && $0.tab != nil && $0.tab != source }
                .sorted { vertical ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
            let extent = members.reduce(heading ?? .null) { $0.union($1.rect) }
            guard extent.contains(point) else { continue }
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
/// group it lands before, or after them all.
struct LooseDrop: Equatable {
    var before: UUID? = nil
}

extension GroupDropFrames {
    /// Where a tab carried out of its group lands, or nil when it stays:
    /// let go anywhere along its own group's run, its own place included
    /// (a hand that barely moved leaves nothing), level with another
    /// group's, or off to the side of the row. `loose` is the tabs in no
    /// group, by where they are drawn.
    static func leaving(_ point: CGPoint, frames: [UUID: GroupDropFrame], loose: [UUID: CGRect],
                        groups: [TabGroup], source: UUID, vertical: Bool) -> LooseDrop? {
        guard frames[source]?.tab == source else { return nil }
        let drawn = frames.values.map(\.rect) + Array(loose.values)
        let row = drawn.reduce(CGRect.null) { $0.union($1) }
        guard !row.isNull,
              vertical ? (row.minX...row.maxX).contains(point.x) : (row.minY...row.maxY).contains(point.y)
        else { return nil }
        let position = vertical ? point.y : point.x
        for group in groups {
            let run = frames.values.filter { $0.group == group.id }.reduce(CGRect.null) { $0.union($1.rect) }
            if !run.isNull, (vertical ? run.minY...run.maxY : run.minX...run.maxX).contains(position) { return nil }
        }
        let next = loose.filter { position < (vertical ? $0.value.midY : $0.value.midX) }
            .min { vertical ? $0.value.minY < $1.value.minY : $0.value.minX < $1.value.minX }
        return LooseDrop(before: next?.key)
    }
}

/// A group's heading. In the column, after Dia's: its icon, its name in its
/// colour and the chevron after it, on the group's surface (GroupLook.swift);
/// across the top, a quiet name, as before.
struct GroupHeading: View {
    @Environment(\.greys) private var greys
    @Environment(\.tabShortcutNumbers) private var shortcutNumbers
    @ObservedObject var browser: Browser
    let group: TabGroup
    var horizontal = false
    var dragSpace: String? = nil
    /// In the column of icons (SideIcons.swift): the name's first letter in
    /// a short heading, the name itself in its tooltip.
    var compact = false
    /// Told while something dragged in from elsewhere is over it, for the
    /// group's surface to light (GroupSurface).
    var targeted: (Bool) -> Void = { _ in }

    @State private var draft = ""
    @State private var hovering = false
    @State private var dropping = false
    @FocusState private var focused: Bool

    private var editing: Bool { browser.editingGroupID == group.id }

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

    /// Its tint: none while folded, as its surface has none (GroupSurface),
    /// until the pointer or something carried is on it.
    private var shortFill: Color {
        if dropping || hovering { return group.colour.lit }
        let bare = group.collapsed && browser.visibleTabs(in: group).isEmpty
        return bare ? .clear : group.colour.fill
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
        .onTapGesture { withAnimation(GroupLook.fold) { browser.toggleTabGroup(group.id) } }
        .modifier(GroupHeadingShared(browser: browser, group: group, dragSpace: dragSpace, dropping: $dropping,
                                       iconEdge: besideColumn, targeted: targeted))
        .onHover { hovering = $0 }
        .help(group.collapsed ? "\(group.name) — folded" : group.name)
        .accessibilityLabel(group.name)
        .accessibilityAction(named: "Show Menu") { GroupMenu.show(for: group, in: browser) }
        // Rename Group: no room for the name here, so it is typed beside.
        .popover(isPresented: Binding(get: { editing }, set: { if !$0 { browser.editingGroupID = nil } }),
                 arrowEdge: browser.prefs.sidePosition == .right ? .leading : .trailing) {
            TextField("Group name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 160)
                .padding(10)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { browser.editingGroupID = nil }
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

    /// The column's heading: on the group's surface, in its colour.
    private var column: some View {
        HStack(spacing: 7) {
            GroupIconView(group: group, first: browser.tabs(in: group.id).first)
            if editing {
                TextField("Group name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(group.colour.ink)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { browser.editingGroupID = nil }
            } else {
                Text(group.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(group.colour.ink)
                    .lineLimit(1)
                    .fadesOut(group.name)
                    .layoutPriority(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(group.colour.ink.opacity(0.7))
                    .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            if !editing, group.collapsed, let number = shortcutNumbers[group.id] {
                TabShortcutNumber(number: number)
            }
            // Closes the group and its tabs, as its menu's Close Group does;
            // there while the pointer is on the heading.
            if !editing, hovering {
                Button { browser.closeTabGroup(group.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(group.colour.ink)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Group")
                .accessibilityLabel("Close \(group.name)")
                .transition(.opacity)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .frame(height: GroupLook.heading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if !editing { withAnimation(GroupLook.fold) { browser.toggleTabGroup(group.id) } } }
        .modifier(GroupHeadingShared(browser: browser, group: group, dragSpace: dragSpace, dropping: $dropping,
                                       iconEdge: besideColumn, targeted: targeted))
        // At once, as a tab's cross is.
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(group.name)
        .accessibilityValue(group.collapsed ? "Folded" : "Open")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: group.collapsed ? "Expand" : "Collapse") { browser.toggleTabGroup(group.id) }
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
                TextField("Group name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: max(60, Self.width(for: group.name) - 20))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { browser.editingGroupID = nil }
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
        .onTapGesture { if !editing { browser.toggleTabGroup(group.id) } }
        .accessibilityAction(named: "Show Menu") { GroupMenu.show(for: group, in: browser) }
        .modifier(GroupHeadingShared(browser: browser, group: group, dragSpace: dragSpace, dropping: $dropping,
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
        browser.editingGroupID = nil
    }
}

/// What both headings answer to: their place for a drop, a tab or a
/// group let go on them, being picked up, and their menu.
private struct GroupHeadingShared: ViewModifier {
    @ObservedObject var browser: Browser
    let group: TabGroup
    let dragSpace: String?
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
            .onDrop(of: [.text], isTargeted: $dropping) { providers in
                guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
                _ = provider.loadObject(ofClass: String.self) { value, _ in
                    guard let value else { return }
                    DispatchQueue.main.async {
                        if value.hasPrefix("eden-group:"),
                           let id = UUID(uuidString: String(value.dropFirst("eden-group:".count))),
                           let index = browser.tabGroups.firstIndex(where: { $0.id == group.id }) {
                            browser.moveTabGroup(id, to: index)
                        }
                    }
                }
                return true
            }
            .onDrag { NSItemProvider(object: "eden-group:\(group.id.uuidString)" as NSString) }
            // The group's menu: its colours in a row at the top, then what
            // can be done to it (GroupMenu).
            .overlay { GroupMenuArea { GroupMenu.make(for: group, in: browser) } }
            .onChange(of: dropping) { _, now in targeted(now) }
            .popover(isPresented: Binding(get: { browser.iconGroupID == group.id }, set: { if !$0 { browser.iconGroupID = nil } }),
                     arrowEdge: iconEdge) {
                GroupIconPicker(browser: browser, group: group.id)
            }
    }
}
