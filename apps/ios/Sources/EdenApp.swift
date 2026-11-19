import EdenCore
import SwiftUI
import WebKit

// Eden for iPhone and iPad: tabs and one field for addresses and searches,
// private tabs, the Mac's blocker, bookmarks and history, Handoff with your
// other devices, and sync with them through iCloud (Syncing). Built on EdenCore, which it shares
// with the Mac app (packages/).

@main
struct EdenApp: App {
    @State private var browser: Browser
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var phase

    init() {
        EdenApp.startFreshIfAsked()
        let settings = Settings()
        Shield.shared.enabled = settings.blocks
        Shield.shared.compile()
        let made = Browser(history: History(), bookmarks: BookmarkStore(), settings: settings)
        made.sync = Syncing(browser: made)
        AppDelegate.syncing = made.sync
        _browser = State(initialValue: made)
    }

    var body: some Scene {
        WindowGroup {
            RootView(browser: browser)
        }
        .onChange(of: phase) { _, now in
            // Going to the background, the app may not come back: what was
            // asked to be written is written, and synced.
            if now == .background {
                browser.flush()
                EdenApp.writeSessions()
            }
            browser.sync?.active(now == .active)
            // In front, the phone is unlocked: whatever waited on it is read.
            if now == .active { SessionCookies.shared.protectedData(open: UIApplication.shared.isProtectedDataAvailable) }
        }
    }

    /// A UI test's launch (EDEN_PROBE, a test world of its own, with
    /// EDEN_FRESH=1) starts with nothing: no tabs, bookmarks, history or
    /// settings from an earlier run. Never the world somebody uses.
    /// The sites' sessions written down as the app goes to the background
    /// (SessionCookies), where it may not come back: given the moment iOS
    /// allows to finish.
    private static func writeSessions() {
        guard SessionCookies.shared.unwritten else { return }
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
        Task { @MainActor in
            await SessionCookies.shared.flush()
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// The sites' sessions kept from the last run, back in the store before
    /// its first page loads (SessionCookies); each space's own store as it is
    /// first made (WebsiteStores). Called as launching begins (AppDelegate),
    /// with UIKit's application in hand to say whether the phone's protected
    /// files and keychain are open: launched in the background before the
    /// first unlock, they wait for it. Watched first, then read, so a change
    /// between the two isn't missed.
    static func keepSessions(_ application: UIApplication) {
        let cookies = SessionCookies.shared
        let center = NotificationCenter.default
        for (name, open) in [(UIApplication.protectedDataDidBecomeAvailableNotification, true),
                             (UIApplication.protectedDataWillBecomeUnavailableNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { cookies.protectedData(open: open) }
            }
        }
        cookies.protectedData(open: application.isProtectedDataAvailable)
        cookies.keep(Tab.ordinaryStore, restoring: true)
    }

    private static func startFreshIfAsked() {
        guard Store.testing, ProcessInfo.processInfo.environment["EDEN_FRESH"] == "1" else { return }
        // The stores the last run's spaces had, found before the settings
        // that name them go.
        let spaceStores = WebsiteStores.probeIdentifiers(in: Store.settings)
        try? FileManager.default.removeItem(at: Store.folder)
        if let suite = Store.settingsSuite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        // The test world's own website stores, never WebKit's default one
        // (Tab.ordinaryStore): their cookies and site data gone before any
        // page of this run is made — TabContent shows none until it is done,
        // so a page typed, or handed over, waits for it.
        Clearing.shared.begin()
        let everything = WKWebsiteDataStore.allWebsiteDataTypes()
        Tab.ordinaryStore.removeData(ofTypes: everything, modifiedSince: .distantPast) {
            Clearing.shared.finish()
        }
        for identifier in spaceStores {
            Clearing.shared.begin()
            Task { @MainActor in
                try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
                Clearing.shared.finish()
            }
        }
    }
}

/// A UI test's fresh start clearing its website store (EdenApp): until it is
/// done, no page is made, so nothing loads with the last run's cookies.
@Observable
final class Clearing {
    static let shared = Clearing()
    private var waiting = 0
    var done: Bool { waiting == 0 }
    func begin() { waiting += 1 }
    func finish() { waiting = max(0, waiting - 1) }
}

/// The two kinds of page another device can hand over: the system's own,
/// from Safari or any browser, and Eden's, from Eden on the Mac. The Mac app
/// (apps/macos/Sources/Eden/Handoff.swift) uses the same two, and the same
/// rule for which pages may go (Continuity, in EdenCore).
enum Activity {
    static let web = NSUserActivityTypeBrowsingWeb
    /// From Info.plist (EDEN_ACTIVITY_BROWSING in Base.xcconfig), so it follows
    /// the bundle id.
    static let browsing = Bundle.main.object(forInfoDictionaryKey: "EdenActivityBrowsing") as? String
        ?? Continuity.browsing

    /// The page, when it may be taken or offered at all: the rule the Mac
    /// app uses too (Continuity, in EdenCore).
    static func web(_ address: URL?) -> URL? { Continuity.page(address) }
}

/// What the app offers your other devices: the page in front, when offering
/// is on and it is a page of the web, and its title, or nothing. A value, so
/// SwiftUI updates the activity whenever either part changes.
struct Offered: Hashable {
    let address: URL
    let title: String?
    /// How it is left here, for the device that takes it (Continuity.info).
    let info: [String: String]

    init?(showing: Bool, address: URL?, title: String, info: (URL) -> [String: String] = { _ in [:] }) {
        guard showing, let address = Activity.web(address) else { return nil }
        self.address = address
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? nil : trimmed
        self.info = info(address)
    }
}

/// The page in front, offered to your other devices as Eden's own activity
/// once Settings › Hand Off Pages is on — never a private tab — with how it
/// is left here: how far down it is read, whether as an article, its space.
/// Drawn nowhere; apart from the browser's views so that reading down a page
/// redraws nothing but this.
private struct HandoffOffer: View {
    let browser: Browser

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .userActivity(Activity.browsing, element: offered) { offered, activity in
                activity.webpageURL = offered.address
                activity.title = offered.title
                activity.userInfo = offered.info
                activity.isEligibleForHandoff = true
                activity.isEligibleForSearch = false
                activity.isEligibleForPublicIndexing = false
            }
    }

    private var offered: Offered? {
        guard let tab = browser.active, case .space(let space) = tab.owner else { return nil }
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let device = UIDevice.current.name
        return Offered(showing: browser.settings.handsOff, address: tab.url, title: tab.title) { _ in
            // A page on its way says only where it is going: how the one
            // before it was left isn't how this one is.
            tab.isLoading ? [:] : Continuity.info(scroll: tab.readStep, reading: tab.isReading, space: space,
                                                  device: device, kind: pad ? .ipad : .iphone)
        }
    }
}

/// The browser, laid out for the width it has: the iPhone's bar at the
/// bottom, or the iPad's sidebar. Handoff is handled here for both.
struct RootView: View {
    let browser: Browser
    @Environment(\.horizontalSizeClass) private var width

    var body: some View {
        Group {
            if width == .regular {
                PadBrowser(browser: browser)
            } else {
                PhoneBrowser(browser: browser)
            }
        }
        .overlay(alignment: .top) { NoticeView(line: browser.notice) }
        .onContinueUserActivity(Activity.web, perform: take)
        .onContinueUserActivity(Activity.browsing, perform: take)
        .background { HandoffOffer(browser: browser) }
    }

    /// A page handed over, as a page from any of your devices is opened
    /// (Browser.open(_ offer:)): to its tab if it is open here already, else
    /// in its own space — into the tab in front if it has nowhere to be yet —
    /// as far down as it was read, as an article if it was, and said.
    private func take(_ activity: NSUserActivity) {
        guard let url = Activity.web(activity.webpageURL) else { return }
        let empty = browser.active.flatMap { $0.isPrivate || $0.url != nil ? nil : $0 }
        browser.open(Continuity.offer(url, title: activity.title, info: activity.userInfo), in: empty)
    }
}

/// A short line over the page — "Nothing to read on this page" — for a
/// moment (Browser.announce).
struct NoticeView: View {
    let line: String?

    var body: some View {
        if let line {
            Text(line)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("notice")
        }
    }
}
