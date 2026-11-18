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

/// The iPad's sidebar: a section for each device.
struct OtherDeviceSections: View {
    let browser: Browser

    var body: some View {
        ForEach(browser.sync?.otherTabs ?? [], id: \.device) { device in
            Section {
                ForEach(Array(device.tabs.enumerated()), id: \.offset) { _, page in
                    Button {
                        if let url = page.address { browser.newTab(url: url) }
                    } label: {
                        Label(page.shownTitle, systemImage: "globe").lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("other-tab")
                }
            } header: {
                Label(device.name, systemImage: device.kind.symbol)
            }
        }
    }
}

/// The iPhone's tab overview: under the cards, a list for each device.
struct OtherDeviceLists: View {
    let browser: Browser
    let opened: () -> Void

    var body: some View {
        let devices = browser.sync?.otherTabs ?? []
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                Text("On Your Other Devices").font(.headline)
                ForEach(devices, id: \.device) { device in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(device.name, systemImage: device.kind.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(device.tabs.enumerated()), id: \.offset) { _, page in
                            Button {
                                guard let url = page.address else { return }
                                browser.newTab(url: url)
                                opened()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(page.shownTitle).lineLimit(1)
                                    Text(page.address.map(Address.pretty) ?? page.url)
                                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("other-tab")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }
}
