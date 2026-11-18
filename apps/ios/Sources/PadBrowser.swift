import EdenCore
import SwiftUI

/// iPad: the tabs down a sidebar, as on the Mac, and the address field at
/// the top of the page, its suggestions dropping down under it.
struct PadBrowser: View {
    let browser: Browser
    @State private var typing = Typing()
    @FocusState private var focused: Bool
    @State private var sheet: BrowserSheet?
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            detail
        }
        .sheet(item: $sheet) { which in BrowserSheets(which: which, browser: browser) }
        .onChange(of: typing.editing) { _, editing in focused = editing }
        .onChange(of: focused) { _, now in
            if now { typing.focused() } else if typing.editing { typing.cancel() }
        }
    }

    private var sidebar: some View {
        List {
            if browser.settings.usesSpaces {
                Section { SpaceSwitcher(browser: browser) }
            }
            if !browser.shownPins.isEmpty {
                Section("Pinned") { PinStrip(browser: browser, container: "sidebar") }
            }
            Section("Tabs") {
                ForEach(browser.looseTabs) { row($0) }
            }
            if !browser.privateTabs.isEmpty {
                Section("Private") {
                    ForEach(browser.privateTabs) { row($0) }
                }
            }
            OtherDeviceSections(browser: browser)
        }
        .navigationTitle("Eden")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Tab", systemImage: "plus.square") { browser.newTab() }
                    Button("New Private Tab", systemImage: "eye.slash") { browser.newTab(private: true) }
                } label: {
                    Label("New Tab", systemImage: "plus")
                } primaryAction: {
                    browser.newTab()
                }
                .accessibilityIdentifier("new-tab")
            }
        }
    }

    private func row(_ tab: Tab) -> some View {
        Button { browser.select(tab) } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.isPrivate ? "eye.slash" : "globe").foregroundStyle(.secondary)
                Text(tab.title.isEmpty ? (tab.url.map(Address.pretty) ?? "New Tab") : tab.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(tab.id == browser.activeID ? Color.accentColor.opacity(0.18) : nil)
        .swipeActions { Button("Close", role: .destructive) { browser.close(tab) } }
        .contextMenu { Button("Close Tab", systemImage: "xmark", role: .destructive) { browser.close(tab) } }
        .accessibilityIdentifier("tab-row")
    }

    private var detail: some View {
        let tab = browser.active
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button("Back", systemImage: "chevron.backward") { tab?.goBack() }
                    .disabled(!(tab?.canGoBack ?? false))
                    .accessibilityIdentifier("back")
                Button("Forward", systemImage: "chevron.forward") { tab?.goForward() }
                    .disabled(!(tab?.canGoForward ?? false))
                    .accessibilityIdentifier("forward")
                Group {
                    if typing.editing {
                        HStack(spacing: 10) {
                            AddressEditor(text: $typing.text, selection: $typing.selection, focus: $focused) {
                                typing.submit(in: browser)
                            }
                            Button("Cancel") { typing.cancel() }
                                .font(.body)
                                .labelStyle(.titleOnly)
                                .accessibilityIdentifier("cancel")
                        }
                    } else {
                        AddressPill(tab: tab) { typing.start(over: tab) }
                    }
                }
                .frame(maxWidth: 640)
                BrowserMenu(browser: browser, tab: tab, sheet: $sheet)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .environment(\.colorScheme, (tab?.isPrivate ?? false) ? .dark : colorScheme)

            TabContent(browser: browser, tab: tab)
                // Below the page, never over what is to be tapped.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if browser.picking != nil { HidingBar(browser: browser) }
                }
                .overlay(alignment: .top) {
                    if typing.editing {
                        let offers = typing.offers(in: browser)
                        if !offers.isEmpty {
                            SuggestionList(offers: offers) { typing.pick($0, in: browser) }
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                                .frame(maxWidth: 640)
                                .padding(.top, 4)
                                .shadow(radius: 12, y: 4)
                        }
                    }
                }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
