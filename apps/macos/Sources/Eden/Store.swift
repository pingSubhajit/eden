import EdenCore
import Foundation
import WebKit

// What the Mac app keeps in WebKit's stores, beside EdenCore's Store: a test
// run's own website store, and the switch that keeps sign-ins.

extension Store {
    /// Cookies, sign-ins, caches. WebKit keeps its default store per bundle,
    /// not per folder, so a test run got every site already signed in — and
    /// "sign out of everything" in a test run signed the real browser out.
    /// A test run gets a store of its own, under a fixed name so it persists
    /// between probes the way the real one does. Wiping the test store is
    /// then as safe as wiping its folder.
    static var websites: WKWebsiteDataStore {
        guard testing, !ownContainer else { return .default() }
        return WKWebsiteDataStore(forIdentifier: probeStore(1))
    }

    /// Settings › Privacy › Prevent cross-site tracking, turned off. WebKit's
    /// tracking prevention, as in Safari, clears what a site it has seen
    /// redirect you — a sign-in through Google or Apple, say — left in local
    /// storage once you haven't opened it for a week or a month of use, and a
    /// site it counts as a tracker loses its cookies too: you are signed out.
    /// Turned off, that stops, and so does the rest of it: a site framed in
    /// another gets its cookies again, so trackers can follow you across
    /// sites, as in Chrome. On unless turned off; until then its flag is not
    /// touched.
    @MainActor static var keepsSignIns = false {
        didSet {
            guard keepsSignIns != oldValue else { return }
            Spaces.everyStore.forEach(followSignIns)
        }
    }

    /// The switch through a name outside the public framework — Safari's
    /// "Prevent cross-site tracking" is the same one.
    @MainActor static func followSignIns(_ store: WKWebsiteDataStore) {
        followCookies(store)
        let set = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
        guard store.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(store.method(for: set), to: Setter.self)(store, set, !keepsSignIns)
    }

    /// Off, the store's cookie policy is Always too: left as it was, it took
    /// cookies only from the page's own site, and a site framed in another —
    /// a Kaltura video in a Brightspace course — still got none. WebKit keeps
    /// the policy with the store, so it is set back when the switch is on, and
    /// at launch for every store, which an earlier run may have left at Always.
    @MainActor static func followCookies(_ store: WKWebsiteDataStore) {
        let jar = store.httpCookieStore
        let policy = NSSelectorFromString("_setCookieAcceptPolicy:completionHandler:")
        guard jar.responds(to: policy) else { return }
        typealias Policy = @convention(c) (AnyObject, Selector, UInt, @escaping @convention(block) () -> Void) -> Void
        let accept: HTTPCookie.AcceptPolicy = keepsSignIns ? .always : .onlyFromMainDocumentDomain
        unsafeBitCast(jar.method(for: policy), to: Policy.self)(jar, policy, accept.rawValue) {}
    }

    /// A test copy of the app under a bundle id of its own has a WebKit
    /// container of its own too, so it can use WebKit's default store and
    /// extension configuration — the ones the real browser uses, which
    /// differ from stores made by identifier in how long extension workers
    /// are let live.
    static var ownContainer: Bool {
        (Bundle.main.bundleIdentifier ?? "") != "com.subhajit.eden.beta"
    }
}
