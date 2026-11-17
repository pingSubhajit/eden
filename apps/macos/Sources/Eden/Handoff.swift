import AppKit
import SwiftUI

// Handoff: the page in front, offered to your other devices, and a page
// one of them offers, taken here.
//
// Offering. With Settings › General › Hand off pages to your other devices
// on (off unless turned on: the address and title of the page in front then
// go to your devices through Apple), each window offers its tab in front as
// an activity of Eden's own (`browsing`), with the page's address. Eden on
// an iPhone or iPad continues it; a device without Eden opens the address
// in its browser, as the system does for any activity carrying one. AppKit
// advertises the activity of the key window and stops when Eden is not in
// front, so a window only has to hold the right one: `Handoff.Offer` keeps
// it in step with the tab, the switch and the window. Nothing is offered
// for a private tab, a tab the bench drives, a pop-up's window, or a page
// that isn't an http or https page of the web (Eden's own pages, files,
// about:blank, an address with a name or password in it).
//
// Taking. A page offered by Eden on another device, or by Safari or any
// browser there once Eden is this Mac's browser, arrives at
// Links.application(_:continue:restorationHandler:) and opens in a tab of
// the window in front, as a link from another app does but never in the
// small window: it is a page you were reading, coming back to the browser.
// Whatever the switch says, as nothing leaves the Mac for it.
//
// The activity types are listed in the app's Info.plist (build.sh) and the
// iOS app's (apps/ios/Configuration/Info.plist), and must stay the same in
// all three places.

enum Handoff {
    /// Eden's own activity: a page in Eden, on any of your devices.
    static let browsing = "com.subhajit.eden.beta.browsing"
    /// The system's activity for a web page, as Safari and other browsers
    /// offer it.
    static let web = NSUserActivityTypeBrowsingWeb
    /// What Eden takes from another device.
    static let taken: Set<String> = [browsing, web]

    /// The address a tab offers: its page at rest, only when offering is on,
    /// and only an ordinary web page of an ordinary tab. Nil offers nothing.
    static func offered(_ address: URL?, on: Bool, private shy: Bool, bench: Bool, popup: Bool) -> URL? {
        guard on, !shy, !bench, !popup else { return nil }
        return web(address)
    }

    /// The address of a page handed over by another device, to open here:
    /// an activity Eden takes, carrying an ordinary web page. Nil for
    /// anything else.
    static func received(_ activity: NSUserActivity) -> URL? {
        guard taken.contains(activity.activityType) else { return nil }
        return web(activity.webpageURL)
    }

    /// An http or https address with a host and no name or password in it.
    private static func web(_ address: URL?) -> URL? {
        guard let address, let scheme = address.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = address.host(), !host.isEmpty,
              address.user(percentEncoded: false) == nil, address.password(percentEncoded: false) == nil
        else { return nil }
        return address
    }

    /// The title an activity carries: the name you gave the tab, else the
    /// page's own, as the window is named (WindowTitle); none when both are
    /// blank, and the receiving device names it for its address.
    static func title(name: String?, page: String) -> String? {
        let chosen = (name ?? page).trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.isEmpty ? nil : chosen
    }

    // MARK: - each window's activity

    /// The activity a window holds, and the tab it is for. A tab switch
    /// makes the new tab's view appear before or after the old one goes;
    /// the tab says which of them still owns the window.
    private final class Held {
        weak var window: NSWindow?
        var tab: Tab.ID
        let activity: NSUserActivity
        init(window: NSWindow, tab: Tab.ID, activity: NSUserActivity) {
            self.window = window
            self.tab = tab
            self.activity = activity
        }
    }

    /// Each window's, by window. A window that went without a word leaves
    /// its entry with no window, cleared at the next offer, so an address a
    /// new window reuses never finds an old one's.
    @MainActor private static var offers: [ObjectIdentifier: Held] = [:]

    /// The window offers `address` for `tab`, or nothing when it is nil.
    @MainActor
    static func offer(_ address: URL?, title: String?, for tab: Tab.ID, in window: NSWindow) {
        for (key, held) in offers where held.window == nil {
            held.activity.invalidate()
            offers[key] = nil
        }
        let key = ObjectIdentifier(window)
        guard let address else {
            withdraw(key, from: window)
            return
        }
        let held: Held
        if let kept = offers[key] {
            held = kept
            held.tab = tab
        } else {
            let activity = NSUserActivity(activityType: browsing)
            activity.isEligibleForHandoff = true
            activity.isEligibleForSearch = false
            activity.isEligibleForPublicIndexing = false
            held = Held(window: window, tab: tab, activity: activity)
            offers[key] = held
        }
        if held.activity.webpageURL != address { held.activity.webpageURL = address }
        if held.activity.title != title { held.activity.title = title }
        if window.userActivity !== held.activity { window.userActivity = held.activity }
    }

    /// The window offers nothing for `tab` any more: its view went, with the
    /// tab switched away or the window closed. Left alone when another tab
    /// has already taken the window over.
    @MainActor
    static func withdraw(_ tab: Tab.ID, from window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard offers[key]?.tab == tab else { return }
        withdraw(key, from: window)
    }

    @MainActor
    private static func withdraw(_ key: ObjectIdentifier, from window: NSWindow) {
        guard let held = offers.removeValue(forKey: key) else { return }
        if window.userActivity === held.activity { window.userActivity = nil }
        // An activity once invalidated is never advertised again; the next
        // offer makes a new one.
        held.activity.invalidate()
    }

    /// What the window offers now, for the bench: nil when nothing.
    @MainActor
    static func offered(in window: NSWindow) -> (address: URL, title: String?)? {
        guard let held = offers[ObjectIdentifier(window)], held.window === window, window.userActivity === held.activity,
              let address = held.activity.webpageURL else { return nil }
        return (address, held.activity.title)
    }

    /// The window's offer, worked out afresh from its tab in front and the
    /// switch. Also called as the window is first set (ContentView.setUp),
    /// so a window doesn't wait for the next change to offer its page.
    @MainActor
    static func apply(_ tab: Tab, in browser: Browser, window: NSWindow) {
        let address = offered(tab.restAddress, on: browser.prefs.handsOff, private: tab.shy,
                              bench: tab.bench, popup: browser.isPopup)
        offer(address, title: title(name: tab.name, page: tab.title), for: tab.id, in: window)
    }

    /// Keeps a window's offer in step with its tab in front: drawn nowhere,
    /// it follows the page, its title and the switch, and withdraws the
    /// offer when its tab stops being the one in front. The window is the
    /// one held for the view, else the browser's, looked up each time: the
    /// view can come before the window does (see ContentView.setUp).
    struct Offer: View {
        @ObservedObject var tab: Tab
        @ObservedObject var prefs: Preferences
        let browser: Browser
        let window: NSWindow?

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear(perform: apply)
                .onChange(of: tab.committed) { _, _ in apply() }
                .onChange(of: tab.address) { _, _ in apply() }
                .onChange(of: tab.title) { _, _ in apply() }
                .onChange(of: tab.name) { _, _ in apply() }
                .onChange(of: prefs.handsOff) { _, _ in apply() }
                .onDisappear { if let window = window ?? browser.window { Handoff.withdraw(tab.id, from: window) } }
        }

        private func apply() {
            if let window = window ?? browser.window { Handoff.apply(tab, in: browser, window: window) }
        }
    }
}
