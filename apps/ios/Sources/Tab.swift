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
    let isPrivate: Bool

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

    /// A new tab. `configuration` is WebKit's own when a page opens a window
    /// (Browser.adopt), so the window keeps its opener, and `own` the opener's
    /// own changes to what is hidden, which a private window shares.
    init(isPrivate: Bool, configuration: WKWebViewConfiguration? = nil, sharing own: PrivateHiding? = nil) {
        self.isPrivate = isPrivate
        self.configuration = configuration ?? Tab.configuration(private: isPrivate)
        privateHiding = isPrivate ? own ?? PrivateHiding() : nil
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
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : ordinaryStore
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
            view.load(URLRequest(url: pending))
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
            built.load(URLRequest(url: url))
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

    func goBack() { built?.goBack() }
    func goForward() { built?.goForward() }

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
        ]
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
        // Another page: whatever was being read, or picked from, was the
        // last one's.
        generation += 1
        isReading = false
        commits += 1
        shown = Curtain.host(of: webView.url).map { ShownPage(number: commits, host: $0) }
        browser?.pageChanged(in: self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        self.url = url
        if !isPrivate, ["http", "https"].contains(url.scheme?.lowercased()) {
            browser?.history.record(url, title: webView.title ?? "")
        }
        browser?.tabChanged(self)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
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
