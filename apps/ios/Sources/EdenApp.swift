import EdenCore
import SwiftUI
import WebKit

// Eden for iPhone and iPad: tabs and one field for addresses and searches,
// private tabs, the Mac's blocker, bookmarks and history kept on the device,
// and Handoff with your other devices. Built on EdenCore, which it shares
// with the Mac app (packages/).

@main
struct EdenApp: App {
    @State private var browser: Browser
    @Environment(\.scenePhase) private var phase

    init() {
        EdenApp.startFreshIfAsked()
        let settings = Settings()
        Shield.shared.enabled = settings.blocks
        Shield.shared.compile()
        _browser = State(initialValue: Browser(history: History(), bookmarks: BookmarkStore(), settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootView(browser: browser)
        }
        .onChange(of: phase) { _, now in
            // Going to the background, the app may not come back: what was
            // asked to be written is written.
            if now == .background { browser.flush() }
        }
    }

    /// A UI test's launch (EDEN_PROBE, a test world of its own, with
    /// EDEN_FRESH=1) starts with nothing: no tabs, bookmarks, history or
    /// settings from an earlier run. Never the world somebody uses.
    private static func startFreshIfAsked() {
        guard Store.testing, ProcessInfo.processInfo.environment["EDEN_FRESH"] == "1" else { return }
        try? FileManager.default.removeItem(at: Store.folder)
        if let suite = Store.settingsSuite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        // The test world's own website store, never WebKit's default one
        // (Tab.ordinaryStore): its cookies and site data gone before any page
        // of this run is made — TabContent shows none until it is done, so a
        // page typed, or handed over, waits for it.
        Clearing.shared.begin()
        let everything = WKWebsiteDataStore.allWebsiteDataTypes()
        Tab.ordinaryStore.removeData(ofTypes: everything, modifiedSince: .distantPast) {
            Clearing.shared.finish()
        }
    }
}

/// A UI test's fresh start clearing its website store (EdenApp): until it is
/// done, no page is made, so nothing loads with the last run's cookies.
@Observable
final class Clearing {
    static let shared = Clearing()
    private(set) var done = true
    func begin() { done = false }
    func finish() { done = true }
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

    init?(showing: Bool, address: URL?, title: String) {
        guard showing, let address = Activity.web(address) else { return nil }
        self.address = address
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? nil : trimmed
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
        .onContinueUserActivity(Activity.web, perform: take)
        .onContinueUserActivity(Activity.browsing, perform: take)
        // The page in front, offered to your other devices as Eden's own
        // activity once Settings › Hand Off Pages is on; never a private tab.
        // Read here in body, so a new address or title updates the offer.
        .userActivity(Activity.browsing, element: offered) { offered, activity in
            activity.webpageURL = offered.address
            activity.title = offered.title
            activity.isEligibleForHandoff = true
            activity.isEligibleForSearch = false
            activity.isEligibleForPublicIndexing = false
        }
    }

    private var offered: Offered? {
        guard let tab = browser.active else { return nil }
        return Offered(showing: browser.settings.handsOff && !tab.isPrivate, address: tab.url, title: tab.title)
    }

    /// A page handed over: into the tab in front if it has nowhere to be yet,
    /// else a new tab, in front.
    private func take(_ activity: NSUserActivity) {
        guard let url = Activity.web(activity.webpageURL) else { return }
        if let tab = browser.active, !tab.isPrivate, tab.url == nil {
            tab.load(url)
        } else {
            browser.newTab(url: url)
        }
    }
}
