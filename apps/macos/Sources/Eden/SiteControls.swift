import EdenCore
import AppKit
import SecurityInterface
import SwiftUI
import WebKit

// The site's controls: what the button at the end of the column's address
// bar opens (AddressBar), hanging from it. A row of square buttons for what
// is done to the page (share it, hide parts of it, capture it, say what it
// may use), the extensions as tiles, the site's own settings as lines that
// flip with a click, and at the foot how private the connection is and a
// menu for the rest. It goes as soon as one of them has done its thing, or
// with a click anywhere else.

/// The site as a person says it: the host without its www. A page with no
/// host — a file, about:blank — is named by what it is.
enum SiteName {
    static func of(_ url: URL) -> String {
        if let host = url.host(), !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if url.isFileURL { return "File" }
        return url.scheme ?? url.absoluteString
    }
}

/// The controls' measures: four tiles to a line, a little air round them,
/// and the column's own corners.
enum SiteControlsMetrics {
    static let pad: CGFloat = 12
    static let gap: CGFloat = 8
    static let tile: CGFloat = 48
    static let tileHeight: CGFloat = 32
    static let width: CGFloat = 4 * tile + 3 * gap + 2 * pad
    /// A setting's line, and the round mark it starts with.
    static let line: CGFloat = 40
    static let mark: CGFloat = 30
    static let heading = Font.system(size: 12.5, weight: .semibold)
    static let title = Font.system(size: 12.5, weight: .medium)
    static let state = Font.system(size: 11)
}

struct SiteControls: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// The tab in front, if any: with none, or one that holds no website,
    /// the controls keep the extensions and what isn't about a page, and
    /// the rest stands greyed.
    let tab: Tab?
    let close: () -> Void

    enum Page { case front, permissions, connection }

    @State private var page: Page
    /// Whether this Mac trusts the site's certificate. Unknown until it has
    /// been asked, off the main thread: asking can go to the network.
    @State private var certified: Bool?
    /// Moved on as a permission is changed, which is kept in the settings
    /// rather than anywhere SwiftUI watches.
    @State private var changed = 0
    /// The page's height as last laid out, which the controls follow
    /// (Height); none yet before the first.
    @State private var height: CGFloat = 0
    /// The “…” button has the keys, and VoiceOver, to have them back as
    /// its menu folds.
    @FocusState private var moreFocused: Bool
    @AccessibilityFocusState private var moreSpoken: Bool
    /// The glass the “…” button and its menu share, for the one to become
    /// the other.
    @Namespace private var glass
    @ObservedObject private var notifications = SiteNotifications.shared
    private let share = ViewBox()

    init(browser: Browser, tab: Tab?, page: Page = .front, close: @escaping () -> Void) {
        self.browser = browser
        self.prefs = browser.prefs
        self.tab = tab
        self.close = close
        _page = State(initialValue: page)
    }

    private typealias M = SiteControlsMetrics

    var body: some View {
        // A page further in comes in from the right over the one before,
        // which goes a little way left as it fades; back, the other way.
        // The controls grow or shrink to the new page on the same spring
        // (Height), so the popover moves with its pages rather than
        // snapping to the new one's size.
        Watching(tab: tab) { stage }
    }

    /// The page on show, and the one on its way in or out.
    private var stage: some View {
        ZStack(alignment: .topLeading) {
            shown(page)
                .padding(M.pad)
                .frame(width: M.width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { tall in
                    withAnimation(height == 0 ? nil : Motion.settle) { height = tall }
                }
                .background(Palette.ground.opacity(page == .front ? 0 : 1))
                .id(page)
                .transition(page == .front ? Self.behind : Self.ahead)
                .zIndex(page == .front ? 0 : 1)
        }
        .modifier(Height(height: height))
        .frame(width: M.width, alignment: .topLeading)
        .clipped()
        // Asked as the controls open, and again for each certificate the
        // tab's page comes with after that: another page, or the same one
        // loaded again.
        .onChange(of: trust.map(ObjectIdentifier.init), initial: true) { _, _ in certify() }
    }

    /// The page you were on as another comes over it, and as it comes back.
    private static let behind = AnyTransition.offset(x: -M.width / 3).combined(with: .opacity)
    /// A page further in, from the right edge, over the one before.
    private static let ahead = AnyTransition.move(edge: .trailing).combined(with: .opacity)

    @ViewBuilder private func shown(_ page: Page) -> some View {
        switch page {
        case .front: front
        case .permissions: permissions
        case .connection: connection
        }
    }

    /// To another page, on the spring things arriving and leaving use.
    private func go(_ to: Page) {
        withAnimation(Motion.settle) { page = to }
    }

    // MARK: - the front

    private var more: MoreActions { MoreActions(browser: browser, tab: tab, close: close) }

    /// From macOS 26 the “…” button is glass, and its menu the same glass
    /// grown out of it, over the controls (MoreMenu): the system's own way
    /// for a menu to come from its button. A click anywhere else in the
    /// controls folds it back. A page too short for the menu grows to hold
    /// it on the same spring, its foot going down with it.
    @ViewBuilder private var front: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer {
                lines
                    .frame(minHeight: browser.siteMenuOpen ? MoreMenu.height(more.groups) : nil, alignment: .top)
                    // Out of reach under the menu, to the keys and VoiceOver
                    // as to the pointer: the menu is all there is while open.
                    .disabled(browser.siteMenuOpen)
                    .accessibilityHidden(browser.siteMenuOpen)
                    .overlay {
                        if browser.siteMenuOpen {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { withAnimation(Motion.settle) { browser.siteMenuOpen = false } }
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if browser.siteMenuOpen { MoreMenu(actions: more, open: $browser.siteMenuOpen, glass: glass) }
                    }
            }
            // Folded, the keys go back to the button the menu came from.
            .onChange(of: browser.siteMenuOpen) { _, open in
                guard !open else { return }
                moreFocused = true
                moreSpoken = true
            }
        } else {
            lines
        }
    }

    /// The front's sections, down to its foot.
    private var lines: some View {
        VStack(alignment: .leading, spacing: 0) {
            actions
            if ExtensionTiles.shown {
                Heading("Extensions")
                ExtensionTiles(browser: browser, close: close)
            }
            if let tab {
                let settings = SiteSettings(browser: browser, prefs: prefs, tab: tab)
                if settings.any {
                    Heading("Settings")
                    VStack(spacing: 0) { settings }
                        .padding(.horizontal, -6)
                }
            }
            Spacer(minLength: 0)
            foot
        }
    }

    /// The four squares: share the page, hide parts of it, capture it, and
    /// what it may use. Capture only once it is on (Settings › Browsing ›
    /// Pages), the others then sharing its room.
    private var actions: some View {
        HStack(spacing: M.gap) {
            SiteTile(help: "Share", enabled: web, act: {
                guard let url = tab?.address, let view = share.view else { return }
                NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            }) {
                symbol("square.and.arrow.up")
            }
            .background(ViewGrab(box: share))
            SiteTile(help: "Hide Elements", enabled: web, act: { after { browser.toggleHiding() } }) {
                symbol("eye.slash")
            }
            if prefs.capturesPages {
                SiteTile(help: "Capture", enabled: web, act: { after { browser.toggleSnap() } }) {
                    symbol("camera")
                }
            }
            SiteTile(help: "Site Permissions", enabled: origin != nil, act: { go(.permissions) }) {
                symbol("hand.raised")
            }
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(Palette.ink)
    }

    /// Whether a website is in front, for what acts on one.
    private var web: Bool { tab?.isWeb == true }

    /// How private the connection is, which goes a step further in, and
    /// the menu for the rest.
    private var foot: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
                .padding(.vertical, M.gap)
            HStack(spacing: M.gap) {
                if let safety {
                    FootButton(symbol: safety.symbol, title: safety.short, tint: safety.secure ? Palette.ink : Palette.unsafe) {
                        // A secure page's certificate is all there is to
                        // add: straight to it. Anything else says what is
                        // wrong first.
                        if safety.secure, certified != false, let trust = safety.trust {
                            after { SiteControls.show(trust, in: browser) }
                        } else {
                            go(.connection)
                        }
                    }
                    .help(safety.title)
                }
                Spacer(minLength: 0)
                More(actions: more, open: $browser.siteMenuOpen, glass: glass)
                    .focused($moreFocused)
                    .accessibilityFocused($moreSpoken)
            }
        }
    }

    // MARK: - one step in

    /// A page further in: its title, with the way back before it.
    private func inner<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { go(.front) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                    Text(title)
                        .font(M.heading)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back")
            .padding(.bottom, 6)
            content()
        }
    }

    private var origin: String? {
        guard let url = tab?.pageAddress, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host() else { return nil }
        return Browser.origin(scheme, host, url.port ?? 0)
    }

    /// What the site may use, each a line that offers the three answers.
    @ViewBuilder private var permissions: some View {
        inner(tab?.pageAddress.map(SiteName.of) ?? "Site Permissions") {
            if let origin {
                let _ = changed
                if tab?.shy == true {
                    Note("Permissions aren't saved in a private tab.")
                } else {
                    VStack(spacing: 0) {
                        ForEach([CaptureChoices.Kind.camera, .microphone, .location, .notifications]) { kind in
                            let choice = CaptureChoices.choice(kind, origin: origin)
                            SettingLine(symbol: Self.symbol(for: kind), title: kind.title, state: choice.title,
                                        on: choice == .allow) {
                                choose(kind, origin: origin)
                            }
                        }
                    }
                    .padding(.horizontal, -6)
                    if !prefs.siteNotifications {
                        Note("Notifications are off in Settings › Privacy.")
                    }
                    if [CaptureChoices.Kind.camera, .microphone, .location, .notifications]
                        .contains(where: { CaptureChoices.choice($0, origin: origin) == .different }) {
                        Note("Saved two ways for this site. Pick one to keep.")
                    }
                }
            }
        }
    }

    private static func symbol(for kind: CaptureChoices.Kind) -> String {
        switch kind {
        case .camera, .cameraAndMicrophone: return "camera"
        case .microphone: return "mic"
        case .location: return "location"
        case .notifications: return "bell"
        }
    }

    /// Ask, Allow or Refuse, as a menu under the pointer, the one there is
    /// ticked.
    private func choose(_ kind: CaptureChoices.Kind, origin: String) {
        let now = CaptureChoices.choice(kind, origin: origin)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let answers: [(String, Bool?, CaptureChoices.Choice)] = [("Ask", nil, .ask), ("Allow", true, .allow), ("Refuse", false, .refuse)]
        for (title, value, choice) in answers {
            let item = ActionItem(title: title) {
                browser.setSitePermission(value, kind: kind, origin: origin)
                changed += 1
            }
            item.state = now == choice ? .on : .off
            item.isEnabled = !(kind == .notifications && value == true && !prefs.siteNotifications)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The connection, said in full.
    @ViewBuilder private var connection: some View {
        inner(tab?.pageAddress.map(SiteName.of) ?? "Connection") {
            if let safety {
                Text(safety.title)
                    .font(M.title)
                    .foregroundStyle(Palette.ink)
                    .padding(.bottom, 4)
                Text(safety.detail)
                    .font(M.state)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let trust = safety.trust {
                    FootButton(symbol: "checkmark.seal", title: certified == false ? "Show Certificate (Not Valid)" : "Show Certificate",
                         tint: Palette.ink) {
                        after { SiteControls.show(trust, in: browser) }
                    }
                    .padding(.top, M.pad)
                }
            }
        }
    }

    // MARK: - the connection

    /// What there is to say about the connection, from a page's own address
    /// and what WebKit knows of how it came.
    private struct Safety {
        let symbol: String
        /// What the foot's button says.
        let short: String
        let title: String
        let detail: String
        let secure: Bool
        /// The certificate the page came with, for an https page.
        let trust: SecTrust?
    }

    /// Asked again as the tab changes (Watching): another page, or one that
    /// pulls in something over plain http, says so while the controls are
    /// open.
    private var safety: Safety? {
        switch tab?.pageAddress?.scheme {
        case "https":
            let trust = tab?.built?.serverTrust
            // Only a certificate this Mac refused and you let through anyway
            // (see Dialogs.trust) gets this far untrusted.
            if certified == false {
                return Safety(
                    symbol: "lock.open", short: "Not Secure", title: "Connection is not secure",
                    detail: "This site's certificate isn't trusted by this Mac. Someone could be reading what you send.",
                    secure: false, trust: trust
                )
            }
            if tab?.built?.hasOnlySecureContent == false {
                return Safety(
                    symbol: "lock.trianglebadge.exclamationmark", short: "Partly Secure", title: "Parts of this page are not secure",
                    detail: "The page came privately, but some of what it shows was fetched over plain http, where anyone on the network could read or change it.",
                    secure: false, trust: trust
                )
            }
            return Safety(
                symbol: "lock", short: "Secure", title: "Connection is secure",
                detail: "Your information (for example, passwords or credit card numbers) is private when it is sent to this site.",
                secure: true, trust: trust
            )
        case "http":
            return Safety(
                symbol: "lock.open", short: "Not Secure", title: "Connection is not secure",
                detail: "Don't enter passwords or credit card numbers here: anything sent to this site can be read on the way.",
                secure: false, trust: nil
            )
        default:
            return nil
        }
    }

    /// The certificate the page in front came with.
    private var trust: SecTrust? { tab?.built?.serverTrust }

    /// Asks whether this Mac trusts the certificate, the way it would for
    /// any app. Off the main thread: the answer can need a revocation check.
    /// An answer about a certificate the page no longer has, the tab having
    /// gone on meanwhile, is let go of.
    private func certify() {
        certified = nil
        guard let trust else { return }
        let tab = tab
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = SecTrustEvaluateWithError(trust, nil)
            DispatchQueue.main.async {
                guard tab?.built?.serverTrust === trust else { return }
                certified = ok
            }
        }
    }

    /// The system's own certificate sheet, over the window.
    private static func show(_ trust: SecTrust, in browser: Browser) {
        guard let window = browser.window ?? Links.window else { return }
        SFCertificatePanel.shared().beginSheet(
            for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: false
        )
    }

    /// The controls go first, then the thing is done: a sheet or a layer
    /// over the page coming up under a popover still on its way out lands
    /// behind it.
    private func after(_ act: @escaping () -> Void) {
        close()
        DispatchQueue.main.async(execute: act)
    }
}

/// Draws `content` again whenever the tab changes, the page it holds, how
/// it came or what it may do: the address bar and the site's controls hold
/// the tab in front, when there is one, without watching it themselves, as
/// there may be none.
struct Watching<Content: View>: View {
    let tab: Tab?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let tab {
            Watched(tab: tab, content: content)
        } else {
            content()
        }
    }

    private struct Watched: View {
        @ObservedObject var tab: Tab
        let content: () -> Content

        var body: some View { content() }
    }
}

/// The controls' height, moved through every step of its spring rather
/// than set at the end: the popover takes its size from what is laid out,
/// so a frame that only looked as if it grew left the popover snapping to
/// the new page's size. Nothing laid out yet (0), the page's own.
private struct Height: AnimatableModifier {
    var height: CGFloat
    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(height: height > 0 ? height : nil, alignment: .top)
    }
}

// MARK: - the settings

/// The site's own settings, each a line that flips with a click.
private struct SiteSettings: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab

    /// The page's address, when it is a website's.
    private var web: URL? {
        guard let url = tab.pageAddress, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// Whether the blocker works on this site (see Shield.pause). Only with
    /// the blocker on and nothing wrong with it, and not in a private tab,
    /// which remembers nothing.
    private var blocker: String? {
        guard !tab.shy, prefs.shielded, Shield.shared.trouble == nil, let web else { return nil }
        return browser.curtain.host(of: web)
    }

    /// Whether the site may play sound by itself (see Autoplay). Not in a
    /// private tab, nor with Settings › Videos wait for a click on, which
    /// lets no site.
    private var sound: String? {
        guard !tab.shy, !Store.settings.bool(forKey: Preferences.waitsKey) else { return nil }
        return web?.host()
    }

    /// Whether the site's videos float out on their own (see Grounded).
    /// Only on a site they would float from, with one of Settings ›
    /// General's Float the video switches on, and not in a private tab.
    private var floats: String? {
        guard !tab.shy, prefs.floatsOnLeave || prefs.floatsAway, let web, Players.knows(web) else { return nil }
        return web.host()
    }

    private var zoomed: Bool { abs(tab.zoom - 1) > 0.001 }
    private var awake: Bool { prefs.keepsSitesAwake && tab.awakeHost != nil }

    var any: Bool {
        blocker != nil || sound != nil || floats != nil || browser.canDusk(tab) || awake || web != nil
    }

    var body: some View {
        if let blocker {
            BlockerLine(host: blocker) { tab.reload() }.id("blocker \(blocker)")
        }
        if let sound {
            SoundLine(host: sound).id("sound \(sound)")
        }
        if let floats {
            FloatLine(host: floats).id("float \(floats)")
        }
        // Only while dark pages are on and doing something: not paused,
        // and the frame dark. It takes effect on the page at once.
        if browser.canDusk(tab) {
            SettingLine(symbol: "moon", title: "Darken This Site", state: tab.dusked ? "On" : "Off", on: tab.dusked,
                        help: ShortcutStore.shared.key(for: "view.dusk").map { "Darken This Site   \($0.display)" } ?? "") {
                browser.dusk(!tab.dusked, tab)
            }
        }
        if awake {
            let on = browser.keepsAwake(tab)
            SettingLine(symbol: "cup.and.saucer", title: "Keep This Site Awake", state: on ? "On" : "Off", on: on,
                        help: tab.shy ? "Only in this private tab, until it closes. Uses more memory."
                            : "Prevents sleep and automatic closure, even when memory is low. You can still close the tab.") {
                browser.keepAwake(!on, for: tab)
            }
        }
        // The page's size, remembered for the site (see Tab.rememberZoom):
        // its steps at the end of the line, and the line itself back to the
        // size every site starts at.
        if web != nil {
            SettingLine(symbol: "plus.magnifyingglass", title: "Zoom", state: "\(Int((tab.zoom * 100).rounded()))%",
                        on: zoomed, help: zoomed ? "Actual Size   ⌘0" : "") {
                browser.resetZoom()
            } accessory: {
                HStack(spacing: 2) {
                    ZoomStep(symbol: "minus", help: "Zoom Out   ⌘-") { browser.zoom(by: 1 / 1.1) }
                    ZoomStep(symbol: "plus", help: "Zoom In   ⌘+") { browser.zoom(by: 1.1) }
                }
            }
        }
    }
}

/// On is the blocker at work here. The page reloads, as the blocker is
/// decided for a page as it starts (#861).
private struct BlockerLine: View {
    let host: String
    let reload: () -> Void
    @State private var on: Bool

    init(host: String, reload: @escaping () -> Void) {
        self.host = host
        self.reload = reload
        _on = State(initialValue: !Shield.shared.isPaused(on: host))
    }

    var body: some View {
        SettingLine(symbol: on ? "shield.lefthalf.filled" : "shield.slash", title: "Block Ads and Trackers",
                    state: on ? "On" : "Off for this site", on: on,
                    help: "Turn off here if the site breaks; the page reloads") {
            on.toggle()
            Shield.shared.pause(host, !on)
            reload()
        }
    }
}

/// WebKit takes it as a page loads, so a page already open stays as it
/// came, and the line says so once flipped.
private struct SoundLine: View {
    let host: String
    private let was: Bool
    @State private var on: Bool

    init(host: String) {
        self.host = host
        was = Autoplay.allowed(host)
        _on = State(initialValue: was)
    }

    var body: some View {
        SettingLine(symbol: on ? "speaker.wave.2" : "speaker.slash", title: "Play Sound by Itself",
                    state: (on ? "Allowed" : "Blocked") + (on != was ? " from the next page" : ""), on: on) {
            on.toggle()
            Autoplay.set(on, for: host)
        }
    }
}

/// Asked each time a video would float, so it holds at once, for the page
/// already open too.
private struct FloatLine: View {
    let host: String
    @State private var on: Bool

    init(host: String) {
        self.host = host
        _on = State(initialValue: !Grounded.holds(host))
    }

    var body: some View {
        SettingLine(symbol: "pip", title: "Float Videos", state: on ? "Allowed" : "Blocked", on: on) {
            on.toggle()
            Grounded.set(!on, for: host)
        }
    }
}

// MARK: - the pieces

/// A setting as a line: a round mark, filled while it is on, its name, and
/// how it is set under it. A click flips it.
struct SettingLine<Accessory: View>: View {
    let symbol: String
    let title: String
    let state: String
    let on: Bool
    var help = ""
    let act: () -> Void
    /// What sits at the line's end, beside its click rather than in it:
    /// zoom's steps.
    @ViewBuilder var accessory: () -> Accessory

    @State private var hovering = false
    private typealias M = SiteControlsMetrics

    var body: some View {
        HStack(spacing: 0) {
            Button(action: act) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(on ? Palette.ground : Palette.muted)
                        .frame(width: M.mark, height: M.mark)
                        .background(Circle().fill(on ? Palette.ink : Palette.wash))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(M.title)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(state)
                            .font(M.state)
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: M.line)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(state)
            .accessibilityAddTraits(.isButton)
            accessory()
        }
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(hovering ? Palette.hover : .clear)
        )
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: on)
        .animation(Motion.quick, value: hovering)
    }
}

extension SettingLine where Accessory == EmptyView {
    init(symbol: String, title: String, state: String, on: Bool, help: String = "", act: @escaping () -> Void) {
        self.init(symbol: symbol, title: title, state: state, on: on, help: help, act: act) { EmptyView() }
    }
}

/// A step of the zoom, at the end of its line.
private struct ZoomStep: View {
    let symbol: String
    let help: String
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Palette.pinLive : Palette.wash)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .animation(Motion.quick, value: hovering)
    }
}

/// One square of the controls: an action on the page, or an extension.
struct SiteTile<Label: View>: View {
    let help: String
    /// Whether it can be done here. Greyed for that alone: put out of reach
    /// under the “…” menu, it stays as it looks.
    var enabled = true
    let act: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            label()
                .frame(maxWidth: .infinity)
                .frame(height: SiteControlsMetrics.tileHeight)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                        .fill(hovering && enabled ? Palette.pinLive : Palette.wash)
                )
                .contentShape(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .animation(Motion.quick, value: hovering)
    }
}

/// Tiles four to a line, as wide as the controls let them be.
struct Grid4<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SiteControlsMetrics.gap), count: 4),
                  spacing: SiteControlsMetrics.gap, content: content)
    }
}

/// A section's name, over its tiles or lines.
private struct Heading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(SiteControlsMetrics.heading)
            .foregroundStyle(Palette.ink)
            .padding(.top, 14)
            .padding(.bottom, 8)
    }
}

/// A line of small print under a page's lines.
private struct Note: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(SiteControlsMetrics.state)
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }
}

/// The foot's button: a symbol and a word, on the tiles' grey.
private struct FootButton: View {
    let symbol: String
    let title: String
    let tint: Color
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(SiteControlsMetrics.title)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(hovering ? Palette.pinLive : Palette.wash)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// The rest, behind “…”: this site's cookies or cache let go of, the page
/// printed or kept, and the way to the extensions.
@MainActor
private struct MoreActions {
    let browser: Browser
    let tab: Tab?
    let close: () -> Void

    /// One line of the menu: what it says, whether it can be done, and
    /// what it does.
    struct Line {
        let title: String
        var enabled = true
        let act: @MainActor () -> Void
    }

    /// The menu's lines, in the groups its separators part.
    var groups: [[Line]] {
        let web = tab?.isWeb == true
        var groups: [[Line]] = [
            [
                Line(title: "Clear Cookies", enabled: web) { if let tab { browser.clearSiteData(.cookies, of: tab) } },
                Line(title: "Clear Cache", enabled: web) { if let tab { browser.clearSiteData(.cache, of: tab) } },
            ],
            [
                Line(title: "Print…", enabled: web) { browser.printPage() },
                Line(title: "Save Page As…", enabled: web) { browser.savePage() },
                Line(title: "Export as PDF…", enabled: web) { browser.exportPDF() },
            ],
        ]
        if ExtensionTiles.supported {
            groups.append([
                Line(title: "Manage Extensions…") {
                    Store.settings.set("extensions", forKey: "settings.page")
                    browser.tuning = true
                },
                Line(title: "Add Extension…") { browser.open(Browser.webStore, foreground: true) },
            ])
        }
        return groups
    }

    /// The controls go first, then the line's thing is done: a print panel
    /// or a sheet coming up under a popover on its way out lands behind it.
    func run(_ line: Line) {
        close()
        let act = line.act
        DispatchQueue.main.async { act() }
    }
}

/// The “…” button. From macOS 26 a circle of glass, which becomes the menu
/// (MoreMenu) and the menu it again; before, the menu at the pointer.
private struct More: View {
    let actions: MoreActions
    @Binding var open: Bool
    let glass: Namespace.ID

    @State private var hovering = false

    /// The glass the button and the menu share.
    static let glassID = "more"

    var body: some View {
        if #available(macOS 26, *) {
            if open {
                // Its place kept, so the foot doesn't move under the menu.
                Color.clear.frame(width: 28, height: 28)
            } else {
                Button { withAnimation(Motion.settle) { open = true } } label: {
                    dots
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID(Self.glassID, in: glass)
                .help("More")
                .accessibilityLabel("More")
            }
        } else {
            Button(action: popUp) {
                dots
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(hovering ? Palette.pinLive : Palette.wash))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("More")
            .accessibilityLabel("More")
        }
    }

    private var dots: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.ink)
    }

    private func popUp() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (group, lines) in actions.groups.enumerated() {
            if group > 0 { menu.addItem(.separator()) }
            for line in lines {
                let item = ActionItem(title: line.title) { actions.run(line) }
                item.isEnabled = line.enabled
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// The menu behind “…”, grown out of its button's glass and folded back
/// into it: its corner on the button's, the panel's corners, and lines as
/// a menu's are. It has the keys while open, as a menu does: ↑ and ↓ walk
/// its lines, Return or Space takes one, and Escape folds it (ContentView).
@available(macOS 26, *)
private struct MoreMenu: View {
    let actions: MoreActions
    @Binding var open: Bool
    let glass: Namespace.ID

    /// The line the keys or the pointer are on, counted down the menu.
    @State private var lit: Int?
    @FocusState private var focused: Bool
    /// The line VoiceOver is on, which the arrow keys move with `lit`, so
    /// the line Return will take is the one said.
    @AccessibilityFocusState private var spoken: Int?

    static let line: CGFloat = 24
    static let separator: CGFloat = 11
    static let pad: CGFloat = 5
    static let corner: CGFloat = 14

    /// How tall the menu stands, for a page that has to grow to hold it.
    static func height(_ groups: [[MoreActions.Line]]) -> CGFloat {
        let lines = groups.reduce(0) { $0 + $1.count }
        return CGFloat(lines) * line + CGFloat(max(0, groups.count - 1)) * separator + 2 * pad
    }

    var body: some View {
        let groups = actions.groups
        let lines = groups.flatMap { $0 }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups.indices, id: \.self) { group in
                if group > 0 {
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(height: 1)
                        .padding(.horizontal, 7)
                        .frame(height: Self.separator)
                        .accessibilityHidden(true)
                }
                let start = groups[..<group].reduce(0) { $0 + $1.count }
                ForEach(groups[group].indices, id: \.self) { index in
                    let at = start + index
                    // The pointer lights a line for VoiceOver too, so
                    // the line Return takes is the one it says.
                    MenuLine(line: lines[at], lit: lit == at,
                             hover: { over in
                                 if over, lines[at].enabled { lit = at; spoken = at }
                                 // Gone with the pointer, as a menu's highlight
                                 // goes, unless VoiceOver is still saying it.
                                 else if !over, lit == at,
                                         !(NSWorkspace.shared.isVoiceOverEnabled && spoken == at) { lit = nil }
                             }) {
                        take(lines[at])
                    }
                    .accessibilityFocused($spoken, equals: at)
                    .accessibilityAddTraits(lit == at ? .isSelected : [])
                }
            }
        }
        .padding(Self.pad)
        .frame(width: 196)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .glassEffectID(More.glassID, in: glass)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        // VoiceOver moved on its own keys: the line it is on is the one
        // lit, for Return, Space and the next arrow to start from. On one
        // that can't be taken, or off the lines, none is: Return takes
        // nothing VoiceOver didn't name. Without VoiceOver running the
        // focus it keeps may come back empty, and the arrows' line stays.
        .onChange(of: spoken) { _, now in
            if let now, lines.indices.contains(now) {
                lit = lines[now].enabled ? now : nil
            } else if NSWorkspace.shared.isVoiceOverEnabled {
                lit = nil
            }
        }
        .onKeyPress(.downArrow) { walk(1, lines); return .handled }
        .onKeyPress(.upArrow) { walk(-1, lines); return .handled }
        .onKeyPress(.return) { takeLit(lines) }
        .onKeyPress(.space) { takeLit(lines) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("More")
        .accessibilityAddTraits(.isModal)
    }

    /// To the next line that can be taken that way, round from either end.
    private func walk(_ step: Int, _ lines: [MoreActions.Line]) {
        guard lines.contains(where: \.enabled) else { return }
        var at = lit ?? (step > 0 ? -1 : lines.count)
        repeat {
            at = (at + step + lines.count) % lines.count
        } while !lines[at].enabled
        lit = at
        spoken = at
    }

    private func takeLit(_ lines: [MoreActions.Line]) -> KeyPress.Result {
        guard let lit, lines.indices.contains(lit), lines[lit].enabled else { return .ignored }
        take(lines[lit])
        return .handled
    }

    private func take(_ line: MoreActions.Line) {
        open = false
        actions.run(line)
    }

    private struct MenuLine: View {
        let line: MoreActions.Line
        let lit: Bool
        let hover: (Bool) -> Void
        let act: () -> Void

        var body: some View {
            Button(action: act) {
                Text(line.title)
                    .font(.system(size: 13))
                    .foregroundStyle(line.enabled ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: MoreMenu.line)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(lit && line.enabled ? Palette.ink.opacity(0.08) : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!line.enabled)
            .focusable(false)
            .onHover(perform: hover)
        }
    }
}

/// A menu line that runs its own closure, its own target.
final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { run() }
}

/// Holds the view a SwiftUI button is drawn on, for what AppKit has to hang
/// from it: the share picker.
final class ViewBox {
    weak var view: NSView?
}

struct ViewGrab: NSViewRepresentable {
    let box: ViewBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

// MARK: - this site's data

extension Browser {
    enum SiteData {
        case cookies, cache

        var types: Set<String> {
            switch self {
            case .cookies: return [WKWebsiteDataTypeCookies]
            case .cache: return [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                 WKWebsiteDataTypeOfflineWebApplicationCache]
            }
        }

        var done: String {
            switch self {
            case .cookies: return "Cookies cleared"
            case .cache: return "Cache cleared"
            }
        }
    }

    /// This site's cookies or cache let go of, in the store its tab keeps
    /// them in, and the page loaded again without them. The site is its
    /// domain and every name under it, as the store keeps its records.
    func clearSiteData(_ kind: SiteData, of tab: Tab) {
        guard let url = tab.address, let host = url.host()?.lowercased() else { return }
        let store = tab.built?.configuration.websiteDataStore ?? Spaces.store(for: spaceID)
        let types = kind.types
        let name = SiteName.of(url)
        store.fetchDataRecords(ofTypes: types) { [weak self, weak tab] records in
            let mine = records.filter { record in
                let domain = record.displayName.lowercased()
                return host == domain || host.hasSuffix("." + domain)
            }
            store.removeData(ofTypes: types, for: mine) {
                MainActor.assumeIsolated {
                    tab?.reload()
                    self?.announce("\(kind.done) for \(name)", look: .done)
                }
            }
        }
    }
}
