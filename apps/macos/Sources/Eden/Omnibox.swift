import EdenCore
import SwiftUI
import AppKit

/// What is typed in a window's field and what answers it (`Browser.typing`):
/// the field and its list watch it, and nothing else has to.
@MainActor
final class FieldState: ObservableObject {
    @Published var typed = ""
    @Published var offers: [Suggestion] = []
    @Published var ending: String?
    @Published var picked: Int?
    @Published var siteOffer: SearchSite?
}

/// One field and the few places it thinks you mean, in one panel laid out
/// as Zen's floating bar is (measured from Zen 1.24, 20 Nov 2026): the
/// field in a band across the top, a hairline under it, and the list below
/// in the same panel. Eden's own colours, corners and type. It takes
/// addresses and only addresses: type something that isn't a place and it
/// shivers and says so, rather than quietly handing your keystrokes to a
/// search engine.
struct Omnibox: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var typing: FieldState
    /// Raised over a page by ⌘T, ⌘L or ⌘K, rather than standing on an
    /// empty tab.
    let over: Bool

    @State private var shake: CGFloat = 0
    @State private var refused = false
    @Environment(\.colorScheme) private var scheme

    /// Sized to a pane of a split rather than to the window.
    var fitted = false
    /// The page whose pane this field stands on, with Split View on.
    var tab: Tab.ID?

    init(browser: Browser, over: Bool, fitted: Bool = false, tab: Tab.ID? = nil) {
        self.browser = browser
        self.typing = browser.typing
        self.over = over
        self.fitted = fitted
        self.tab = tab
    }

    /// Where the panel stands and how wide it is, after Zen's, for the space
    /// it stands in: two thirds of it up to 750 points, never narrower than
    /// 90% of it up to 682, and never closer than 14 to its edges. Its top
    /// is where a panel 333 points high would be centred, so a list that
    /// grows only ever grows downwards, and the field never moves from
    /// under what is being typed.
    enum Layout {
        /// The band the field stands in.
        static let header: CGFloat = 62
        /// The height the panel's top is centred as if it were.
        static let reference: CGFloat = 333

        static func width(in space: CGFloat) -> CGFloat {
            let zen = max(min(space * 0.9, 682), min(space / 1.5, 750))
            return min(zen, max(0, space - 28))
        }

        static func top(in height: CGFloat) -> CGFloat {
            max(16, (height - reference) / 2)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let top = Layout.top(in: geometry.size.height)
            // The list's room: down to 16 points from the bottom, under the
            // field and its hairline.
            content(width: Layout.width(in: geometry.size.width), top: top,
                    room: geometry.size.height - top - Layout.header - 1 - 16)
        }
        .allowsHitTesting(browser.fieldShowing)
    }

    private func content(width: CGFloat, top: CGFloat, room: CGFloat) -> some View {
        ZStack(alignment: .top) {
            if browser.fieldShowing {
                if over {
                    // The page stays as it is, as under Zen's bar: nothing
                    // dims it. A click on it puts the field away.
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea(.all, edges: fitted ? [] : .all)
                        .onTapGesture { browser.dismiss() }
                }
                panel(room: room)
                    .frame(width: width)
                    .padding(.top, top)
                    // There at once and gone at once, as Zen's is: a fade
                    // too short to wait for, whatever the window's own
                    // animation for the field is.
                    .transition(.opacity.animation(Motion.reduced ? nil : .easeOut(duration: 0.08)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var listing: Bool {
        !browser.offers.isEmpty || browser.siteOffer != nil || browser.switcherNote != nil
    }

    private func panel(room: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            if listing {
                Rectangle()
                    .fill(Palette.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                FittedRows(room: room, picked: pickedID, asked: browser.typed) { list }
            }
        }
        .background {
            // The shadow is the background's, not the panel's: drawn again
            // only when the panel changes size, not with every keystroke.
            // Broad and low, as Zen's is, and no scrim: it is what lifts
            // the panel off the page.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.ground)
                .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.22), radius: 50, y: 24)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(refused ? Color.red.opacity(0.35) : Palette.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .modifier(Shake(travel: shake))
        .animation(Motion.settle, value: refused)
        .onAppear {
            shake = 0
            refused = false
        }
        .onChange(of: browser.refusals) { _, _ in
            shake = 0
            refused = true
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        .onChange(of: browser.typed) { _, _ in
            withAnimation(Motion.quick) { refused = false }
        }
    }

    /// The field, after a glass in the column the rows' icons stand in, so
    /// what is typed starts where the rows' words do.
    private var header: some View {
        HStack(spacing: Row.gap) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: Row.iconBox, height: Row.iconBox)
            HStack(spacing: 8) {
                if let site = browser.siteChip {
                    SiteChip(site: site)
                        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                }
                AddressField(browser: browser, tab: tab)
                    .frame(height: 22)
            }
            .animation(Motion.quick, value: browser.siteChip)
        }
        .padding(.leading, Row.listInset + Row.inset)
        .padding(.trailing, 22)
        .frame(height: Layout.header)
    }

    /// The row the arrow keys are on, for the list to keep in sight.
    private var pickedID: String? {
        browser.picked.flatMap { browser.offers.indices.contains($0) ? browser.offers[$0].id : nil }
    }

    /// What it thinks you mean, in the panel under the field. Places you
    /// have been come with their titles; the handful of well-known addresses
    /// it starts life knowing come without the weight of one. Rows come and
    /// go at once, as Zen's do: the panel grows down to hold them.
    private var list: some View {
        VStack(spacing: Row.pitch) {
            if let site = browser.siteOffer {
                SiteOfferRow(site: site)
                    .contentShape(Rectangle())
                    .onTapGesture { _ = browser.lockSiteOffer() }
            }
            ForEach(Array(browser.offers.enumerated()), id: \.element.id) { index, offer in
                Row(offer: offer, picked: browser.picked == index, wide: true)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.take(offer) }
            }
            if let note = browser.switcherNote {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Row.inset + Row.iconBox + Row.gap)
                    .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, Row.listInset)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    /// One row of a list of places: in the panel, in the tab's own list
    /// and over another app. Zen's: the site's icon in a column of its own,
    /// what the place is called and, after a dash, where it is; an open tab
    /// offers itself with Switch to Tab.
    struct Row: View {
        /// Zen's measures for a row: the air before the icon, the box it
        /// stands in, the gap after it, its least height, and the space
        /// between rows. `listInset` is the list's own, from the panel's edge.
        static let inset: CGFloat = 8
        static let iconBox: CGFloat = 24
        static let gap: CGFloat = 12
        static let height: CGFloat = 45
        static let pitch: CGFloat = 4
        static let listInset: CGFloat = 11

        let offer: Suggestion
        /// Where the arrow keys have walked to. The pointer gets its own,
        /// quieter mark, and changes nothing but the look of the row.
        let picked: Bool
        /// In a panel wide enough to say Switch to Tab in words. A narrow
        /// list keeps an open tab's address instead, and the arrow alone.
        var wide = false

        @State private var hovering = false

        var body: some View {
            HStack(spacing: Self.gap) {
                icon
                    .frame(width: 16, height: 16)
                    .frame(width: Self.iconBox, height: Self.iconBox)
                words
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, Self.inset)
            .frame(minHeight: Self.height)
            .background {
                if picked {
                    RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                        .fill(Palette.wash)
                } else if hovering {
                    RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                        .fill(Palette.hover)
                }
            }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }

        /// Every row has the same column before its words, so the words line
        /// up whatever stands in it.
        @ViewBuilder
        private var icon: some View {
            switch offer.kind {
            case .search, .suggested:
                // The icon of where the words go, when this Mac already
                // has it: what you typed and what the engine suggests are
                // both searches sent there, and wear the same mark. Nothing
                // is fetched for one that isn't known; the glass is what
                // every search row wears until then.
                if let icon = Favicons.shared.cached(for: offer.url) {
                    Mark(icon: icon, letter: "", size: 16)
                } else {
                    symbol("magnifyingglass")
                }
            case .command:
                symbol("command")
            case .searched:
                // Words you searched this site for before: yours, not the
                // site's, so a mark of their own.
                symbol("clock.arrow.circlepath")
            case .elsewhere:
                // Open on another of your devices: that device.
                symbol(offer.elsewhere?.kind.symbol ?? "laptopcomputer")
            default:
                // A place — open, kept or visited — wears its site's icon,
                // as it does in History and the bookmarks bar: from what
                // this Mac already keeps, nothing fetched while typing, and
                // the site's letter until a visit brings one.
                Mark(icon: Favicons.shared.cached(for: offer.url), letter: letter, size: 16)
            }
        }

        /// What it is called, and after a dash where it is, as Zen writes
        /// it: "Wikipedia — wikipedia.org", "otters — Search with Kagi".
        private var words: some View {
            let (name, place) = parts
            return HStack(spacing: 0) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let place {
                    Text("—")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted.opacity(0.6))
                        .padding(.horizontal, 5)
                    Text(place)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }

        /// The row's name and, when it has one, where it is. An address
        /// reads without its www, as 1.0.4's did; the key itself keeps it,
        /// for completing and going there.
        private var parts: (String, String?) {
            switch offer.kind {
            case .open:
                // An open tab's key is its title, and its title its
                // address: Switch to Tab says the rest where there is room.
                return (offer.key, wide || offer.title.isEmpty ? nil : offer.title)
            case .search, .suggested, .searched, .command:
                // A search's title says where it goes ("Search with Kagi",
                // or ⌘K's "Search in a new tab"); a past one, which site.
                return (offer.key, offer.title.isEmpty ? nil : offer.title)
            default:
                let address = Address.withoutWWW(offer.key)
                return offer.title.isEmpty || offer.title == address ? (address, nil) : (offer.title, address)
            }
        }

        @ViewBuilder
        private var trailing: some View {
            // A command's key, as Arc's Command Bar shows it.
            if let command = offer.command, let key = command.key {
                Text(key)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            if let elsewhere = offer.elsewhere {
                Text("On \(elsewhere.deviceName)")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            if offer.kind == .bookmark {
                // Kept by you, not only visited: the bookmark's mark, at
                // the end now that the site's icon leads the row.
                symbol("bookmark")
            }
            if offer.kind == .open, offer.tab != nil {
                // Zen's: the words, quiet until the row is picked, and an
                // arrow cut out of a small square.
                HStack(spacing: 6) {
                    if wide {
                        Text("Switch to Tab")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(picked ? Palette.ink : Palette.muted)
                    }
                    Image(systemName: "arrow.right.square.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(picked ? Palette.ink.opacity(0.75) : Palette.muted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Switch to Tab")
            }
        }

        private func symbol(_ name: String) -> some View {
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
        }

        /// The site's first letter, as History's lines wear it: an open
        /// tab's row leads with its title, so the address is asked instead.
        private var letter: String {
            let host = offer.url.host().map(Address.withoutWWW) ?? ""
            return host.first.map { String($0).uppercased() } ?? "•"
        }
    }
}

/// A list's rows at their own height while they fit in `room`, and
/// scrolled once they don't, the row the arrow keys are on (`picked`, a
/// row's id) kept in sight: a long list under a field low in a short window
/// ran off its bottom, its last rows still there to be picked and never
/// seen. Kept in sight when it is picked, and again when the room or the
/// rows change under it, as a window made shorter does. With nothing
/// picked — the arrows walked off it back to the field, or something new
/// asked (`asked`, what was typed) — it starts again at its top: the last
/// place it was scrolled to left the first rows out of sight.
struct FittedRows<Rows: View>: View {
    let room: CGFloat
    let picked: String?
    let asked: String
    @ViewBuilder let rows: Rows

    /// The rows' own height, measured as they are laid out.
    @State private var tall: CGFloat = 0

    private var limit: CGFloat { max(room, Omnibox.Row.height) }

    private struct Sight: Equatable {
        let picked: String?
        let asked: String
        let limit: CGFloat
        let tall: CGFloat
    }

    /// The top of the rows, to go back to.
    private static var top: String { "fitted-rows-top" }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top)
                    rows
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { tall = $0 }
            }
            .scrollDisabled(tall <= limit)
            .frame(height: min(tall, limit))
            .onChange(of: Sight(picked: picked, asked: asked, limit: limit, tall: tall)) { before, sight in
                guard sight.tall > sight.limit else { return }
                if let id = sight.picked {
                    scroller.scrollTo(id)
                } else if before.picked != nil || sight.asked != before.asked {
                    scroller.scrollTo(Self.top, anchor: .top)
                }
            }
        }
    }
}

/// A site's icon when this Mac has it, or a glass.
private struct SiteIcon: View {
    let site: SearchSite
    var size: CGFloat = 14
    var body: some View {
        let host = site.host.split(separator: "/").first.map(String.init) ?? site.host
        // By where its search goes first, as the rows below it are, so the
        // chip and its rows wear one mark: Wikipedia's icon is kept under
        // en.wikipedia.org, not the wikipedia.org the site is named by.
        if let icon = Favicons.shared.cached(for: site.url(for: "x"))
            ?? Favicons.shared.cached(host) ?? Favicons.shared.cached("www." + host) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: size * 0.72, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: size, height: size)
        }
    }
}

/// The site Tab put in the field: its icon and name, in the field's grey,
/// before what is typed.
private struct SiteChip: View {
    let site: SearchSite
    var body: some View {
        HStack(spacing: 6) {
            SiteIcon(site: site)
            Text(site.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Searching \(site.name)")
    }
}

/// "Search Reddit", first in the list, with the key that takes it.
private struct SiteOfferRow: View {
    let site: SearchSite
    @State private var hovering = false
    var body: some View {
        HStack(spacing: Omnibox.Row.gap) {
            SiteIcon(site: site, size: 16)
                .frame(width: Omnibox.Row.iconBox, height: Omnibox.Row.iconBox)
            Text("Search \(site.name)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("Tab")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        }
        .padding(.horizontal, Omnibox.Row.inset)
        .frame(minHeight: Omnibox.Row.height)
        .background {
            if hovering {
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(Palette.hover)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Search \(site.name), press Tab")
    }
}

/// The field itself, in AppKit.
///
/// SwiftUI's TextField can hold a string and nothing else, and the whole point
/// here is the part you didn't type: the rest of the address, already there and
/// selected, so carrying on typing replaces it and Return accepts it. That
/// needs a real text field and its delegate.
struct AddressField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    @ObservedObject private var typing: FieldState
    /// The pane's page, for a field standing on one (see Coordinator.focus).
    var tab: Tab.ID?

    init(browser: Browser, tab: Tab.ID? = nil) {
        self.browser = browser
        self.typing = browser.typing
        self.tab = tab
    }

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    /// The field each window made last: the one on show. SwiftUI can make a
    /// new one while the one before is still fading out, in the window and
    /// still told of every request for the keys (from the second ⌘T on a
    /// page, since #718). That one answered after the new one, took the keys
    /// back, and left the window with them: nothing had them.
    private static let shown = NSMapTable<Browser, Field>.weakToWeakObjects()

    func makeNSView(context: Context) -> Field {
        let field = Field()
        Self.shown.setObject(field, forKey: browser)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15.5)
        field.textColor = Palette.NS.ink
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        // Scrolls with the caret, so a long address can be read and edited
        // all the way along rather than cut off at the field's edge.
        field.cell?.isScrollable = true
        // SwiftUI picks its own colour for a placeholder, and on a pale ground
        // that colour was near-white.
        let words = Self.placeholderWords(for: browser)
        field.placeholderAttributedString = Self.placeholder(words)
        field.setAccessibilityLabel(Self.accessibilityName(for: browser))
        context.coordinator.placeheld = words
        return field
    }

    /// What the empty field asks for: with a site put in it with Tab, the
    /// words to search that site for; otherwise an address, and where it
    /// will open, since the field looks the same whichever key raised it.
    private static func placeholderWords(for browser: Browser) -> String {
        if let site = browser.siteChip { return "Search \(site.name)" }
        switch browser.fieldMode {
        case .blank: return "Enter a web address"
        case .newTab: return "New tab: enter a web address"
        case .thisTab: return "This tab: enter a web address"
        case .switcher: return "Switch to an open tab"
        }
    }

    /// The field's name for VoiceOver, which reads it beside what is typed,
    /// after the placeholder has gone.
    private static func accessibilityName(for browser: Browser) -> String {
        switch browser.fieldMode {
        case .blank: return "Address"
        case .newTab: return "Address, new tab"
        case .thisTab: return "Address, this tab"
        case .switcher: return "Switch to an open tab"
        }
    }

    private static func placeholder(_ words: String) -> NSAttributedString {
        NSAttributedString(
            string: words,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15.5),
                .foregroundColor: NSColor(Palette.ink.opacity(0.3)),
            ]
        )
    }

    func updateNSView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.tab = tab

        // Only when something other than typing changed it — ⌘L arriving with
        // an address, a walk through the list, a submit clearing it.
        //
        // Comparing against the field's own text instead would undo every
        // backspace: deleting leaves the field shorter than what the browser
        // still considers complete, and the next update would helpfully type
        // it back in. That is a field you cannot shorten, and it reads exactly
        // like one that has stopped responding.
        let want = browser.completed
        if want != coordinator.synced {
            coordinator.synced = want
            field.stringValue = want
            coordinator.select(from: browser.typed.count, in: field)
        }

        let words = Self.placeholderWords(for: browser)
        if coordinator.placeheld != words {
            coordinator.placeheld = words
            field.placeholderAttributedString = Self.placeholder(words)
            field.setAccessibilityLabel(Self.accessibilityName(for: browser))
            DispatchQueue.main.async { coordinator.showPlaceholder(in: field) }
        }

        if coordinator.answered != browser.focusRequest {
            coordinator.answered = browser.focusRequest
            DispatchQueue.main.async { coordinator.focus(field) }
        }
    }

    /// The field, told when it lands in a window.
    ///
    /// SwiftUI makes the view and updates it before it is in one, and with
    /// Split View on it comes only once the stage has said where the page is,
    /// a turn of the run loop later. Asked for the keys before then, the
    /// field had no window to ask: the request went nowhere and nothing asked
    /// again, so ⌘T left a field with no caret and typing that went nowhere
    /// until it was clicked. Now the request waits for the window.
    final class Field: NSTextField {
        var arrived: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let arrived else { return }
            self.arrived = nil
            arrived()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var tab: Tab.ID?
        var answered = -1
        /// The placeholder last given, so it is set again only when a site
        /// goes in or comes out, or another key raises the field.
        var placeheld: String?
        /// The last value pushed in from the browser side, so an update can
        /// tell a change worth applying from one it made itself.
        var synced = ""

        /// A backspace has to be allowed to actually take a letter off. Without
        /// this the field puts the same letter straight back as a completion
        /// and the address can never be shortened.
        private var deleting = false

        init(browser: Browser) {
            self.browser = browser
        }

        /// The keys to the field, now if it is in a window, or the moment it is.
        @MainActor func focus(_ field: Field) {
            // Only the field of the page in front. With Split View on, ⌘T's
            // request reaches the field over the page just left too, in the
            // moment before it goes: answered there, the keys went with it
            // and were left to the window, which beeps at every key.
            guard tab == nil || tab == browser.activeID else { return }
            // One on its way out has no keys to take.
            guard AddressField.shown.object(forKey: browser) === field else { return }
            guard let window = field.window else {
                field.arrived = { [weak self, weak field] in
                    DispatchQueue.main.async {
                        guard let self, let field, self.browser.fieldShowing else { return }
                        self.focus(field)
                    }
                }
                return
            }
            field.arrived = nil
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            defer { browser.fieldFocused(in: window) }
            // The system paints selected text as a block of accent colour,
            // which over this pale field is the loudest thing in the
            // window. A tenth of the ink says "selected" quietly enough.
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            // A draft come back to its blank tab is carried on, not typed
            // over: the caret after it. An address ⌘L raises is selected whole.
            if browser.active?.isBlank == true, !browser.typed.isEmpty {
                select(from: browser.typed.count, in: field)
            } else {
                editor.selectAll(nil)
            }
        }

        /// A field being typed in shows the placeholder its editor was given
        /// when the typing began, and AppKit has no way to hand that editor
        /// a new one: the field begins editing again, with the caret and
        /// whatever was selected put back where they were.
        @MainActor func showPlaceholder(in field: Field) {
            guard let window = field.window, let editor = field.currentEditor() as? NSTextView,
                  window.firstResponder === editor else { return }
            let selected = editor.selectedRange()
            window.makeFirstResponder(field)
            guard let again = field.currentEditor() as? NSTextView else { return }
            again.selectedTextAttributes = editor.selectedTextAttributes
            let length = (again.string as NSString).length
            let start = min(selected.location, length)
            again.selectedRange = NSRange(location: start, length: min(selected.length, length - start))
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let text = field.stringValue

            browser.typed = text
            guard !deleting, let ending = browser.ending else {
                if deleting { browser.stopCompleting() }
                deleting = false
                synced = browser.completed
                return
            }
            deleting = false

            field.stringValue = text + ending
            synced = field.stringValue
            select(from: text.count, in: field)
        }

        /// The part after the caret, shown as selected, so the next keystroke
        /// replaces it and Return takes it.
        func select(from start: Int, in field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            let length = field.stringValue.count
            guard start <= length else { return }
            editor.selectedRange = NSRange(location: start, length: length - start)
            // The start in view, not the end: selecting a long completion
            // scrolled the field to its last characters, hiding what was
            // typed and the site it goes to (#1055). The ending stays
            // selected, so the next key still replaces it.
            editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                browser.submit()
                return true
            case #selector(NSResponder.moveDown(_:)):
                browser.walk(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                browser.walk(-1)
                return true
            case #selector(NSResponder.deleteWordBackward(_:)):
                // ⌥⌫ over an offered ending lets go of it and takes the last
                // word typed, as it does with no ending there. Left to the
                // text view it would only take the selected ending.
                deleting = true
                let selected = textView.selectedRange()
                guard browser.ending != nil, selected.length > 0,
                      NSMaxRange(selected) == (textView.string as NSString).length
                else { return false }
                textView.delete(nil)
                deleting = true
                textView.deleteWordBackward(nil)
                return true
            case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty && browser.siteChip != nil:
                // ⌫ on an empty field takes the site out of it.
                browser.siteChip = nil
                return true
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)),
                 #selector(NSResponder.deleteWordForward(_:)):
                deleting = true
                return false
            default:
                return false
            }
        }
    }
}
