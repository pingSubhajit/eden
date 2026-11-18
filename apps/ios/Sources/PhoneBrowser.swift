import EdenCore
import SwiftUI

/// iPhone: the page takes the screen, and the address field sits at the
/// bottom, within the thumb's reach, over a row of buttons. Tapping the
/// field brings up the keyboard with the suggestions above it.
struct PhoneBrowser: View {
    let browser: Browser
    @State private var typing = Typing()
    @FocusState private var focused: Bool
    @State private var showingTabs = false
    @State private var showingPrivate = false
    @State private var sheet: BrowserSheet?
    @State private var covered: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tab = browser.active
        ZStack {
            TabContent(browser: browser, tab: tab)
                .environment(\.pageCovered, covered)
                .ignoresSafeArea(edges: .bottom)
            if typing.editing { editor }
        }
        // What the bar below covers of the page running on under it.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { covered = $0 }
        // Picking things to hide takes the bar's place, the page scrolling
        // clear of it as of the bar, so nothing is out of a finger's reach.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if browser.picking != nil {
                HidingBar(browser: browser)
            } else if !typing.editing {
                bar(tab)
            }
        }
        .fullScreenCover(isPresented: $showingTabs) {
            TabOverview(browser: browser, showingPrivate: $showingPrivate) { showingTabs = false }
        }
        .sheet(item: $sheet) { which in
            BrowserSheets(which: which, browser: browser)
        }
        .onChange(of: typing.editing) { _, editing in focused = editing }
        .onChange(of: focused) { _, now in
            if now { typing.focused() } else if typing.editing { typing.cancel() }
        }
    }

    private func bar(_ tab: Tab?) -> some View {
        VStack(spacing: 6) {
            AddressPill(tab: tab) { typing.start(over: tab) }
            HStack {
                Button("Back", systemImage: "chevron.backward") { tab?.goBack() }
                    .disabled(!(tab?.canGoBack ?? false))
                    .accessibilityIdentifier("back")
                Spacer()
                Button("Forward", systemImage: "chevron.forward") { tab?.goForward() }
                    .disabled(!(tab?.canGoForward ?? false))
                    .accessibilityIdentifier("forward")
                Spacer()
                BrowserMenu(browser: browser, tab: tab, sheet: $sheet)
                Spacer()
                Button {
                    showingPrivate = tab?.isPrivate ?? false
                    showingTabs = true
                } label: {
                    TabCount(count: (tab?.isPrivate ?? false) ? browser.privateTabs.count : browser.spaceTabs.count)
                }
                .accessibilityIdentifier("tabs")
                .accessibilityLabel("Tabs")
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .padding(.horizontal, 12)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(.bar)
        // A private tab's bar is dark, whatever the phone's appearance, so
        // which kind of tab is in front shows at a glance, as in Safari.
        .environment(\.colorScheme, (tab?.isPrivate ?? false) ? .dark : colorScheme)
    }

    /// Typing: the suggestions, and the field at the bottom above the keyboard.
    private var editor: some View {
        VStack(spacing: 0) {
            ScrollView {
                SuggestionList(offers: typing.offers(in: browser)) { typing.pick($0, in: browser) }
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            HStack(spacing: 10) {
                AddressEditor(text: $typing.text, selection: $typing.selection, focus: $focused) { typing.submit(in: browser) }
                Button("Cancel") { typing.cancel() }
                    .accessibilityIdentifier("cancel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .background(Color(.systemBackground))
    }
}

/// The tabs button: how many there are, in a rounded square.
struct TabCount: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? ":)" : "\(count)")
            .font(.footnote.weight(.bold))
            .frame(width: 24, height: 24)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary, lineWidth: 1.6))
    }
}

/// The sheet the menu opened, each opening its page in the tab in front.
struct BrowserSheets: View {
    let which: BrowserSheet
    let browser: Browser

    var body: some View {
        switch which {
        case .bookmarks: BookmarksSheet(browser: browser, open: open)
        case .history: HistorySheet(browser: browser, open: open)
        case .settings: SettingsSheet(settings: browser.settings, browser: browser)
        case .hidden:
            if let tab = browser.active { HiddenSheet(browser: browser, tab: tab, curtain: browser.curtain) }
        }
    }

    private func open(_ url: URL) {
        if let tab = browser.active { tab.load(url) } else { browser.newTab(url: url) }
    }
}
