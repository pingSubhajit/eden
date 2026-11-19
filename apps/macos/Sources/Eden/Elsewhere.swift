import EdenCore
import SwiftUI

// Your other devices' open tabs, in the column: a line for each device at the
// foot, over the row of doors, folded until it is opened; opened, its tabs
// under the spaces they are open in. With icons only, a door in the foot
// opens the same list beside the column. A tab picked comes here as it does
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

/// Whether another device has a tab open, said only when that changes: all
/// the column needs to know to keep room for the door to them.
@MainActor
final class ElsewherePresence: ObservableObject {
    @Published private(set) var hasTabs = false

    func set(_ now: Bool) {
        if now != hasTabs { hasTabs = now }
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

/// The devices with tabs open, as sync last heard: none while it is off.
@MainActor private func devices(_ sync: Sync) -> [DeviceTabs] { sync.elsewhere.filter(\.hasTabs) }

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
}

/// The lines at the column's foot, and the lists opened under them, in one
/// place that scrolls once taller than `maxHeight`: the rows and what plays
/// keep the rest of the column.
struct ElsewhereSection: View {
    @ObservedObject var browser: Browser
    let maxHeight: CGFloat
    /// The devices opened, by id: folded until opened, and as left while the
    /// window is open — kept by the column, through icons only and back.
    @Binding var opened: Set<String>
    @ObservedObject private var sync = Sync.shared
    @ObservedObject private var pages = OpenPages.shared
    /// How tall the lines and lists are, to stop at.
    @State private var content: CGFloat = 0

    var body: some View {
        let devices = devices(sync)
        // Once for every list, whichever window changed (OpenPages).
        let open = browser.openHere
        if !devices.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(devices, id: \.device) { device in
                        DeviceLine(device: device, open: opened.contains(device.device)) {
                            withAnimation(Motion.quick) {
                                if !opened.insert(device.device).inserted { opened.remove(device.device) }
                            }
                        }
                        if opened.contains(device.device) {
                            ElsewhereTabs(browser: browser, device: device, open: open)
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { content = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(content, maxHeight))
        }
    }
}

/// A device's line: its name and how many tabs it has open, and whether its
/// list is open.
private struct DeviceLine: View {
    @Environment(\.greys) private var greys
    let device: DeviceTabs
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: device.kind.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 16)
                Text(device.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("\(device.tabs.count)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? greys.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(open ? "Hide the tabs open on \(device.name)" : "Show the tabs open on \(device.name)")
        .accessibilityLabel("\(device.name), \(device.tabs.count) \(device.tabs.count == 1 ? "tab" : "tabs")")
        .accessibilityValue(open ? "Shown" : "Hidden")
        .accessibilityAddTraits(.isButton)
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
                ElsewhereRow(page: page, openHere: URL(string: page.url).map { open.contains(History.identity(for: $0)) } ?? false) {
                    browser.open(Elsewhere.Offer(device: device, page: page))
                    picked()
                }
            }
        }
    }
}

/// One of another device's tabs: its site's mark and its title, and whether
/// it is open here already, which a click switches to.
private struct ElsewhereRow: View {
    @Environment(\.greys) private var greys
    let page: DeviceTabs.Page
    let openHere: Bool
    let open: () -> Void
    @State private var hovering = false

    private var url: URL? { URL(string: page.url) }
    private var title: String { page.title.isEmpty ? (url.map(Address.pretty) ?? page.url) : page.title }
    private var letter: String { String((url?.host().map(Address.withoutWWW) ?? "?").prefix(1)).uppercased() }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Mark(icon: Favicons.shared.cached(for: url), letter: letter, size: 14)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if openHere {
                    Text("Open")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? greys.hover : .clear))
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
        let devices = devices(sync)
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
