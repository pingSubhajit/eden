import AppKit
import EdenCore
import SwiftUI

// How a tab group looks in the column, after Dia's: one tinted, rounded
// surface holding its heading and its tabs, in the group's colour. The
// heading reads in that colour, its icon before the name and the chevron
// straight after it. The tab in front is a card on the tint; folded, the
// group keeps that card showing, so where you are always has its place.
// Folding and unfolding run on a quick spring fitted to Dia's frames
// (GroupLook.fold). A right-click opens the group's menu: the colours in a
// row at its top, applied as you pick them, then what can be done to it.

extension GroupColour {
    /// The swatch itself, as the paintings have it.
    private var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .stone: return (0xA3, 0x9E, 0x93)
        case .sage: return (0x7F, 0x96, 0x72)
        case .sky: return (0x7E, 0xA2, 0xB6)
        case .heather: return (0x8E, 0x81, 0xA3)
        case .ochre: return (0xC9, 0xA0, 0x4A)
        case .rose: return (0xC7, 0x90, 0x8F)
        case .madder: return (0xA9, 0x5C, 0x54)
        case .umber: return (0xB0, 0x6F, 0x42)
        }
    }

    /// What the surfaces are tinted with on dark. Stone, the neutral, goes
    /// much darker there, a quiet grey a little off the column's own, as
    /// Dia's plain groups are; the colours keep their swatch.
    private var night: (CGFloat, CGFloat, CGFloat) {
        self == .stone ? (0x44, 0x42, 0x3F) : rgb
    }

    private func color(_ make: @escaping (_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ dark: Bool) -> NSColor) -> Color {
        let day = rgb, night = night
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = dark ? night : day
            return make(r / 255, g / 255, b / 255, dark)
        })
    }

    var swatch: Color {
        let (r, g, b) = rgb
        return Color(nsColor: NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1))
    }

    /// The surface: the colour laid thinly over whatever ground the column has.
    var fill: Color { color { r, g, b, dark in NSColor(srgbRed: r, green: g, blue: b, alpha: dark ? 0.30 : 0.24) } }
    /// The same, stronger, while something carried over it would join it.
    var lit: Color { color { r, g, b, dark in NSColor(srgbRed: r, green: g, blue: b, alpha: dark ? 0.46 : 0.40) } }
    /// Its fine edge.
    var edge: Color { color { r, g, b, dark in NSColor(srgbRed: r, green: g, blue: b, alpha: dark ? 0.45 : 0.40) } }
    /// The heading's name, icon and chevron: the colour darkened on light,
    /// lightened on dark, to read on its own surface. Stone's is the
    /// column's own ink, as a plain heading's is.
    var ink: Color {
        if self == .stone { return Palette.ink }
        return color { r, g, b, dark in
            let to: CGFloat = dark ? 1 : 0, t: CGFloat = dark ? 0.30 : 0.32
            return NSColor(srgbRed: r + (to - r) * t, green: g + (to - g) * t, blue: b + (to - b) * t, alpha: 1)
        }
    }
    /// The tab in front, on the surface: white on light, the colour stronger
    /// on dark; on Stone's near-black, a lift of white.
    var card: Color {
        let stone = self == .stone
        return color { r, g, b, dark in
            guard dark else { return NSColor(white: 1, alpha: 0.92) }
            return stone ? NSColor(white: 1, alpha: 0.09) : NSColor(srgbRed: r, green: g, blue: b, alpha: 0.42)
        }
    }
    var hover: Color {
        let stone = self == .stone
        return color { r, g, b, dark in
            dark && stone ? NSColor(white: 1, alpha: 0.05) : NSColor(srgbRed: r, green: g, blue: b, alpha: dark ? 0.20 : 0.16)
        }
    }

    /// The greys for the rows on its surface (Greys): its card for the tab in
    /// front and its tint under the pointer.
    var greys: Greys { Greys(wash: card, hover: hover, tile: hover, pinLive: card) }
}

enum GroupLook {
    /// Folding and unfolding: Dia's lower edge, tracked at 60 fps, travels
    /// most of the way in five frames and settles with about a point of
    /// overshoot (183 ms folding, 217 ms unfolding). This spring meets it.
    static var fold: Animation? {
        Motion.reduced ? nil : Motion.light ? .easeOut(duration: 0.16) : .spring(response: 0.2, dampingFraction: 0.82)
    }

    /// Between the surface's edge and what it holds.
    static let inset: CGFloat = 3
    /// The heading's height: folded, a group on its surface takes one
    /// tab's line in the column, and lights as one would.
    static func heading(row: CGFloat) -> CGFloat { row - surround }
    /// How much further in a group's tabs sit than the tabs outside it.
    static let indent: CGFloat = 12
    static let radius = Metrics.rowRadius

    /// What the surface adds to the height of the rows it holds.
    static var surround: CGFloat { inset * 2 }

    /// The symbols a group can take, as Dia offers 46.
    static let symbols = [
        "star.fill", "bookmark.fill", "heart.fill", "flag.fill", "bolt.fill", "triangle.fill", "asterisk", "bell.fill",
        "square.on.square.fill", "books.vertical.fill", "tray.full.fill", "archivebox.fill", "square.stack.3d.up.fill",
        "circle.grid.2x2.fill", "tag.fill", "folder.fill",
        "tray.fill", "doc.text.fill", "checkmark.circle.fill", "person.2.fill", "calendar", "bubble.left.fill",
        "text.bubble.fill", "list.bullet",
        "checklist", "pencil", "quote.opening", "magnifyingglass", "doc.fill", "book.fill", "curlybraces",
        "graduationcap.fill",
        "sparkles", "paintbrush.fill", "lightbulb.fill", "music.note", "at", "bubble.right.fill", "sun.horizon.fill",
        "leaf.fill",
        "cart.fill", "airplane", "house.fill", "briefcase.fill", "gamecontroller.fill", "camera.fill",
    ]

    /// The emoji the picker offers first; any other is a keystroke away.
    static let emoji = [
        "😀", "😎", "🤓", "🧠", "💡", "⭐️", "🔥", "✨", "❤️", "🌱", "🌿", "🌸", "🌻", "🍀", "🌍", "🌙",
        "☀️", "🌊", "🏔️", "🏛️", "🏠", "🏢", "🎓", "📚", "📝", "📌", "📎", "🔖", "🗂️", "💼", "💻", "🖥️",
        "⚙️", "🔧", "🧪", "🔬", "🎨", "🎵", "🎬", "📷", "🎮", "⚽️", "🍕", "☕️", "✈️", "🛒", "💰", "🚀",
    ]
}

/// The surface around a group's heading and tabs.
struct GroupSurface: ViewModifier {
    let colour: GroupColour
    /// Folded with nothing showing under its heading.
    var folded = false
    /// Something carried over it would join it.
    var lit = false

    @State private var hovering = false

    /// Folded, a group has no surface at all, as Dia's don't: a heading
    /// among the tabs, its name in its colour, until it is opened, the
    /// pointer comes onto it, or something carried over it would join it.
    /// Where it sits doesn't change, only the tint.
    private var bare: Bool { folded && !hovering && !lit }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: GroupLook.radius, style: .continuous)
        content
            .padding(GroupLook.inset)
            .environment(\.greys, colour.greys)
            // Under the pointer the tint is there at once, as a tab's is;
            // folding or unfolding, it goes with the fold. Lit, it fades.
            .background {
                shape.fill(lit ? colour.lit : colour.fill)
                    .opacity(bare ? 0 : 1)
                    .animation(Motion.quick, value: lit)
            }
            .overlay {
                shape.strokeBorder(colour.edge, lineWidth: 0.5)
                    .opacity(bare ? 0 : 1)
                    .animation(Motion.quick, value: lit)
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: colour)
    }
}

// MARK: - a group in the column

/// A group in the column: its heading on its surface, and under it, set in,
/// its rows. Your tab groups and your other devices' (Elsewhere.swift) are
/// both one of these, so they fold, light and sit alike; only what their
/// headings say and what their rows are differ.
struct SideGroup<Heading: View, Rows: View>: View {
    let colour: GroupColour
    /// Folded with nothing showing under its heading: no surface until the
    /// pointer or something carried is on it (GroupSurface).
    let folded: Bool
    var lit = false
    /// Its rows drawn: while it isn't folded, unless told otherwise (a pin
    /// carried onto a folded group shows where it would go).
    var showsRows: Bool?
    /// How far in its rows sit: none with icons only.
    var indent = GroupLook.indent
    @ViewBuilder let heading: Heading
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(spacing: SideBar.gap) {
            heading
            // Nothing under a folded heading: not even an empty stack, and
            // its gap.
            if showsRows ?? !folded {
                VStack(spacing: SideBar.gap) { rows }
                    .padding(.leading, indent)
            }
        }
        .modifier(GroupSurface(colour: colour, folded: folded, lit: lit))
    }
}

/// A group's heading in the column: its icon, its name, whatever stands at
/// its end, one tab's line in all, its icon and cross where a tab's are
/// (the surface's edge being that much in). A click folds or unfolds it on
/// the fold's spring, and so do Space and Return once it has the keyboard's
/// focus, as a button would.
struct GroupLabel<Icon: View, Title: View, End: View>: View {
    let row: CGFloat
    /// Folds or unfolds it; nil while it can't be (its name being typed).
    let toggle: (() -> Void)?
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    @ViewBuilder let end: End

    var body: some View {
        HStack(spacing: Metrics.rowSpacing) {
            icon
            title
            Spacer(minLength: 0)
            end
        }
        .padding(.leading, Metrics.rowInset - GroupLook.inset)
        .padding(.trailing, Metrics.rowCrossInset - GroupLook.inset)
        .frame(height: GroupLook.heading(row: row))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: fold)
        .focusable(toggle != nil, interactions: .activate)
        .onKeyPress(keys: [.space, .return]) { _ in
            guard toggle != nil else { return .ignored }
            fold()
            return .handled
        }
    }

    private func fold() {
        guard let toggle else { return }
        withAnimation(GroupLook.fold) { toggle() }
    }
}

/// A group's name in its heading, in the group's ink, and the chevron
/// straight after it: pointing on while folded, down while open.
struct GroupName: View {
    let name: String
    let ink: Color
    let collapsed: Bool
    let size: CGFloat

    var body: some View {
        Text(name)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .fadesOut(name)
            .layoutPriority(1)
        Image(systemName: "chevron.right")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(ink.opacity(0.7))
            .rotationEffect(.degrees(collapsed ? 0 : 90))
            .accessibilityHidden(true)
    }
}

extension View {
    /// A group's heading, as VoiceOver reads it: one button, named for the
    /// group, folded or open, that expands or collapses it.
    func groupAccessibility(name: String, collapsed: Bool, toggle: @escaping () -> Void) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityLabel(name)
            .accessibilityValue(collapsed ? "Folded" : "Open")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: collapsed ? "Expand" : "Collapse", toggle)
    }
}

/// A group's icon in its heading: its own, else its first tab's site icon,
/// else a stack of cards.
struct GroupIconView: View {
    let group: TabGroup
    /// The group's first tab, for its site icon.
    let first: Tab?
    /// A tab's icon in the column (Preferences.sideMark).
    let size: CGFloat
    /// Letters for site icons, as the tabs show them (Settings › Tabs).
    var letters = false

    var body: some View {
        Group {
            switch group.icon {
            case .emoji(let text):
                Text(text).font(.system(size: size * 0.8))
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: size * 0.72, weight: .semibold))
                    .foregroundStyle(group.colour.ink)
            case nil:
                if let first {
                    // The tab's own mark, as its row draws it.
                    Mark(icon: letters ? nil : first.icon, letter: first.monogram, size: size)
                } else {
                    Image(systemName: "square.on.square.fill")
                        .font(.system(size: size * 0.68, weight: .semibold))
                        .foregroundStyle(group.colour.ink)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - the menu

/// A right-click — or a ⌃-click — anywhere on the view it lies over opens
/// `menu`. Every other click goes through to what is under it.
struct GroupMenuArea: NSViewRepresentable {
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> Area { Area(make: menu) }
    func updateNSView(_ view: Area, context: Context) { view.make = menu }

    final class Area: NSView {
        var make: () -> NSMenu
        init(make: @escaping () -> NSMenu) {
            self.make = make
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        /// Only for the click that asks for a menu.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let asks = event.type == .rightMouseDown || event.type == .rightMouseUp
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return asks ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            NSMenu.popUpContextMenu(make(), with: event, for: self)
        }

        override func mouseDown(with event: NSEvent) {
            NSMenu.popUpContextMenu(make(), with: event, for: self)
        }
    }
}

@MainActor
enum GroupMenu {
    /// Menu rows call back into Swift through this, each kept by its own
    /// row, so it goes with the menu.
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    private static func item(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [],
                             _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: key)
        // The target is held weakly; the row's object is what keeps it.
        item.target = action
        item.representedObject = action
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// The group's menu, in Dia's order, without what Eden leaves out.
    static func make(for group: TabGroup, in browser: Browser) -> NSMenu {
        let menu = NSMenu()
        let swatches = NSMenuItem()
        let row = NSHostingView(rootView: SwatchRow(browser: browser, group: group.id))
        row.frame = NSRect(x: 0, y: 0, width: SwatchRow.width, height: SwatchRow.height)
        // As wide as the menu, the swatches from its left as its titles are.
        row.autoresizingMask = .width
        swatches.view = row
        menu.addItem(swatches)
        menu.addItem(item("Rename…") { browser.editingGroupID = group.id })
        menu.addItem(item(group.icon == nil ? "Add Icon…" : "Change Icon…") { browser.iconGroupID = group.id })
        menu.addItem(.separator())
        menu.addItem(item("New Tab in Group", key: "t", modifiers: [.option, .command]) { browser.newTab(inGroup: group.id) })
        menu.addItem(item("New Group", key: "n", modifiers: [.control, .command]) { browser.newGroup() })
        menu.addItem(.separator())
        menu.addItem(item(group.collapsed ? "Expand Group" : "Collapse Group") {
            withAnimation(GroupLook.fold) { browser.toggleTabGroup(group.id) }
        })
        menu.addItem(item("Separate Tabs") { browser.removeTabGroup(group.id) })
        menu.addItem(item("Duplicate") { browser.duplicateTabGroup(group.id) })
        menu.addItem(item("Copy All Links") { browser.copyLinks(of: group.id) })
        // The whole group into another space, still a group there.
        if browser.prefs.usesSpaces, browser.spaces.count > 1 {
            let spaces = NSMenu()
            for space in browser.spaces where space.id != browser.spaceID {
                let entry = item(space.name) { browser.move(group: group.id, toSpace: space.id) }
                entry.image = NSImage(systemSymbolName: space.symbol, accessibilityDescription: nil)
                spaces.addItem(entry)
            }
            let holder = NSMenuItem(title: "Move Group to Space", action: nil, keyEquivalent: "")
            holder.submenu = spaces
            menu.addItem(holder)
        }
        menu.addItem(.separator())
        menu.addItem(item("Close Group") { browser.closeTabGroup(group.id) })
        return menu
    }

    /// The menu without a right click: VoiceOver's Show Menu, at the pointer.
    static func show(for group: TabGroup, in browser: Browser) {
        make(for: group, in: browser).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// The colours, in a row at the top of a group's menu: picked, at once, and
/// the menu stays open for another look.
private struct SwatchRow: View {
    @ObservedObject var browser: Browser
    let group: UUID

    private var current: GroupColour? { browser.tabGroups.first { $0.id == group }?.colour }

    /// A swatch, the ring round the chosen one and the air between them,
    /// as close set as Dia's.
    private static let dot: CGFloat = 16
    private static let ring: CGFloat = 2.5
    private static let gap: CGFloat = 5
    /// Where the menu's titles start, measured from its edge: the first
    /// swatch starts there too, its ring just outside.
    private static let titles: CGFloat = 15.5
    static let height: CGFloat = 30
    static var width: CGFloat {
        let count = CGFloat(GroupColour.allCases.count)
        return titles * 2 + count * dot + (count - 1) * (gap + ring * 2)
    }

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(GroupColour.allCases) { colour in
                Button {
                    browser.setColour(colour, ofGroup: group)
                } label: {
                    Circle()
                        .fill(colour.swatch)
                        .frame(width: Self.dot, height: Self.dot)
                        .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                        .padding(Self.ring)
                        .overlay(Circle().strokeBorder(Palette.muted, lineWidth: current == colour ? 1.5 : 0))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(colour.name)
                .accessibilityLabel(colour.name)
                .accessibilityAddTraits(current == colour ? .isSelected : [])
            }
        }
        .padding(.leading, Self.titles - Self.ring)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - the icon

/// Add Icon…, beside the group's heading: an emoji or one of the symbols,
/// taken as it is picked, the popover staying for another look. The bin
/// goes back to the first tab's site icon.
struct GroupIconPicker: View {
    @ObservedObject var browser: Browser
    let group: UUID

    private enum Kind: String, CaseIterable { case emoji = "Emoji", symbols = "Symbols" }
    @State private var kind: Kind = .emoji
    @State private var typed = ""
    @FocusState private var typing: Bool

    private var current: GroupIcon? { browser.tabGroups.first { $0.id == group }?.icon }
    private var colour: GroupColour { browser.tabGroups.first { $0.id == group }?.colour ?? .stone }
    private let columns = Array(repeating: GridItem(.fixed(26), spacing: 4), count: 8)

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                Button {
                    browser.setIcon(nil, ofGroup: group)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(current == nil)
                .help("Remove the icon")
                .accessibilityLabel("Remove Icon")
            }
            LazyVGrid(columns: columns, spacing: 4) {
                switch kind {
                case .emoji:
                    ForEach(GroupLook.emoji, id: \.self) { text in
                        cell(selected: current == .emoji(text)) { browser.setIcon(.emoji(text), ofGroup: group) } label: {
                            Text(text).font(.system(size: 15))
                        }
                    }
                case .symbols:
                    ForEach(GroupLook.symbols, id: \.self) { name in
                        cell(selected: current == .symbol(name)) { browser.setIcon(.symbol(name), ofGroup: group) } label: {
                            Image(systemName: name).font(.system(size: 13, weight: .semibold)).foregroundStyle(colour.ink)
                        }
                    }
                }
            }
            if kind == .emoji {
                // Any other emoji: typed, pasted, or from the Mac's own viewer.
                HStack(spacing: 6) {
                    TextField("Another emoji", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .focused($typing)
                        .onChange(of: typed) { _, now in take(now) }
                    Button("Emoji & Symbols") {
                        typing = true
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 252)
    }

    private func cell(selected: Bool, _ pick: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: pick) {
            label()
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Palette.wash : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The last emoji typed into the field, taken as the icon.
    private func take(_ text: String) {
        guard let last = text.last, last.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C })
        else { return }
        browser.setIcon(.emoji(String(last)), ofGroup: group)
        typed = ""
    }
}
