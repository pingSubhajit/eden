import EdenCore
import SwiftUI

// Your other devices' open tabs, in the column: a group for each device
// under the pins, above the line over your own tabs, as Dia's Pull Requests
// is — a group of the browser's, not yours to rename, colour or close —
// folded until it is opened; opened, the tabs open on that device in this
// space. A tab picked comes here as it does from History › Tabs on Other
// Devices: to its tab if it is open here
// already, else in its own space, as far down as it was read
// (Browser.open(_ offer:)).

/// Told whenever the pages open in this Mac's windows may have changed: a
/// row written, a page come in, a window closed. What says "Open" beside
/// another device's tab follows it, whichever window changed.
@MainActor
final class OpenPages: ObservableObject {
    static let shared = OpenPages()
    /// Posted where a page comes in and a window closes.
    static let changed = Notification.Name("EdenOpenPagesChanged")
    @Published private(set) var revision = 0
    private var watching: [NSObjectProtocol] = []

    private init() {
        for name in [OpenPages.changed, Sync.tabsChanged] {
            watching.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.revision += 1 }
            })
        }
    }
}

/// How many tabs each of your other devices has open in each space, said
/// only when that changes: what the column needs to know to draw their
/// groups, the line under them and room for their rows, without being
/// drawn again for every title another device changes. By device as well as space: one group growing as
/// another shrinks still changes the room they take.
@MainActor
final class ElsewherePresence: ObservableObject {
    struct Place: Hashable {
        let device: String
        /// Nil for tabs in no space, from a device without spaces.
        let space: UUID?
    }

    @Published private(set) var counts: [Place: Int] = [:]

    var hasTabs: Bool { !counts.isEmpty }

    func set(_ devices: [DeviceTabs]) {
        var now: [Place: Int] = [:]
        for device in devices {
            for page in device.tabs { now[Place(device: device.device, space: page.space), default: 0] += 1 }
        }
        if now != counts { counts = now }
    }
}

extension Tab {
    /// The page it shows and is staying on, by History.identity; nil while
    /// it is on its way to another. What a page from another device may come
    /// to, and what is said to be open here.
    var settledIdentity: String? {
        guard let shown = restAddress, let going = address,
              History.identity(for: shown) == History.identity(for: going) else { return nil }
        return History.identity(for: shown)
    }
}

extension Sync {
    /// The devices with tabs open, as sync last heard: none while it is off.
    var devicesWithTabs: [DeviceTabs] { elsewhere.filter(\.hasTabs) }

    /// Why `device` won't open `tab` sent from `space`, as said when it is
    /// let go on that device's group or sent from a menu; nil when it will.
    /// It takes a page the other devices can be shown (Sync.page(of:in:))
    /// that it hasn't open already. A pin goes only once it has gone on
    /// from its home: at its home it is on every device already.
    func refusal(sending tab: Tab, from space: UUID, to device: DeviceTabs) -> String? {
        let name = device.name
        guard let page = Sync.page(of: tab, in: space), let url = URL(string: page.url) else {
            if tab.shy { return "Private tabs stay on this Mac" }
            if tab.pin != nil, tab.isHome(tab.restAddress) { return "\(name) has this pin already" }
            return "This page can't be opened on \(name)"
        }
        let identity = History.identity(for: url)
        guard !device.tabs.contains(where: { URL(string: $0.url).map(History.identity(for:)) == identity }) else {
            return "Already open on \(name)"
        }
        return nil
    }

    /// Why `device` won't open any of `tabs`, sent together: nil when it
    /// takes at least one. Turned down all for one reason, that reason;
    /// for several, that these pages can't be opened there.
    func refusal(sending tabs: [Tab], from space: UUID, to device: DeviceTabs) -> String? {
        var refusals: [String] = []
        for tab in tabs {
            guard let why = refusal(sending: tab, from: space, to: device) else { return nil }
            refusals.append(why)
        }
        return Sync.saying(refusals, on: device)
    }

    /// What is said of `refusals` from one device: the one reason they
    /// share, or that the pages can't be opened there. Nil for none.
    static func saying(_ refusals: [String], on device: DeviceTabs) -> String? {
        guard let first = refusals.first else { return nil }
        return Set(refusals).count == 1 ? first : "These pages can't be opened on \(device.name)"
    }
}

extension Browser {
    /// Send to ‹device›, from a tab's menu or Tabs in the menu bar, and
    /// tabs let go on its group in the column (`dropped`): each tab opened
    /// on that device too, and kept here (Sync.askToOpen). A device needn't
    /// have tabs in this space, or any, to be sent one. What it won't take
    /// is said, either way. What it will is said from a menu, as the device
    /// may be out of sight in the column; let go on its group, nothing is
    /// said, the rows coming into that group under the hand.
    func send(_ tabs: [Tab], to device: DeviceTabs, dropped: Bool = false) {
        let sync = Sync.shared
        guard sync.on, !tabs.isEmpty else { return }
        var refusals: [String] = []
        var sent = 0
        for tab in tabs {
            // As the device is shown now, with what was just sent to it, so
            // two tabs of one page go once.
            let now = sync.elsewhere.first { $0.device == device.device } ?? device
            if let why = sync.refusal(sending: tab, from: spaceID, to: now) {
                refusals.append(why)
            } else if sync.askToOpen(tab, in: spaceID, on: device.device) {
                sent += 1
            }
        }
        guard let why = refusals.first else {
            if !dropped { announce("Sent to \(device.name)", look: .done) }
            return
        }
        if sent > 0, !dropped {
            announce("Sent \(sent) of \(tabs.count) to \(device.name)", look: .done)
        } else {
            // Let go on its group, what went is in sight there: only why
            // the rest didn't is said.
            announce(sent > 0 ? why : Sync.saying(refusals, on: device) ?? why)
        }
    }

    /// Open in New Tab, from another device's row: always a tab of its own
    /// here, in front, even when the page is open here already (a click
    /// on the row goes to that one), shown as it was left there.
    func openInNewTab(_ offer: Elsewhere.Offer) {
        guard let url = URL(string: offer.page.url) else { return }
        let tab = open(url, foreground: true, from: active, loose: true)
        tab.arrival = Tab.Arrival(page: url, scroll: offer.page.scroll, reading: offer.page.reading == true,
                                  from: offer.deviceName)
    }

    /// Open All Here, from another device's group: its pages in this space
    /// not open here yet, each a tab behind the one you are on, in their
    /// order; the ones open here already are left where they are.
    func openAllHere(_ pages: [DeviceTabs.Page], of device: DeviceTabs) {
        let open = openHere
        for page in pages {
            guard let url = URL(string: page.url), !open.contains(History.identity(for: url)) else { continue }
            let tab = self.open(url, foreground: false, from: active, loose: true)
            tab.arrival = Tab.Arrival(page: url, scroll: page.scroll, reading: page.reading == true, from: device.name)
        }
    }
}

/// Send to, in a tab's menu and Tabs in the menu bar: each of your other
/// devices sync knows, by name, whether or not it has tabs open in this
/// space. Not there while sync knows of none.
struct SendToMenu: View {
    @ObservedObject private var sync = Sync.shared
    let browser: Browser
    let tabs: [Tab]

    var body: some View {
        let devices = sync.elsewhere
        if !devices.isEmpty {
            Menu("Send to") {
                ForEach(devices, id: \.device) { device in
                    Button {
                        browser.send(tabs, to: device)
                    } label: {
                        Label(device.name, systemImage: device.kind.symbol)
                    }
                }
            }
            .disabled(tabs.isEmpty)
        }
    }
}

extension DeviceTabs.Kind {
    /// The device's symbol.
    var symbol: String {
        switch self {
        case .mac: return "laptopcomputer"
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        }
    }
}

extension Browser {
    /// Another device's pages under this window's spaces, in their order,
    /// while spaces are on — the column's and History's alike.
    func spaceGroups(_ pages: [DeviceTabs.Page]) -> [(title: String?, pages: [DeviceTabs.Page])] {
        guard prefs.usesSpaces else { return [(nil, pages)] }
        return Elsewhere.bySpace(pages, order: spaces.map(\.id)).map { group in
            (group.space.flatMap { id in spaces.first { $0.id == id }?.name }, group.pages)
        }
    }

    /// Another device's pages in one of this window's spaces, for its group
    /// in the column: those open there in that space, and in the first
    /// space those from a device without spaces, or in one this Mac hasn't.
    func pages(_ pages: [DeviceTabs.Page], in space: UUID) -> [DeviceTabs.Page] {
        guard prefs.usesSpaces else { return pages }
        let known = Set(spaces.map(\.id))
        let first = space == spaces.first?.id
        return pages.filter { page in
            page.space == space || (first && page.space.map { !known.contains($0) } ?? true)
        }
    }
}

/// Your other devices' groups in one space's column, under its pins: a group
/// for each device with tabs open in that space, in the order sync heard
/// from them, newest first.
struct DeviceGroups: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let space: UUID
    @Binding var opened: Set<String>
    /// A tab carried in the column onto one of these, by the device's id,
    /// and the room it needs: it opens there too (ColumnCarry.Target.device).
    /// Where each group is drawn is the column's layout's (ColumnLayout).
    var gap: (device: String, height: CGFloat)? = nil
    var gapFrame = RowGapFrame()
    @ObservedObject private var sync = Sync.shared
    @ObservedObject private var pages = OpenPages.shared

    var body: some View {
        // Once for every group, whichever window changed (OpenPages).
        let open = browser.openHere
        ForEach(sync.devicesWithTabs, id: \.device) { device in
            let here = browser.pages(device.tabs, in: space)
            if !here.isEmpty {
                DeviceGroup(browser: browser, prefs: prefs, device: device, pages: here, open: open,
                            opened: opened.contains(device.device),
                            gap: gap?.device == device.device ? gap?.height : nil, gapFrame: gapFrame) {
                    if !opened.insert(device.device).inserted { opened.remove(device.device) }
                }
                // A device's last page closed takes its group, as your
                // tabs' rows go; the column settles round it (SideBar).
                .transition(.sideRow)
            }
        }
    }
}

/// Another device's tabs in the column: a group like yours (SideGroup), in
/// Stone, the device's symbol and name in its heading, folded until opened.
/// The browser's, not yours: it can be opened, not renamed, coloured or
/// closed.
struct DeviceGroup: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let device: DeviceTabs
    /// Its tabs in this space (Browser.pages(_:in:)).
    let pages: [DeviceTabs.Page]
    /// The pages open in this profile's windows, by History.identity.
    let open: Set<String>
    let opened: Bool
    /// A tab carried onto it: the room its page will take, at the end, the
    /// group lit and open to show it as a tab group shows one.
    var gap: CGFloat? = nil
    var gapFrame = RowGapFrame()
    let toggle: () -> Void

    @State private var hovering = false

    /// Its symbol, name and chevron: a tab title's strength, up under the
    /// pointer, as a group's heading has them.
    private var ink: Color { hovering ? GroupColour.stone.lifted : GroupColour.stone.title }

    var body: some View {
        SideGroup(colour: .stone, folded: !opened, lit: gap != nil,
                  showsRows: DeviceRows.shown(opened: opened, carried: gap != nil)) {
            GroupLabel(row: prefs.sideRow, toggle: toggle) {
                Image(systemName: device.kind.symbol)
                    .font(.system(size: prefs.sideMark * 0.8, weight: .medium))
                    .foregroundStyle(ink)
                    .frame(width: prefs.sideMark, height: prefs.sideMark)
            } title: {
                GroupName(name: device.name, ink: ink, collapsed: !opened, size: prefs.sideTitle)
            } end: {
                EmptyView()
            }
            .help(opened ? "Hide the tabs open on \(device.name)" : "Show the tabs open on \(device.name)")
            // At once, as a group's heading comes up.
            .onHover { hovering = $0 }
            .groupAccessibility(name: device.name, collapsed: !opened, toggle: toggle)
            // As a group's heading has its menu: what can be done with all
            // of the device's pages here.
            .contextMenu {
                Button("Open All Here") { browser.openAllHere(pages, of: device) }
                    .disabled(pages.allSatisfy { page in URL(string: page.url).map { open.contains(History.identity(for: $0)) } ?? true })
                Button("Copy All Links") { browser.copy(links: pages.map(\.url)) }
                Divider()
                Button(opened ? "Collapse" : "Expand", action: toggle)
            }
        } rows: {
            // By page, each once on its device, as your tabs' rows are by
            // tab: one closed goes as a tab's does (sideRow).
            ForEach(pages, id: \.url) { page in
                ElsewhereRow(prefs: prefs, page: page, deviceName: device.name,
                             openHere: URL(string: page.url).map { open.contains(History.identity(for: $0)) } ?? false,
                             close: { Sync.shared.askToClose(page, on: device.device) },
                             openInNewTab: { browser.openInNewTab(Elsewhere.Offer(device: device, page: page)) },
                             copy: { browser.copy(addresses: [page.url]) }) {
                    browser.open(Elsewhere.Offer(device: device, page: page))
                }
                .transition(.sideRow)
            }
            if let gap { RowGapSlot(height: gap, frame: gapFrame) }
        }
    }
}

/// One of another device's tabs, drawn as a tab's line in the column is:
/// its site's mark, with a green dot carved into it when it is open here
/// already, and its title; a click switches to it here, or opens it. Under
/// the pointer, a cross closes it on its device, as a tab's closes it here.
private struct ElsewhereRow: View {
    @Environment(\.greys) private var greys
    @ObservedObject var prefs: Preferences
    let page: DeviceTabs.Page
    let deviceName: String
    let openHere: Bool
    /// Closes it on its device (Sync.askToClose).
    let close: () -> Void
    /// Its menu's Open in New Tab and Copy Address.
    let openInNewTab: () -> Void
    let copy: () -> Void
    let open: () -> Void
    @State private var hovering = false

    private var url: URL? { URL(string: page.url) }
    private var title: String { page.title.isEmpty ? (url.map(Address.pretty) ?? page.url) : page.title }
    private var letter: String { String((url?.host().map(Address.withoutWWW) ?? "?").prefix(1)).uppercased() }

    var body: some View {
        Button(action: open) {
            HStack(spacing: Metrics.rowSpacing) {
                Mark(icon: Favicons.shared.cached(for: url), letter: letter, size: prefs.sideMark)
                    .modifier(OpenHereDot(on: openHere, size: prefs.sideMark))
                Text(title)
                    .font(.system(size: prefs.sideTitle))
                    .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                    .lineLimit(1)
                    .fadesOut(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.rowInset)
            .frame(height: prefs.sideRow)
            // The title fades out beneath the cross rather than being cut
            // shorter, as a tab's does.
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    if hovering {
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 16)
                        Color.clear.frame(width: RowCross.size + Metrics.rowCrossInset + 2)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(hovering ? greys.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if hovering {
                RowCross(height: prefs.sideRow, action: close)
                    .padding(.trailing, Metrics.rowCrossInset)
                    .help("Close on \(deviceName)")
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        // Its own menu, as your tabs' rows have theirs.
        .contextMenu {
            Button("Open", action: open)
            Button("Open in New Tab", action: openInNewTab)
            Button("Copy Address", action: copy)
            Divider()
            Button("Close on \(deviceName)", action: close)
        }
        .help(openHere ? "Open here already: switch to it" : (url.map(Address.pretty) ?? page.url))
        .accessibilityLabel(openHere ? "\(title), open here" : title)
        .accessibilityHint(openHere ? "Switches to it here" : "Opens it here")
        .accessibilityAction(named: "Close on \(deviceName)", close)
    }
}

/// A small green dot at a site mark's foot, carved into it with a ring of
/// nothing round it so it reads on any icon and any ground: the page is
/// open here already.
private struct OpenHereDot: ViewModifier {
    let on: Bool
    let size: CGFloat

    func body(content: Content) -> some View {
        let dot = (size * 0.32).rounded()
        let ring = max(1.25, size * 0.08)
        // Its middle a little past the mark's corner.
        let out = dot * 0.2
        content
            .mask {
                if on {
                    Rectangle()
                        .overlay(alignment: .bottomTrailing) {
                            Circle()
                                .frame(width: dot + ring * 2, height: dot + ring * 2)
                                .offset(x: out + ring, y: out + ring)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                } else {
                    Rectangle()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if on {
                    Circle()
                        .fill(Color(nsColor: .systemGreen))
                        .frame(width: dot, height: dot)
                        .offset(x: out, y: out)
                        .accessibilityHidden(true)
                }
            }
    }
}
