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
    /// The page's zoom into its card in the tab overview, and out again.
    @State private var director = DeckDirector()
    /// The page being photographed for the overview to open from it.
    @State private var opening = false
    /// The bar is the tab overview's: +, the search, Done. It turns as the
    /// page zooms, both ways, not once the zoom is over, so the two move
    /// together, as Safari's do.
    @State private var barShowsTabs = false
    /// How wide the bar has to be laid out in.
    @State private var barWidth: CGFloat = 362
    /// What is typed in the overview's search, and whether it has the keyboard.
    @State private var tabQuery = ""
    @FocusState private var searchingTabs: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// How the controls change shape: the system's own spring, the glass
    /// flowing from one shape into the next.
    private static let motion = Animation.smooth(duration: 0.35)
    /// How the bar shrinks as the page is read and grows back: Safari's half
    /// second, with no bounce.
    private static let tuckMotion = Animation.spring(duration: 0.4, bounce: 0)
    /// What is inside a piece of the bar, giving way to what takes its place
    /// as the glass changes shape: gone quickly, the new come in just after,
    /// never the two at once, as in Safari.
    private static let swap = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.07)),
        removal: .opacity.animation(.easeIn(duration: 0.08)))
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
            // Nor while the tab overview has the bar away, nor while it is
            // shrunk as the page is read: the page keeps what the bar in full
            // covers, as Safari's does, and isn't laid out again each time it
            // shrinks and grows — which left a strip unpainted, and stalled
            // the bar as it went.
            if !typing.editing, !showingTabs, !tuck.tucked { covered = now }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { top = $0 }
        // The overview over the page, under the bar, which is the overview's
        // own while it shows.
        .overlay {
            if showingTabs {
                TabOverview(browser: browser, showingPrivate: $showingPrivate, director: director, query: tabQuery) {
                    leaveTabs(to: $0)
                }
                .transition(.opacity.combined(with: .scale(scale: 1.06)))
            }
        }
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
        // The tab overview: light over the private room's dark.
        if showingTabs { return showingPrivate ? .lightContent : .default }
        guard let tab, !typing.editing, sheet == nil else { return .default }
        // A private tab's start page is dark, whatever the phone's appearance.
        guard tab.url != nil else { return tab.isPrivate ? .lightContent : .default }
        guard let light = tab.isLight else { return .default }
        return light ? .darkContent : .lightContent
    }

    private func bar(_ tab: Tab?) -> some View {
        let overview = barShowsTabs
        let dark = overview ? showingPrivate : (tab?.isPrivate ?? false) && !typing.editing
        let shrunk = tucked && !typing.editing && !overview
        return GlassEffectContainer(spacing: 10) {
            if !overview, typing.editing {
                editorRow
            } else {
                slots(tab, overview: overview, shrunk: shrunk)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 40 } action: { barWidth = $0 }
        .padding(.top, 6)
        // The shrunk name sits lower, in the room above the home indicator,
        // leaving the page as much of the screen as it can.
        .padding(.bottom, shrunk ? -12 : 0)
        .tint(.primary)
        // Back, the field and the tabs flow into +, the search and Done, and
        // back again, each piece of glass into the one in its place.
        .animation(Self.motion, value: overview)
        // The whole bar at once: forward coming or going reshapes back's
        // glass and the field beside it together, never one after the other.
        .animation(Self.tuckMotion, value: tucked)
        .animation(Self.motion, value: typing.editing)
        .animation(Self.motion, value: tab?.canGoForward ?? false)
        .animation(Self.motion, value: tab?.url == nil)
        // A private tab's controls are dark, whatever the phone's appearance,
        // so which kind of tab is in front shows at a glance, as in Safari.
        .environment(\.colorScheme, dark ? .dark : colorScheme)
    }

    /// The bar's three pieces of glass, the same for the browser and the
    /// overview, so each flows from one to the other rather than being
    /// swapped: back (and forward) or a new tab; the address field or the
    /// search through the cards — Return searches the web; the tabs, or Done
    /// (Cancel while searching). The glass stays and takes its new width, as
    /// Safari's toolbar turns into its tabs' own; what is inside cross-fades.
    private func slots(_ tab: Tab?, overview: Bool, shrunk: Bool) -> some View {
        let forward = tab?.canGoForward ?? false
        // Shrunk as the page is read, as Safari's: back and the tabs give up
        // their room, smaller and fading, closing in on the field, which
        // narrows to the site's name and grows shorter. The same pieces,
        // every size between drawn as it goes, so nothing blurs or doubles.
        let side: CGFloat = 48
        let left: CGFloat = shrunk ? 0 : (overview || !forward ? side : 96)
        let right: CGFloat = shrunk ? 0 : (overview ? (searchingTabs ? 92 : 80) : side)
        let gap: CGFloat = shrunk ? 0 : 10
        let middle = shrunk ? compactWidth(tab) : max(60, barWidth - left - right - gap * 2)
        let tall: CGFloat = shrunk ? 32 : 48
        return HStack(spacing: gap) {
            ZStack {
                if overview {
                    Button {
                        browser.newTab(private: showingPrivate)
                        leaveTabs(to: nil)
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3.weight(.medium))
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showingPrivate ? "New Private Tab" : "New Tab")
                    .accessibilityIdentifier("new-tab")
                    .transition(Self.swap)
                } else {
                    NavigationButtons(tab: tab).transition(Self.swap)
                }
            }
            .frame(width: overview || !forward ? side : 96, height: side)
            // What is inside shrinks and fades in the glass, which narrows
            // to nothing round it: the glass draws apart from what it holds.
            .scaleEffect(shrunk ? 0.4 : 1)
            .opacity(shrunk ? 0 : 1)
            .frame(width: left, height: tall)
            .clipped()
            // Its glass gone with it, nothing left to run into the field's.
            .glassEffect(shrunk ? .identity : .regular.interactive(), in: .capsule)
            .glassEffectID("navigation", in: glass)

            ZStack {
                if overview {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(showingPrivate ? "Search private tabs" : "Search tabs", text: $tabQuery)
                            .focused($searchingTabs)
                            .submitLabel(.search)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(searchTheWeb)
                            .accessibilityIdentifier("tabs-search")
                        if !tabQuery.isEmpty {
                            Button("Clear", systemImage: "xmark.circle.fill") { tabQuery = "" }
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .transition(Self.swap)
                } else {
                    AddressPill(tab: tab, height: tall, compact: shrunk, leadingWidth: 32) {
                        if shrunk { tuck.untuck() } else { typing.start(over: tab) }
                    } leading: {
                        BrowserMenu(browser: browser, tab: tab, sheet: $sheet) {
                            Label("Page Menu", systemImage: "text.page")
                                .labelStyle(.iconOnly)
                                .font(.body.weight(.medium))
                                .frame(width: 32, height: 48)
                                .contentShape(Rectangle())
                        }
                    }
                    .transition(Self.swap)
                }
            }
            .frame(width: middle, height: tall)
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID("address", in: glass)

            ZStack {
                if overview {
                    Button {
                        if searchingTabs {
                            tabQuery = ""
                            searchingTabs = false
                        } else {
                            leaveTabs(to: nil)
                        }
                    } label: {
                        Text(searchingTabs ? "Cancel" : "Done")
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(searchingTabs ? "tabs-search-cancel" : "tabs-done")
                    .transition(Self.swap)
                } else {
                    tabsButton(tab).transition(Self.swap)
                }
            }
            .frame(width: overview ? (searchingTabs ? 92 : 80) : side, height: side)
            .scaleEffect(shrunk ? 0.4 : 1)
            .opacity(shrunk ? 0 : 1)
            .frame(width: right, height: tall)
            .clipped()
            .glassEffect(shrunk ? .identity : .regular.interactive(), in: .capsule)
            .glassEffectID("tabs", in: glass)
        }
        .animation(Self.motion, value: searchingTabs)
    }

    /// Return in the overview's search: what was typed, searched for or gone
    /// to, in a new tab of the room shown.
    private func searchTheWeb() {
        let typed = tabQuery.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        let tab = browser.newTab(private: showingPrivate)
        _ = browser.go(typed, in: tab)
        leaveTabs(to: nil)
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
            openTabs(tab)
        }
        .accessibilityIdentifier("tabs")
        .accessibilityLabel("Tabs")
    }

    // MARK: - the tab overview, zoomed into and out of

    /// The page in front shrinks into its card, in the deck, as the rest come
    /// in round it (CardDeck); with no page to show, the overview simply
    /// comes in.
    private func openTabs(_ tab: Tab?) {
        guard !showingTabs, !opening else { return }
        opening = true
        showingPrivate = tab?.isPrivate ?? false
        Task { @MainActor in
            defer { opening = false }
            director.chrome = false
            tabQuery = ""
            if let tab, let picture = await tab.capture() {
                director.entry = (tab.id, picture)
                showingTabs = true
            } else {
                director.entry = nil
                withAnimation(.smooth(duration: 0.32)) { showingTabs = true }
            }
            // The bar turns as the page shrinks.
            withAnimation(Self.motion) { barShowsTabs = true }
        }
    }

    /// A card picked, or Done: its card grows back to the page, over the
    /// rest as they go (CardDeck). One with no card in sight in the room
    /// shown — a pin, a page never seen — fades in instead.
    private func leaveTabs(to picked: Tab?) {
        if let picked { browser.select(picked) }
        // The bar turns back as the card grows, not once it has.
        searchingTabs = false
        tabQuery = ""
        withAnimation(Self.motion) { barShowsTabs = false }
        let room = showingPrivate ? browser.privateTabs : browser.looseTabs
        guard let target = browser.active, target.snapshot != nil, room.contains(where: { $0.id == target.id }),
              director.leave(to: target.id, done: { showingTabs = false })
        else {
            withAnimation(.smooth(duration: 0.3)) { showingTabs = false }
            return
        }
    }

    /// The field shrunk to the site's name: wide enough for the name at the
    /// size it shrinks to, and no wider than the bar.
    private func compactWidth(_ tab: Tab?) -> CGFloat {
        let name = Address.label(for: tab) as NSString
        let wide = name.size(withAttributes: [.font: UIFont.systemFont(ofSize: AddressPill<EmptyView>.compactSize)]).width
        let mark: CGFloat = (tab?.isPrivate ?? false) || tab?.url?.scheme == "http" ? 22 : 0
        return min(barWidth, (wide + mark).rounded(.up) + 24 + 8)
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
        .transition(Self.swap)
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
