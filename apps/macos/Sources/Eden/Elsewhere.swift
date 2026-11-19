import EdenCore
import SwiftUI

// Your other devices' open tabs, in the column: a group for each device
// under the pins, above the line over your own tabs, as Dia's Pull Requests
// is — a group of the browser's, not yours to rename, colour or close —
// folded until it is opened; opened, the tabs open on that device in this
// space. With icons only, a door in the foot opens every device's list
// beside the column, under the spaces they are open in. A tab picked comes here as it does
// from History › Tabs on Other Devices: to its tab if it is open here
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
/// groups, the line under them and room for their rows, and the door to
/// them with icons only, without being drawn again for every title another
/// device changes. By device as well as space: one group growing as
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
    @ObservedObject private var sync = Sync.shared
    @ObservedObject private var pages = OpenPages.shared

    var body: some View {
        // Once for every group, whichever window changed (OpenPages).
        let open = browser.openHere
        ForEach(sync.devicesWithTabs, id: \.device) { device in
            let here = browser.pages(device.tabs, in: space)
            if !here.isEmpty {
                DeviceGroup(browser: browser, prefs: prefs, device: device, pages: here, open: open,
                            opened: opened.contains(device.device)) {
                    if !opened.insert(device.device).inserted { opened.remove(device.device) }
                }
            }
        }
    }
}

/// Another device's tabs in the column: a group of its own, on Stone's
/// surface, the device's symbol and name in its heading. Folded, it keeps
/// its surface, as Dia's Pull Requests does, where a folded group of yours
/// has none: the browser's, not yours. It can't be renamed, coloured or
/// closed, only opened.
struct DeviceGroup: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let device: DeviceTabs
    /// Its tabs in this space (Browser.pages(_:in:)).
    let pages: [DeviceTabs.Page]
    /// The pages open in this profile's windows, by History.identity.
    let open: Set<String>
    let opened: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: SideBar.gap) {
            Button { withAnimation(GroupLook.fold) { toggle() } } label: {
                HStack(spacing: Metrics.rowSpacing) {
                    Image(systemName: device.kind.symbol)
                        .font(.system(size: prefs.sideMark * 0.8, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: prefs.sideMark, height: prefs.sideMark)
                    Text(device.name)
                        .groupName(Palette.ink, size: prefs.sideTitle)
                        .lineLimit(1)
                        .fadesOut(device.name)
                        .layoutPriority(1)
                    GroupChevron(collapsed: !opened, ink: Palette.ink)
                    Spacer(minLength: 0)
                }
                .modifier(GroupHeadingFrame(row: prefs.sideRow))
            }
            .buttonStyle(.plain)
            .help(opened ? "Hide the tabs open on \(device.name)" : "Show the tabs open on \(device.name)")
            .accessibilityLabel("\(device.name), \(pages.count) \(pages.count == 1 ? "tab" : "tabs")")
            .accessibilityValue(opened ? "Open" : "Folded")
            if opened {
                VStack(spacing: SideBar.gap) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                        ElsewhereRow(prefs: prefs, page: page,
                                     openHere: URL(string: page.url).map { open.contains(History.identity(for: $0)) } ?? false) {
                            browser.open(Elsewhere.Offer(device: device, page: page))
                        }
                        .padding(.leading, GroupLook.indent)
                    }
                }
            }
        }
        .modifier(GroupSurface(colour: .stone))
    }
}

/// A device's tabs, under the spaces they are open in while spaces are on.
struct ElsewhereTabs: View {
    @ObservedObject var browser: Browser
    let device: DeviceTabs
    /// The pages open in this profile's windows, by History.identity.
    let open: Set<String>
    /// Told once a tab is picked: a popover showing them goes away.
    var picked: () -> Void = {}

    var body: some View {
        ForEach(Array(browser.spaceGroups(device.tabs).enumerated()), id: \.offset) { _, group in
            if let title = group.title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            ForEach(Array(group.pages.enumerated()), id: \.offset) { _, page in
                ElsewhereRow(prefs: browser.prefs, page: page, openHere: URL(string: page.url).map { open.contains(History.identity(for: $0)) } ?? false) {
                    browser.open(Elsewhere.Offer(device: device, page: page))
                    picked()
                }
            }
        }
    }
}

/// One of another device's tabs, drawn as a tab's line in the column is:
/// its site's mark and its title, and whether it is open here already,
/// which a click switches to.
private struct ElsewhereRow: View {
    @Environment(\.greys) private var greys
    @ObservedObject var prefs: Preferences
    let page: DeviceTabs.Page
    let openHere: Bool
    let open: () -> Void
    @State private var hovering = false

    private var url: URL? { URL(string: page.url) }
    private var title: String { page.title.isEmpty ? (url.map(Address.pretty) ?? page.url) : page.title }
    private var letter: String { String((url?.host().map(Address.withoutWWW) ?? "?").prefix(1)).uppercased() }

    var body: some View {
        Button(action: open) {
            HStack(spacing: Metrics.rowSpacing) {
                Mark(icon: Favicons.shared.cached(for: url), letter: letter, size: prefs.sideMark)
                Text(title)
                    .font(.system(size: prefs.sideTitle))
                    .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                    .lineLimit(1)
                    .fadesOut(title)
                Spacer(minLength: 0)
                if openHere {
                    Text("Open")
                        .font(.system(size: prefs.sideTitle - 2))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, Metrics.rowInset)
            .frame(height: prefs.sideRow)
            .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(hovering ? greys.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(openHere ? "Open here already: switch to it" : (url.map(Address.pretty) ?? page.url))
        .accessibilityLabel(title)
        .accessibilityHint(openHere ? "Switches to it here" : "Opens it here")
    }
}

/// With icons only: a door in the foot, while another device has tabs open,
/// opening every device's list beside the column.
struct ElsewhereDoor: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var sync = Sync.shared
    let arrowEdge: Edge
    @State private var showing = false

    var body: some View {
        let devices = sync.devicesWithTabs
        if !devices.isEmpty {
            Door(icon: "laptopcomputer.and.iphone", on: showing, help: "Tabs on Other Devices") { showing.toggle() }
                .popover(isPresented: $showing, arrowEdge: arrowEdge) {
                    ElsewherePopover(browser: browser, devices: devices) { showing = false }
                }
        }
    }
}

/// Every device's list, beside the icons-only column.
private struct ElsewherePopover: View {
    @ObservedObject var browser: Browser
    let devices: [DeviceTabs]
    let picked: () -> Void
    @ObservedObject private var pages = OpenPages.shared

    var body: some View {
        // Once for every list, whichever window changed (OpenPages).
        let open = browser.openHere
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(devices, id: \.device) { device in
                    Label(device.name, systemImage: device.kind.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                    ElsewhereTabs(browser: browser, device: device, open: open, picked: picked)
                }
            }
            .padding(8)
        }
        .frame(width: 300)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
