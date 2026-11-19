import EdenCore
import SwiftUI
import WebKit

/// iPhone: the page takes the screen, and the controls float over its foot
/// on glass, within the thumb's reach, as Safari's do: back (and forward,
/// once there is somewhere to go), the address field with the page's menu
/// folded into it, and the tabs. Reading on down the page shrinks them to
/// the site's name; looking back up, or a tap on it, brings them back.
/// Tapping the field brings up the keyboard with the suggestions above it.
struct PhoneBrowser: View {
    let browser: Browser
    @State private var typing = Typing()
    @FocusState private var focused: Bool
    @State private var showingTabs = false
    @State private var showingPrivate = false
    @State private var sheet: BrowserSheet?
    @State private var covered: CGFloat = 0
    /// What the status bar covers of the page running on up under it.
    @State private var top: CGFloat = 0
    /// Whether the controls are shrunk to the site's name, the page read.
    @State private var tuck = BarTuck()
    @Namespace private var glass
    @Environment(\.colorScheme) private var colorScheme

    /// How the controls change shape: the system's own spring, the glass
    /// flowing from one shape into the next.
    private static let motion = Animation.smooth(duration: 0.35)

    var body: some View {
        let tab = browser.active
        ZStack {
            TabContent(browser: browser, tab: tab)
                .environment(\.pageCovered, covered)
                .environment(\.pageTop, top)
                .environment(\.barTuck, tuck)
                .ignoresSafeArea(edges: .bottom)
            if typing.editing { suggestions }
        }
        // What the bar below covers of the page running on under it. Not
        // the keyboard while typing: the page is out of sight then, and
        // would only be laid out again twice for nothing.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { now in
            if !typing.editing { covered = now }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { top = $0 }
        // Picking things to hide takes the bar's place, the page scrolling
        // clear of it as of the bar, so nothing is out of a finger's reach.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if browser.picking != nil {
                HidingBar(browser: browser)
            } else {
                bar(tab)
            }
        }
        .background(StatusBarStyle(style: statusBar(tab)))
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
        // Another tab, another page, typing or picking: the controls in
        // full, as Safari brings them back for each page, and kept so
        // while typing or picking whatever the page does.
        .onChange(of: browser.activeID) { tuck.untuck() }
        .onChange(of: tab?.url) { tuck.untuck() }
        .onChange(of: typing.editing || browser.picking != nil, initial: true) { _, busy in
            tuck.held = busy
            tuck.untuck()
        }
    }

    private var tucked: Bool { tuck.tucked }

    /// The status bar over the page running up under it: dark writing on a
    /// light page, light on a dark one, as Safari's. As the phone has it
    /// over anything else: typing, a sheet, the tabs.
    private func statusBar(_ tab: Tab?) -> UIStatusBarStyle {
        guard let tab, !typing.editing, sheet == nil, !showingTabs else { return .default }
        // A private tab's start page is dark, whatever the phone's appearance.
        guard tab.url != nil else { return tab.isPrivate ? .lightContent : .default }
        guard let light = tab.isLight else { return .default }
        return light ? .darkContent : .lightContent
    }

    private func bar(_ tab: Tab?) -> some View {
        let dark = (tab?.isPrivate ?? false) && !typing.editing
        return GlassEffectContainer(spacing: 10) {
            if typing.editing {
                editorRow
            } else if tucked {
                tuckedPill(tab)
            } else {
                HStack(spacing: 10) {
                    NavigationButtons(tab: tab)
                        .glassEffectID("navigation", in: glass)
                    AddressPill(tab: tab, height: 48) {
                        typing.start(over: tab)
                    } leading: {
                        BrowserMenu(browser: browser, tab: tab, sheet: $sheet) {
                            Label("Page Menu", systemImage: "text.page")
                                .labelStyle(.iconOnly)
                                .font(.body.weight(.medium))
                                .frame(width: 32, height: 48)
                                .contentShape(Rectangle())
                        }
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("address", in: glass)
                    tabsButton(tab)
                        .glassEffectID("tabs", in: glass)
                }
            }
        }
        .padding(.horizontal, tucked && !typing.editing ? 0 : 20)
        .padding(.top, 6)
        // The shrunk name sits lower, in the room above the home indicator,
        // leaving the page as much of the screen as it can.
        .padding(.bottom, tucked && !typing.editing ? -12 : 0)
        .tint(.primary)
        // The whole bar at once: forward coming or going reshapes back's
        // glass and the field beside it together, never one after the other.
        .animation(Self.motion, value: tucked)
        .animation(Self.motion, value: typing.editing)
        .animation(Self.motion, value: tab?.canGoForward ?? false)
        .animation(Self.motion, value: tab?.url == nil)
        // A private tab's controls are dark, whatever the phone's appearance,
        // so which kind of tab is in front shows at a glance, as in Safari.
        .environment(\.colorScheme, dark ? .dark : colorScheme)
    }

    /// The tabs: a tap shows them all; holding it opens or closes one.
    private func tabsButton(_ tab: Tab?) -> some View {
        Menu {
            Button("New Tab", systemImage: "plus.square.on.square") { browser.newTab() }
            Button("New Private Tab", systemImage: "eye.slash") { browser.newTab(private: true) }
            if let tab {
                Divider()
                Button("Close Tab", systemImage: "xmark", role: .destructive) { browser.close(tab) }
            }
        } label: {
            Label("Tabs", systemImage: "square.on.square")
                .labelStyle(.iconOnly)
                .font(.title3.weight(.medium))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        } primaryAction: {
            showingPrivate = tab?.isPrivate ?? false
            showingTabs = true
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityIdentifier("tabs")
        .accessibilityLabel("Tabs")
    }

    /// The controls shrunk while reading: the site's name alone, a tap
    /// bringing the rest back.
    private func tuckedPill(_ tab: Tab?) -> some View {
        let label = Address.label(for: tab)
        return Button { tuck.untuck() } label: {
            HStack(spacing: 4) {
                if tab?.isPrivate ?? false { Image(systemName: "eye.slash") }
                Text(label).lineLimit(1).truncationMode(.middle)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 18)
            .frame(height: 32)
            .overlay(alignment: .bottom) { LoadProgress(tab: tab) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("address", in: glass)
        .accessibilityIdentifier("address-tucked")
        .accessibilityLabel(label)
        .accessibilityHint("Shows the toolbar")
    }

    /// Typing: the field over the keyboard, grown from the one at rest.
    private var editorRow: some View {
        HStack(spacing: 10) {
            AddressEditor(text: $typing.text, selection: $typing.selection, focus: $focused, height: 48) {
                typing.submit(in: browser)
            }
            .glassEffect(.regular, in: .capsule)
            .glassEffectID("address", in: glass)
            Button { typing.cancel() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .glassEffectID("tabs", in: glass)
            .accessibilityLabel("Cancel")
            .accessibilityIdentifier("cancel")
        }
    }

    /// What the typing could mean, filling the screen above the field.
    private var suggestions: some View {
        ScrollView {
            SuggestionList(offers: typing.offers(in: browser)) { typing.pick($0, in: browser) }
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        // Under the field and the keyboard too, so no strip of the page
        // shows between them.
        .background(Color(.systemBackground).ignoresSafeArea())
        .transition(.opacity)
    }
}

/// Whether the iPhone's controls are shrunk while the page is read, as its
/// scrolling says (PageView): on down it, shrunk; back up, in full.
@MainActor @Observable
final class BarTuck {
    private(set) var tucked = false
    /// Typing, or picking things to hide: the controls stay in full.
    var held = false

    func scrolled(_ move: PageScroll) {
        let shrink = move == .down && !held
        if shrink != tucked { tucked = shrink }
    }

    func untuck() {
        if tucked { tucked = false }
    }
}

/// Back, and forward beside it once there is somewhere to go: one piece of
/// glass that stretches to hold both, as Safari's does. Holding either
/// lists the pages that way.
private struct NavigationButtons: View {
    let tab: Tab?

    var body: some View {
        let forward = tab?.canGoForward ?? false
        HStack(spacing: 0) {
            step("Back", systemImage: "chevron.backward", pages: tab?.backList ?? []) { tab?.goBack() }
                .disabled(!(tab?.canGoBack ?? false))
                .accessibilityIdentifier("back")
            if forward {
                step("Forward", systemImage: "chevron.forward", pages: tab?.forwardList ?? []) { tab?.goForward() }
                    .accessibilityIdentifier("forward")
                    .transition(.blurReplace)
            }
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func step(_ title: String, systemImage: String, pages: [WKBackForwardListItem],
                      action: @escaping () -> Void) -> some View {
        Menu {
            ForEach(pages, id: \.self) { page in
                Button(page.title?.isEmpty == false ? page.title ?? "" : Address.pretty(page.url)) {
                    tab?.go(to: page)
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.medium))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        } primaryAction: {
            action()
        }
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
