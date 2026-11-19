import EdenCore
import Foundation
import Observation
import UIKit
import WebKit

/// One page: its web view, made the first time it is shown, and what the
/// browser's chrome reads from it. A private tab has a store of its own
/// that keeps nothing once the tab is gone, and leaves no history.
@Observable
final class Tab: NSObject, Identifiable {
    let id = UUID()
    /// Whose it is, for as long as it lives (Spaces.swift).
    let owner: TabOwner
    var isPrivate: Bool { owner == .private }
    /// The pin it is, if it is one (Pins.swift).
    var pin: UUID?
    /// A pin's tab made to stand at its home, never shown since: nothing of
    /// yours is in it, so a pin taken away elsewhere takes it too.
    @ObservationIgnored var restsAtHome = false
    /// How far down the page is read, nought to one, as your other devices
    /// are told (Syncing).
    @ObservationIgnored private(set) var readFraction: Double = 0
    /// The same in twentieths, watched: what a page handed off says, which
    /// changes only a few times down a page (EdenApp's HandoffOffer).
    private(set) var readStep: Double = 0
    /// A page carried on from another device: how it is to be shown once it
    /// has come in (Elsewhere).
    @ObservationIgnored var arrival: Arrival?

    /// How a page from another device was left there.
    struct Arrival: Equatable {
        /// The page it is for: another that comes in instead takes none of it.
        var page: URL
        var scroll: Double?
        var reading: Bool
        /// The device's name, to say where it came from.
        var from: String
    }

    /// Where the tab is, or is going: the page's address once it has one, and
    /// the address a restored tab will load when it is first shown.
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var progress = 0.0
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Set when the page never arrived, shown in place of the page.
    private(set) var failure: String?
    /// The page stripped back to its article (EdenCore's ReadingMode), until
    /// the next page or a reload.
    private(set) var isReading = false
    /// Whether the page is light, by the colour it shows behind itself, so
    /// the status bar over its top reads dark on it, as in Safari; nil until
    /// it has said.
    private(set) var isLight: Bool?
    /// The page as it last showed, small: its card in the tab overview.
    /// Kept on disk too for the next launch, never a private tab's
    /// (CardPictures).
    private(set) var snapshot: UIImage?

    /// Who the tab tells about pages it loads and windows it opens.
    @ObservationIgnored weak var browser: Browser?

    @ObservationIgnored private var configuration: WKWebViewConfiguration
    @ObservationIgnored private var built: WKWebView?
    /// What the page loads when it is first made: a restored tab's address,
    /// or one asked for before the page was. Never a pop-up's, whose page
    /// WebKit loads itself (Browser.adopt).
    @ObservationIgnored private var pending: URL?
    @ObservationIgnored private var watching: [NSKeyValueObservation] = []
    /// Counts the pages the tab has shown, so an answer about one that has
    /// gone is never applied to the next.
    @ObservationIgnored private var generation = 0
    /// Looking for the article now: asking again meanwhile is the same request.
    @ObservationIgnored private var seekingArticle = false

    /// Eden's own content world, where its scripts run apart from the page's.
    static let world = WKContentWorld.world(name: "Eden")
    /// A private tab's own changes to what is hidden (Hiding.swift); nil for
    /// an ordinary tab.
    let privateHiding: PrivateHiding?
    /// The page showing, once WebKit has committed to one with a site.
    private(set) var shown: ShownPage?
    /// Counts the pages committed to, for `shown`.
    @ObservationIgnored private var commits = 0

    /// A new tab. `configuration`: made with its space's store (Browser),
    /// or WebKit's own when a page opens a window (Browser.adopt), so the
    /// window keeps its opener; Personal's or a private one's when not given.
    /// `own`: the opener's own changes to what is hidden, which a private
    /// window shares.
    init(owner: TabOwner, configuration: WKWebViewConfiguration? = nil, sharing own: PrivateHiding? = nil) {
        self.owner = owner
        self.configuration = configuration ?? Tab.configuration(private: owner == .private)
        privateHiding = owner == .private ? own ?? PrivateHiding() : nil
        super.init()
    }

    /// Where ordinary tabs keep cookies, sign-ins and caches: WebKit's own
    /// store, or for a test run (EDEN_PROBE) one of its own, under the test
    /// world's fixed identifier as on the Mac (Store.probeStore), so a test
    /// never signs in as, or signs out, whoever browses on the same device.
    static let ordinaryStore: WKWebsiteDataStore = Store.testing
        ? WKWebsiteDataStore(forIdentifier: Store.probeStore(1))
        : .default()

    /// What every page is made with: Eden's own name in the user agent as
    /// Safari's version, and for a private tab a store that keeps nothing.
    static func configuration(private isPrivate: Bool) -> WKWebViewConfiguration {
        configuration(store: isPrivate ? .nonPersistent() : ordinaryStore)
    }

    /// The same, with `store`: a space's own, say (WebsiteStores).
    static func configuration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.applicationNameForUserAgent = "Version/\(safariVersion) Mobile/15E148 Safari/604.1"
        return configuration
    }

    /// The system's Safari version, which pages expect in the user agent.
    private static var safariVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    /// The page, built the first time something asks for it: a session of
    /// tabs coming back costs nothing until each is looked at.
    var webView: WKWebView {
        if let built { return built }
        restsAtHome = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = true
        view.isInspectable = true
        view.navigationDelegate = self
        view.uiDelegate = self
        view.accessibilityIdentifier = "page"
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pulled(_:)), for: .valueChanged)
        view.scrollView.refreshControl = refresh
        Shield.shared.protect(configuration.userContentController)
        browser?.prepare(configuration.userContentController, for: self)
        built = view
        watch(view)
        if let pending {
            self.pending = nil
            // Signed in as it was: its store's sessions back first (SessionCookies).
            SessionCookies.shared.whenRestored(configuration.websiteDataStore) { [weak view] in
                view?.load(URLRequest(url: pending))
            }
        }
        return view
    }

    /// Whether the page has been made yet.
    var isBuilt: Bool { built != nil }

    // MARK: - going places

    /// The tab goes to `url`, now if its page is made, else when it is.
    func load(_ url: URL) {
        failure = nil
        self.url = url
        if let built {
            Shield.shared.tune(configuration.userContentController, for: url.host())
            SessionCookies.shared.whenRestored(configuration.websiteDataStore) { [weak built] in
                built?.load(URLRequest(url: url))
            }
        } else {
            pending = url
        }
    }

    /// A tab from the last session: its address and title, loaded when it is
    /// first shown.
    func restore(url: URL, title: String) {
        self.url = url
        self.title = title
        pending = url
    }

    /// A pop-up's address, to show until its page says where it is: WebKit
    /// loads the request itself, with its method and body, into the page
    /// handed back to it — loading it here too would send it twice, a form's
    /// POST again as a bare GET.
    func opening(_ url: URL) {
        self.url = url
    }

    /// Back and forward say at once where they lead: WebKit says so only
    /// once the page gone to commits, after it has loaded, so the buttons
    /// would lag behind the tap. What WebKit says later stands (`settled`).
    func goBack() {
        guard let built, built.goBack() != nil else { return }
        canGoForward = true
        canGoBack = built.backForwardList.backList.count > 1
    }

    func goForward() {
        guard let built, built.goForward() != nil else { return }
        canGoBack = true
        canGoForward = built.backForwardList.forwardList.count > 1
    }

    /// The pages behind, nearest first, and those ahead: what holding the
    /// back or forward button offers, as in Safari.
    var backList: [WKBackForwardListItem] { built.map { Array($0.backForwardList.backList.reversed()) } ?? [] }
    var forwardList: [WKBackForwardListItem] { built?.backForwardList.forwardList ?? [] }

    /// Straight to one of those pages, the buttons saying so at once as above.
    func go(to item: WKBackForwardListItem) {
        guard let built else { return }
        let list = built.backForwardList
        let behind = list.backList.firstIndex(of: item)
        let ahead = list.forwardList.firstIndex(of: item)
        guard built.go(to: item) != nil else { return }
        if let behind {
            canGoForward = true
            canGoBack = behind > 0
        } else if let ahead {
            canGoBack = true
            canGoForward = ahead < list.forwardList.count - 1
        }
    }

    /// Back and forward as WebKit has them, once a step has landed or come
    /// to nothing.
    private func settled(_ webView: WKWebView) {
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
    }

    func reload() {
        failure = nil
        // Whatever was being looked for is for the page as it was.
        generation += 1
        isReading = false
        if let built, built.url != nil { built.reload() } else if let url { load(url) }
    }

    /// Whether the page has an address to load once it is made.
    var isPending: Bool { pending != nil }

    // MARK: - hiding (Hiding.swift)

    /// The page's content controller, shared with the windows it opens.
    var contentController: WKUserContentController { configuration.userContentController }

    /// One of Eden's scripts run on the page showing, in Eden's world.
    func run(_ script: String) {
        built?.evaluateJavaScript(script, in: nil, in: Tab.world)
    }

    /// The page as it shows now: kept small as its card (`snapshot`), and
    /// handed back as drawn, for the page to shrink into that card. Nil with
    /// no page on screen.
    @MainActor func capture() async -> UIImage? {
        guard let built, built.window != nil, url != nil else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        guard let image = try? await built.takeSnapshot(configuration: configuration) else { return nil }
        // Sharp at a card's size in the tab overview, about two thirds of
        // the screen across.
        let width: CGFloat = 290
        let size = CGSize(width: width, height: (image.size.height * width / max(1, image.size.width)).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        snapshot = picture
        // Kept for the next launch, never a private tab's (CardPictures).
        if !isPrivate, let url { CardPictures.shared.keep(picture, for: url) }
        return image
    }

    /// A picture of its page found for it (CardPictures), while it has none
    /// of its own.
    @MainActor func adopt(snapshot picture: UIImage) {
        if snapshot == nil { snapshot = picture }
    }

    /// The same, and what it answered: nil for no page, or no answer.
    @MainActor func ask(_ script: String) async -> Any? {
        guard let built else { return nil }
        return try? await built.evaluateJavaScript(script, in: nil, contentWorld: Tab.world)
    }

    /// Whether this tab's page is `page`.
    func shows(_ page: WKWebView?) -> Bool { page != nil && built === page }

    // MARK: - reading

    /// Into reading mode, or out of it, which reloads the page. How it went
    /// (`.gone` too when a look was already under way, the same request).
    func toggleReading(twins: Bool) async -> ReadingMode.Outcome {
        guard let built, Continuity.page(url) != nil else { return .nothing }
        guard !isReading else {
            reload()
            return .read
        }
        guard !seekingArticle else { return .gone }
        seekingArticle = true
        defer { seekingArticle = false }
        let asked = generation
        let page = built.url
        let outcome = await ReadingMode.enter(built, twins: twins, look: .system, world: Tab.world) { [weak self, weak built] in
            guard let self, let built else { return false }
            return self.generation == asked && self.built === built && built.url == page
        }
        if outcome == .read { isReading = true }
        return outcome
    }

    func stop() { built?.stopLoading() }

    @objc private func pulled(_ control: UIRefreshControl) {
        reload()
        control.endRefreshing()
    }

    /// The page and everything it keeps let go, as the tab closes.
    func close() {
        // Nothing it is still asked does anything to the browser.
        browser = nil
        watching.forEach { $0.invalidate() }
        watching = []
        built?.stopLoading()
        built?.navigationDelegate = nil
        built?.uiDelegate = nil
        built?.removeFromSuperview()
        built = nil
    }

    // MARK: - following the page

    private func watch(_ view: WKWebView) {
        watching = [
            view.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                MainActor.assumeIsolated { self?.scrolled(scroll) }
            },
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.titleChanged(view.title ?? "") }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { if let url = view.url { self?.url = url } }
            },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            view.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    let light = Tab.isLight(view.underPageBackgroundColor, as: view.traitCollection)
                    if self?.isLight != light { self?.isLight = light }
                }
            },
        ]
    }

    /// Whether `color` is light enough that dark writing reads on it; nil
    /// for one too clear to tell.
    private static func isLight(_ color: UIColor?, as traits: UITraitCollection) -> Bool? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard let color, color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              alpha > 0.5 else { return nil }
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.55
    }

    /// Where the page is scrolled to, as a fraction of how far it goes: in
    /// hundredths, so a scroll changes it only now and then.
    private func scrolled(_ scroll: UIScrollView) {
        let range = scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height
        let fraction = range > 0 ? (min(1, max(0, scroll.contentOffset.y / range)) * 100).rounded() / 100 : 0
        if fraction != readFraction { readFraction = fraction }
        let step = DeviceTabs.Page.scroll(fraction)
        if step != readStep { readStep = step }
    }

    /// A page from another device, shown as it was left there: now, when
    /// this tab is already showing it, else once it has come in.
    func carry(on arrival: Arrival) {
        guard let built, !built.isLoading, url.map(History.identity(for:)) == History.identity(for: arrival.page) else {
            self.arrival = arrival
            return
        }
        let page = generation
        Task { await arrive(arrival, on: page) }
    }

    /// Its article, if it was being read so and isn't yet, then as far
    /// down, and said — only while `page` (Tab.generation) is still the one
    /// showing.
    private func arrive(_ arrival: Arrival, on page: Int) async {
        guard generation == page else { return }
        if arrival.reading, !isReading, let browser {
            _ = await toggleReading(twins: browser.settings.readsTwins)
            // Somewhere else by now: nothing to carry on with, nor to say.
            guard generation == page else { return }
        }
        guard let scroll = arrival.scroll else {
            browser?.announce("Continued from \(arrival.from)")
            return
        }
        await scrollTo(scroll, from: arrival.from)
    }

    /// As far down as it was read there, and said.
    private func scrollTo(_ scroll: Double, from device: String) async {
        guard let built else { return }
        let script = "window.scrollTo(0, \(scroll) * Math.max(0, document.documentElement.scrollHeight - window.innerHeight))"
        _ = try? await built.evaluateJavaScript(script, contentWorld: .page)
        browser?.announce(scroll > 0 ? "Continued from \(device) at \(Int((scroll * 100).rounded()))%" : "Continued from \(device)")
    }

    private func titleChanged(_ title: String) {
        self.title = title
        if !isPrivate, let url, !title.isEmpty { browser?.history.retitle(url, title) }
    }
}

// MARK: - WebKit's questions

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url else { return (.cancel, preferences) }
        let scheme = url.scheme?.lowercased() ?? ""
        // A link to another app — a phone number, a mail, the App Store — goes
        // to that app, as in Safari: only a link tapped in the page itself,
        // never a page or a frame sending itself there, and only once you say
        // so, since whatever the address carries goes to that app.
        if !["http", "https", "about", "data", "blob"].contains(scheme) {
            let tapped = navigationAction.navigationType == .linkActivated
                && (navigationAction.targetFrame?.isMainFrame ?? true)
            // Not canOpenURL: it says no to any scheme the app doesn't list,
            // and opening one no app takes simply does nothing.
            if tapped, await Dialogs.openApp(url, from: navigationAction.sourceFrame, in: webView) {
                await UIApplication.shared.open(url)
            }
            return (.cancel, preferences)
        }
        // The main frame heading somewhere: the blocker on or off for that site.
        if navigationAction.targetFrame?.isMainFrame ?? true {
            Shield.shared.tune(configuration.userContentController, for: url.host())
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
        // Leaving: an article being looked for belongs to the page going.
        generation += 1
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        settled(webView)
        // Another page: whatever was being read, or picked from, was the
        // last one's.
        generation += 1
        isReading = false
        commits += 1
        shown = Curtain.host(of: webView.url).map { ShownPage(number: commits, host: $0) }
        // A new page is read from its top, whatever the last had come to.
        readFraction = 0
        readStep = 0
        browser?.pageChanged(in: self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settled(webView)
        guard let url = webView.url else { return }
        self.url = url
        if !isPrivate, ["http", "https"].contains(url.scheme?.lowercased()) {
            browser?.history.record(url, title: webView.title ?? "")
            MainActor.assumeIsolated { SiteIcons.shared.learn(from: self, at: url) }
        }
        browser?.tabChanged(self)
        // Its card in the tab overview, as it shows now, once it has drawn:
        // not only the tab the overview is opened from has a fresh one.
        if webView.window != nil {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                _ = await self?.capture()
            }
        }
        if let arrival {
            self.arrival = nil
            // Only the page it was for: one gone to instead, or a load given
            // up for another, takes none of it.
            // Bound to this page as it finished, should another start before
            // it is carried on with.
            let page = generation
            if History.identity(for: url) == History.identity(for: arrival.page) { Task { await arrive(arrival, on: page) } }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        settled(webView)
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        settled(webView)
        failed(error)
    }

    private func failed(_ error: Error) {
        let code = (error as NSError).code
        // A load replaced by another, or stopped by hand, isn't a failure.
        guard code != NSURLErrorCancelled, code != 102 else { return }
        failure = error.localizedDescription
    }

    /// The page's process went: the page comes back rather than staying blank.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension Tab: WKUIDelegate {
    /// A page opening a window — a link with target=_blank, or window.open —
    /// gets a tab of its own, beside this one, with WebKit's configuration
    /// so it keeps its opener (a sign-in pop-up reports back that way).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        browser?.adopt(configuration: configuration, request: navigationAction.request, from: self)?.webView
    }

    /// window.close() from a page this tab's opener made.
    func webViewDidClose(_ webView: WKWebView) {
        browser?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await Dialogs.alert(message, from: frame, in: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await Dialogs.confirm(message, from: frame, in: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        await Dialogs.prompt(prompt, defaultText: defaultText, from: frame, in: webView)
    }

    /// A link held down: open it in a new tab, or a new private one, beside
    /// what WebKit offers itself.
    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo)
        async -> UIContextMenuConfiguration? {
        guard let link = elementInfo.linkURL, Continuity.page(link) != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            let newTab = UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                guard let self else { return }
                self.browser?.newTab(url: link, private: self.isPrivate, select: false, after: self)
            }
            let newPrivate = UIAction(title: "Open in Private Tab", image: UIImage(systemName: "eye.slash")) { _ in
                guard let self else { return }
                self.browser?.newTab(url: link, private: true, select: false, after: self)
            }
            return UIMenu(children: [newTab, newPrivate] + suggested)
        }
    }
}
