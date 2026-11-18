import EdenCore
import Foundation
import Observation
import UIKit
import WebKit

/// The tabs, which one is in front, and what they share: history, bookmarks,
/// settings. One per app; on iPad, every window shows the same tabs.
@Observable
final class Browser {
    private(set) var tabs: [Tab] = []
    /// The tab in front, ordinary or private.
    private(set) var activeID: Tab.ID?
    /// A short line said over the page a moment, and gone (RootView).
    private(set) var notice: String?
    @ObservationIgnored private var noticeClears: Task<Void, Never>?

    @ObservationIgnored let history: History
    @ObservationIgnored let bookmarks: BookmarkStore
    @ObservationIgnored let settings: Settings
    /// Where the ordinary tabs are kept between launches; nil keeps none.
    @ObservationIgnored private let sessionFile: URL?
    /// Told when the ordinary tabs change, so sync shows them on your other
    /// devices (Syncing).
    @ObservationIgnored var changed: (() -> Void)?
    /// Sync through iCloud, once the app has made it.
    @ObservationIgnored var sync: Syncing?

    init(history: History, bookmarks: BookmarkStore, settings: Settings,
         sessionFile: URL? = Store.file("tabs.json")) {
        self.history = history
        self.bookmarks = bookmarks
        self.settings = settings
        self.sessionFile = sessionFile
        restore()
        // Always a tab to type into: a first launch, or a session of none,
        // starts with an empty one.
        if tabs.isEmpty { newTab() }
    }

    var active: Tab? { tabs.first { $0.id == activeID } }
    var ordinaryTabs: [Tab] { tabs.filter { !$0.isPrivate } }
    var privateTabs: [Tab] { tabs.filter(\.isPrivate) }

    // MARK: - opening and closing

    /// A new tab, at the end of its kind or right after `after`, going to `url`
    /// if there is one.
    @discardableResult
    func newTab(url: URL? = nil, private isPrivate: Bool = false, select: Bool = true, after: Tab? = nil) -> Tab {
        let tab = Tab(isPrivate: isPrivate)
        insert(tab, after: after)
        if let url { tab.load(url) }
        if select { activeID = tab.id }
        save()
        return tab
    }

    /// A window a page opened (Tab's createWebViewWith): a tab right after the
    /// page's own, in front, made with WebKit's configuration. The page loads
    /// what it asked for itself; `request` only names it until then.
    func adopt(configuration: WKWebViewConfiguration, request: URLRequest, from opener: Tab) -> Tab? {
        let tab = Tab(isPrivate: opener.isPrivate, configuration: configuration)
        if let url = request.url { tab.opening(url) }
        insert(tab, after: opener)
        activeID = tab.id
        save()
        return tab
    }

    private func insert(_ tab: Tab, after: Tab?) {
        tab.browser = self
        if let after, let index = tabs.firstIndex(where: { $0.id == after.id }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
    }

    /// What was typed in the address field, opened in `tab` — or in a new tab
    /// when there is none. False when it can't go anywhere.
    @discardableResult
    func go(_ typed: String, in tab: Tab?) -> Bool {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = destination(for: text) else { return false }
        if let tab {
            tab.load(url)
            activeID = tab.id
            save()
        } else {
            newTab(url: url)
        }
        return true
    }

    /// Where typed text goes: an address, a site's shortcut, or a search.
    func destination(for typed: String) -> URL? {
        Address.destination(for: typed, engine: settings.searchTemplate)
    }

    func select(_ tab: Tab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        activeID = tab.id
        save()
    }

    /// The tab gone, and the one beside it in front if it was: the next of
    /// its kind, else the one before, else none.
    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let wasActive = tab.id == activeID
        tabs.remove(at: index)
        tab.close()
        // The last tab gone leaves an empty one, never none.
        if tabs.isEmpty {
            newTab()
            return
        }
        if wasActive {
            let sameKind = { (other: Tab) in other.isPrivate == tab.isPrivate }
            let after = tabs[index...].first(where: sameKind)
            activeID = (after ?? tabs.last(where: sameKind) ?? tabs.last)?.id
        }
        save()
    }

    /// Every tab of one kind gone — all the private ones, say.
    func closeAll(private isPrivate: Bool) {
        for tab in tabs where tab.isPrivate == isPrivate { close(tab) }
    }

    /// A line said over the page for a few seconds, and to VoiceOver.
    func announce(_ line: String) {
        notice = line
        UIAccessibility.post(notification: .announcement, argument: line)
        noticeClears?.cancel()
        noticeClears = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// The tab's page as its article, or back to the page. "Nothing to read"
    /// is said only about the page still in front.
    func toggleReading(_ tab: Tab) {
        Task {
            guard await tab.toggleReading(twins: settings.readsTwins) == .nothing, activeID == tab.id else { return }
            announce("Nothing to read on this page")
        }
    }

    /// A page arrived somewhere new: written down, for the next launch.
    func tabChanged(_ tab: Tab) {
        if !tab.isPrivate { save() }
    }

    // MARK: - the session

    /// What is written: the ordinary tabs' addresses and titles and which
    /// one was in front. A private tab is never written anywhere.
    nonisolated struct Session: Codable, Equatable, Sendable {
        nonisolated struct Entry: Codable, Equatable, Sendable {
            var url: String
            var title: String
        }
        var tabs: [Entry]
        var active: Int?
    }

    var session: Session {
        let kept = ordinaryTabs.compactMap { tab -> Session.Entry? in
            guard let url = tab.url, Continuity.page(url) != nil else { return nil }
            return Session.Entry(url: url.absoluteString, title: tab.title)
        }
        let front = ordinaryTabs.filter { Continuity.page($0.url) != nil }.firstIndex { $0.id == activeID }
        return Session(tabs: kept, active: front)
    }

    private func save() {
        changed?()
        guard let sessionFile else { return }
        let snapshot = session
        Disk.write(sessionFile) { try? JSONEncoder().encode(snapshot) }
    }

    private func restore() {
        guard let sessionFile, let data = try? Data(contentsOf: sessionFile) else { return }
        guard let read = try? JSONDecoder().decode(Session.self, from: data) else {
            Store.quarantine(sessionFile)
            return
        }
        for entry in read.tabs {
            guard let url = URL(string: entry.url) else { continue }
            let tab = Tab(isPrivate: false)
            tab.restore(url: url, title: entry.title)
            insert(tab, after: nil)
        }
        if let index = read.active, tabs.indices.contains(index) { activeID = tabs[index].id }
        // A private or empty tab was in front, and no session keeps those:
        // the last tab that came back is in front instead, never none.
        if activeID == nil { activeID = tabs.last?.id }
    }

    /// Everything asked to be written, written now: the app is going to the
    /// background and may not come back.
    func flush() {
        save()
        history.flush()
        Disk.drain()
    }

    // MARK: - the blocker

    /// The blocker switched on or off for every page already open.
    func applyBlocking() {
        Shield.shared.enabled = settings.blocks
        Shield.shared.apply(to: tabs.filter(\.isBuilt).map { $0.webView.configuration.userContentController })
    }
}
