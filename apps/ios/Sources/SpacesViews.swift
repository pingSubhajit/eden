import EdenCore
import SwiftUI

// What spaces and pins look like on iPhone and iPad: the space in front by
// name and icon, a sheet of them all to switch, make, change, reorder and
// delete, and the pins of the space in front — squares, and rows under them
// while Settings › Pinned Rows is on — each with what can be done to it.

extension SpaceAppearance.Colour {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

extension Space {
    /// Its colour, or nil for none.
    var tint: Color? { tintIndex.map { SpaceAppearance.colours[$0].color } }
}

/// A space's icon, in its colour.
struct SpaceIcon: View {
    let space: Space

    var body: some View {
        Image(systemName: space.symbol)
            .foregroundStyle(space.tint ?? .secondary)
            .accessibilityHidden(true)
    }
}

/// The space in front, by name and icon: a tap opens every space.
struct SpaceSwitcher: View {
    let browser: Browser
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 8) {
                SpaceIcon(space: browser.space)
                Text(browser.space.name).fontWeight(.semibold).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Space: \(browser.space.name)")
        .accessibilityHint("Shows every space")
        .accessibilityIdentifier("space-switcher")
        .sheet(isPresented: $showing) { SpacesSheet(browser: browser) }
    }
}

/// Every space: tap one to go there; make, change, reorder or delete them.
struct SpacesSheet: View {
    let browser: Browser
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Space?
    @State private var making = false
    @State private var deleting: Space?

    var body: some View {
        NavigationStack {
            List {
                ForEach(browser.spaces) { space in
                    Button {
                        browser.enter(space.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            SpaceIcon(space: space).frame(width: 24)
                            Text(space.name)
                            Spacer(minLength: 0)
                            if space.id == browser.spaceID {
                                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(space.id == browser.spaceID ? .isSelected : [])
                    .accessibilityIdentifier("space-option-\(space.id.uuidString)")
                    .swipeActions {
                        if !space.isFirst {
                            Button("Delete", role: .destructive) { deleting = space }
                        }
                        Button("Edit") { editing = space }.tint(.gray)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = space }
                        if !space.isFirst {
                            Button("Delete…", systemImage: "trash", role: .destructive) { deleting = space }
                        }
                    }
                }
                .onMove { from, to in
                    guard let index = from.first else { return }
                    let space = browser.spaces[index]
                    browser.library.move(space.id, to: to > index ? to - 1 : to)
                }
            }
            .navigationTitle("Spaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { EditButton() }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Space", systemImage: "plus") { making = true }
                        .accessibilityIdentifier("space-new")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $making) { SpaceForm(browser: browser, editing: nil) { dismiss() } }
            .sheet(item: $editing) { space in SpaceForm(browser: browser, editing: space) {} }
            .confirmationDialog(deleting.map { "Delete “\($0.name)”?" } ?? "", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete Space", role: .destructive) {
                    if let deleting { browser.deleteSpace(deleting.id) }
                    deleting = nil
                }
                .accessibilityIdentifier("space-delete-confirm")
            } message: {
                Text("Its tabs and pins close, and its own cookies and sign-ins are erased from this device. History and bookmarks stay.")
            }
        }
    }
}

/// A new space, or one being changed: its name, icon and colour, and — only
/// as it is made — whether it is signed in where Personal is.
struct SpaceForm: View {
    let browser: Browser
    let editing: Space?
    /// Told once a new space is made, to put the sheets away.
    let made: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = ""
    @State private var colour = 0
    @State private var sharesSignIns = false
    private let icons = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("space-name")
                }
                Section("Icon") {
                    LazyVGrid(columns: icons, spacing: 8) {
                        ForEach(Array(zip(SpaceAppearance.icons, SpaceAppearance.iconNames)), id: \.0) { symbol, label in
                            Button { icon = symbol } label: {
                                Image(systemName: symbol)
                                    .frame(width: 40, height: 40)
                                    .background(icon == symbol ? Color.accentColor.opacity(0.2) : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(label)
                            .accessibilityAddTraits(icon == symbol ? .isSelected : [])
                        }
                    }
                }
                Section("Colour") {
                    Picker("Colour", selection: $colour) {
                        ForEach(SpaceAppearance.colourNames.indices, id: \.self) { index in
                            Text(SpaceAppearance.colourNames[index]).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if editing == nil {
                    Section {
                        Toggle("Share Sign-Ins with Personal", isOn: $sharesSignIns)
                            .accessibilityIdentifier("space-share-signins")
                    } footer: {
                        Text("Off, the space starts signed out, with cookies and sign-ins of its own. This can't be changed later.")
                    }
                }
            }
            .navigationTitle(editing == nil ? "New Space" : "Edit Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Create" : "Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("space-save")
                }
            }
            .onAppear {
                name = editing?.name ?? ""
                icon = editing?.symbol ?? SpaceAppearance.freeIcon(among: browser.spaces)
                colour = editing?.tintIndex ?? 0
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let editing {
            browser.library.edit(editing.id) { space in
                space.name = trimmed
                space.icon = icon
                space.colour = colour
            }
            dismiss()
        } else {
            browser.addSpace(named: trimmed, icon: icon, colour: colour, sharesSignIns: sharesSignIns)
            dismiss()
            made()
        }
    }
}

// MARK: - pins

/// The pins of the space in front: squares, then — while Pinned Rows is on —
/// rows. `container` scopes their identifiers ("sidebar", "start", "tabs").
struct PinStrip: View {
    let browser: Browser
    let container: String
    /// Told once a pin is picked: a sheet showing them goes away.
    var picked: () -> Void = {}
    @State private var renaming: Tab?
    /// A square's height, and the room between squares.
    private static let height: CGFloat = 56
    private static let gap: CGFloat = 8

    var body: some View {
        let pins = browser.shownPins
        let rows = browser.settings.listsPins ? pins.filter { $0.def.listed == true } : []
        let tiles = pins.filter { pin in !rows.contains { $0.id == pin.id } }
        VStack(alignment: .leading, spacing: 10) {
            if !tiles.isEmpty { grid(tiles) }
            ForEach(rows) { pin in row(pin) }
        }
        .pinRenaming($renaming, browser: browser)
    }

    /// The squares as the Mac's column lays them out (PinRows): no more than
    /// four to a row, the rows even, each spanning the width, its squares
    /// sharing it; one row alone of fewer than three keeps three places.
    /// Past a square, a cell grows into a wide button, never a bigger icon.
    private func grid(_ tiles: [ShownPin]) -> some View {
        let split = PinRows.split(tiles.count, most: 4)
        let places = PinRows.places(split, least: 3)
        let starts = split.indices.map { split[..<$0].reduce(0, +) }
        return VStack(spacing: Self.gap) {
            ForEach(split.indices, id: \.self) { line in
                HStack(spacing: Self.gap) {
                    ForEach(tiles[starts[line]..<starts[line] + split[line]]) { pin in square(pin) }
                    ForEach(0..<(places[line] - split[line]), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).frame(height: Self.height)
                    }
                }
            }
        }
    }

    private func square(_ pin: ShownPin) -> some View {
        let active = pin.tab.id == browser.activeID
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button { open(pin) } label: {
            PinMark(pin: pin, size: 28)
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .background(Color(.secondarySystemBackground), in: shape)
                .overlay {
                    // The pin in front lit in its icon's own colour, as on
                    // the Mac; in the accent, with no icon or no colour.
                    if active {
                        if let colour = PinMark.accent(of: pin) {
                            PinGlow(colour: colour, shape: shape)
                        } else {
                            shape.strokeBorder(Color.accentColor, lineWidth: 2)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if pin.shared {
                        Image(systemName: "square.on.square").font(.caption2).foregroundStyle(.secondary).padding(4)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .contextMenu { PinActions(browser: browser, tab: pin.tab, renaming: $renaming) }
        .accessibilityLabel(label(pin))
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("\(container)-pin-\(pin.id.uuidString)")
    }

    private func row(_ pin: ShownPin) -> some View {
        let active = pin.tab.id == browser.activeID
        return Button { open(pin) } label: {
            HStack(spacing: 10) {
                PinMark(pin: pin, size: 18)
                    .frame(width: 28, height: 28)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(pin.def.label).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(active ? (PinMark.accent(of: pin) ?? Color.accentColor).opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { PinActions(browser: browser, tab: pin.tab, renaming: $renaming) }
        .accessibilityLabel(label(pin))
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("\(container)-pin-\(pin.id.uuidString)")
    }

    private func open(_ pin: ShownPin) {
        browser.select(pin.tab)
        picked()
    }

    /// What VoiceOver says: its name, and that every space shows it.
    private func label(_ pin: ShownPin) -> String {
        pin.shared ? "\(pin.def.label), pinned in every space" : "\(pin.def.label), pinned"
    }
}

/// A pin's face: its site's icon (SiteIcons), the site it was pinned at,
/// or its letter until the icon has come.
struct PinMark: View {
    let pin: ShownPin
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let icon = SiteIcons.shared.icon(for: PinMark.site(of: pin)) {
            Image(uiImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                // One grey on nothing, in the tile's own tone, turned over
                // to stand out from it: GitHub's black cat, white at night.
                .turnedOver(SiteIcons.shared.needsTurning(icon, dark: scheme == .dark))
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Text(pin.def.letter)
                .font(.system(size: size * 0.72, weight: .semibold, design: .rounded))
        }
    }

    /// Its home's site, whatever page it was taken to since.
    static func site(of pin: ShownPin) -> URL? { pin.def.homeURL ?? pin.tab.url }

    /// The colour its icon wears, if it has an icon of some colour.
    @MainActor static func accent(of pin: ShownPin) -> Color? {
        SiteIcons.shared.icon(for: site(of: pin)).flatMap(SiteIcons.shared.accent(of:))
    }
}

private extension View {
    /// Its colours turned over, light for dark, when `on`.
    @ViewBuilder func turnedOver(_ on: Bool) -> some View {
        if on { colorInvert() } else { self }
    }
}

/// The pinned tab in front, lit in its site icon's colour, as Dia's is and
/// the Mac's: a wash, a glow in from the edge, and the edge itself.
struct PinGlow<Edge: InsettableShape>: View {
    let colour: Color
    let shape: Edge

    var body: some View {
        ZStack {
            shape.fill(colour.opacity(0.16))
            shape.strokeBorder(colour.opacity(0.55), lineWidth: 5)
            shape.strokeBorder(colour.opacity(0.9), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// What can be done to a pin, or to a tab that could be one: in the
/// browser's menu and on each pin.
struct PinActions: View {
    let browser: Browser
    let tab: Tab
    @Binding var renaming: Tab?

    var body: some View {
        if let def = browser.pinDef(of: tab) {
            Button("Go Home", systemImage: "house") { browser.goHome(tab) }
                .disabled(Browser.samePage(def.homeURL, tab.url))
                .accessibilityIdentifier("pin-go-home")
            Button("Set Current Page as Home", systemImage: "house.and.flag") { browser.setHome(tab) }
                .disabled(Browser.samePage(def.homeURL, tab.url) || Continuity.page(tab.url) == nil)
            Button("Open as New Tab", systemImage: "plus.square.on.square") { browser.openAsNewTab(tab) }
            Button("Rename…", systemImage: "pencil") { renaming = tab }
            if browser.settings.listsPins {
                Button(def.listed == true ? "Show as Square" : "Show as Row",
                       systemImage: def.listed == true ? "square" : "list.bullet") {
                    browser.editPin(tab) { $0.listed = $0.listed == true ? nil : true }
                }
            }
            if browser.settings.usesSpaces {
                if browser.pins.isShared(def.id) {
                    Button("Keep in This Space", systemImage: "square") { browser.keepHere(tab) }
                } else {
                    Button("Show in Every Space", systemImage: "square.on.square") { browser.showEverywhere(tab) }
                }
            }
            Button("Close Pin", systemImage: "xmark") { browser.close(tab) }
                .accessibilityIdentifier("pin-close")
            Button("Unpin", systemImage: "pin.slash") { browser.unpin(tab) }
                .accessibilityIdentifier("pin-unpin")
        } else if browser.canPin(tab) {
            Button("Pin Tab", systemImage: "pin") { browser.pin(tab) }
                .accessibilityIdentifier("pin-tab")
        }
    }
}

extension View {
    /// The question that renames a pin, while `tab` is set.
    func pinRenaming(_ tab: Binding<Tab?>, browser: Browser) -> some View {
        modifier(PinRenaming(tab: tab, browser: browser))
    }
}

private struct PinRenaming: ViewModifier {
    @Binding var tab: Tab?
    let browser: Browser
    @State private var name = ""
    @State private var letter = ""

    func body(content: Content) -> some View {
        content.alert("Rename Pin", isPresented: Binding(get: { tab != nil }, set: { if !$0 { tab = nil } })) {
            TextField("Name", text: $name).accessibilityIdentifier("pin-name")
            TextField("Letter", text: $letter).accessibilityIdentifier("pin-letter")
            Button("Rename") {
                if let tab {
                    let named = name.trimmingCharacters(in: .whitespaces)
                    let first = letter.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() }
                    browser.editPin(tab) { def in
                        def.name = named.isEmpty ? nil : named
                        // Empty leaves the letter as it was: a square with
                        // nothing on it could never be told apart.
                        if let first { def.letter = first }
                    }
                }
                tab = nil
            }
            Button("Cancel", role: .cancel) { tab = nil }
        } message: {
            Text("Its name, and the letter on its square.")
        }
        .onChange(of: tab) { _, now in
            guard let now, let def = browser.pinDef(of: now) else { return }
            name = def.name ?? ""
            letter = def.letter
        }
    }
}
