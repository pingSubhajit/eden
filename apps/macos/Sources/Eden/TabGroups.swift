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

/// Where a tab carried over the groups would go.
enum GroupDropFrames {
    /// `holding`: the group the carried tab is in, or has a gap open in
    /// (ColumnCarry): it keeps the tab until the hand is `margin` past its edge,
    /// so a hand on the line between two groups doesn't flick between them.
    static func resolve(_ point: CGPoint, frames: [UUID: GroupDropFrame],
                        groups: [TabGroup], excluding source: UUID,
                        holding: UUID? = nil, margin: CGFloat = 8) -> GroupDropTarget? {
        // Model group order gives overlapping regions a deterministic priority,
        // after the group holding the tab.
        let ordered = groups.filter { $0.id == holding } + groups.filter { $0.id != holding }
        for group in ordered {
            let heading = frames[group.id]?.rect
            let members = frames.values.filter { $0.group == group.id && $0.tab != nil && $0.tab != source }
                .sorted { $0.rect.minY < $1.rect.minY }
            // Everything drawn for it: its heading, its tabs, and a gap
            // open in it, which is part of it while the hand is over it.
            var extent = frames.values.filter { $0.group == group.id && $0.tab != source }
                .reduce(CGRect.null) { $0.union($1.rect) }
            if group.id == holding, !extent.isNull {
                extent = extent.insetBy(dx: 0, dy: -margin)
            }
            guard extent.contains(point) else { continue }
            // The top of its heading is the place before it, among the tabs
            // in no group; in it, for the group holding the tab.
            if group.id != holding, let heading, point.y < entry(of: heading) {
                continue
            }
            if heading?.contains(point) == true || group.collapsed || members.isEmpty {
                return GroupDropTarget(group: group.id)
            }
            if let next = members.first(where: { point.y < $0.rect.midY }) {
                return GroupDropTarget(group: group.id, member: next.tab)
            }
            return GroupDropTarget(group: group.id, member: members.last?.tab, after: true)
        }
        return nil
    }

    /// Where on a heading its group begins taking a tab: above it, the
    /// place before the group, among the tabs in no group.
    static func entry(of heading: CGRect) -> CGFloat {
        heading.minY + heading.height * 0.4
    }
}

/// A group's heading, in either area of the column (Column.swift): one
/// heading for both. After Dia's: its icon, its name in its colour and the
/// chevron after it, on the group's surface (GroupLook.swift).
struct GroupHeading: View {
    @Environment(\.tabShortcutNumbers) private var shortcutNumbers
    @ObservedObject var browser: Browser
    /// What it heads: a group above the line or under it.
    let group: TabGroup
    /// Not to be pressed: another space's column passing in a swipe. No
    /// card comes up for it, and its name is never typed there.
    var interactive = true

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var editing: Bool { interactive && browser.editingGroupID == group.id }

    /// Above the line: a kept group (Column.swift), which says so only in
    /// its words, what stands for its icon and what it leaves out.
    private var kept: Bool { browser.area(ofGroup: group.id) == .kept }

    /// Its height in the column, a little under a tab's.
    static let height: CGFloat = 24

    var body: some View { column }

    /// What it is called while its name is typed.
    private var placeholder: String { kept ? "Folder name" : "Group name" }

    private func toggle() { browser.toggleTabGroup(group.id) }

    private func stopRenaming() { browser.editingGroupID = nil }

    /// Pickers beside the column open away from the window's edge.
    private var besideColumn: Edge { browser.prefs.sidePosition == .right ? .leading : .trailing }

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
        .modifier(GroupHeadingShared(browser: browser, group: group, iconEdge: besideColumn))
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

    private func commit() {
        browser.renameTabGroup(group.id, to: draft)
        stopRenaming()
    }
}

/// What every heading answers to: its menu and its icon's picker. Above
/// the line and under it, a heading is carried by hand with its group, and
/// a tab carried onto it goes in by the column's layout (ColumnLayout), so
/// it measures nothing.
private struct GroupHeadingShared: ViewModifier {
    @ObservedObject var browser: Browser
    let group: TabGroup
    /// Where Add Icon's picker points from.
    let iconEdge: Edge

    func body(content: Content) -> some View {
        content
            // The group's menu: its colours in a row at the top, then what
            // can be done to it (GroupMenu).
            .overlay { GroupMenuArea { GroupMenu.make(for: group, in: browser) } }
            .popover(isPresented: Binding(get: { browser.iconGroupID == group.id }, set: { if !$0 { browser.iconGroupID = nil } }),
                     arrowEdge: iconEdge) {
                GroupIconPicker(browser: browser, group: group)
            }
    }
}
