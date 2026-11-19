import EdenCore
import SwiftUI

// Your other devices' open tabs, as sync last heard of them (Syncing): on
// the iPad, sections at the foot of the sidebar; on the iPhone, under the
// tab cards. A tap opens the page in a new tab here.

extension DeviceTabs.Kind {
    var symbol: String {
        switch self {
        case .mac: return "laptopcomputer"
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        }
    }
}

extension DeviceTabs.Page {
    var address: URL? { URL(string: url) }
    var shownTitle: String { title.isEmpty ? (address.map(Address.pretty) ?? url) : title }
}

/// A device's pages, under the spaces they are open in while spaces are on.
private func grouped(_ device: DeviceTabs, in browser: Browser) -> [(title: String?, pages: [DeviceTabs.Page])] {
    guard browser.settings.usesSpaces else { return [(nil, device.tabs)] }
    return Elsewhere.bySpace(device.tabs, order: browser.spaces.map(\.id)).map { group in
        (group.space.flatMap { browser.library.space($0)?.name }, group.pages)
    }
}

/// One of another device's pages: a tap brings it here, to its tab if it is
/// open here already.
private struct ElsewhereRow: View {
    let browser: Browser
    let device: DeviceTabs
    let page: DeviceTabs.Page
    var opened: () -> Void = {}

    var body: some View {
        Button {
            browser.open(Elsewhere.Offer(device: device, page: page))
            opened()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.shownTitle).lineLimit(1)
                    Text(page.address.map(Address.pretty) ?? page.url)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if browser.isOpenHere(page) {
                    Text("Open Here").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(browser.isOpenHere(page) ? "Switches to it here" : "Opens it here")
        .accessibilityIdentifier("other-tab")
    }
}

/// The iPad's sidebar: a section for each device, its pages under their
/// spaces.
struct OtherDeviceSections: View {
    let browser: Browser

    var body: some View {
        ForEach(browser.elsewhere.filter(\.hasTabs), id: \.device) { device in
            Section {
                ForEach(Array(grouped(device, in: browser).enumerated()), id: \.offset) { _, group in
                    if let title = group.title {
                        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(group.pages.enumerated()), id: \.offset) { _, page in
                        ElsewhereRow(browser: browser, device: device, page: page)
                    }
                }
            } header: {
                Label(device.name, systemImage: device.kind.symbol)
            }
        }
    }
}

// MARK: - opening them here

extension Browser {
    /// Your other devices' open tabs, freshest first: none while sync is off.
    var elsewhere: [DeviceTabs] { sync?.otherTabs ?? [] }

    /// Every page open here, by History.identity.
    var openHere: Set<String> { Set(ordinaryTabs.compactMap { $0.url.map(History.identity(for:)) }) }

    /// Whether a page from another device is open here already.
    func isOpenHere(_ page: DeviceTabs.Page) -> Bool {
        guard let url = page.address else { return false }
        return openHere.contains(History.identity(for: url))
    }

    /// A page from another device, here: its tab if it is open here already
    /// — the one in its own space first — never a second; otherwise opened
    /// in the space it was open in, when this device has it, read as far
    /// down and as an article if it was. `empty`: a tab with nowhere to be
    /// yet, to open it in rather than beside.
    func open(_ offer: Elsewhere.Offer, in empty: Tab? = nil) {
        guard let url = offer.page.address else { return }
        let space = offer.page.space.flatMap { settings.usesSpaces && library.space($0) != nil ? $0 : nil } ?? spaceID
        let identity = History.identity(for: url)
        let arrival = Tab.Arrival(page: url, scroll: offer.page.scroll, reading: offer.page.reading == true,
                                  from: offer.deviceName)
        let open = ordinaryTabs.filter { $0.url.map(History.identity(for:)) == identity }
        if let here = open.first(where: { $0.owner == .space(space) }) ?? open.first {
            select(here)
            // Shown as it was left there, when there was anything to carry.
            if arrival.scroll != nil || arrival.reading { here.carry(on: arrival) }
            return
        }
        if let empty, empty.url == nil, empty.owner == .space(space) {
            empty.arrival = arrival
            empty.load(url)
            select(empty)
            return
        }
        if space != spaceID { enter(space) }
        newTab(url: url).arrival = arrival
    }
}
