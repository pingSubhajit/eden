import EdenCore
import Foundation
import Observation
import UIKit
import WebKit

/// The tabs, which one is in front, and what they share: history, bookmarks,
/// settings, the spaces. One per app; on iPad, every window shows the same
/// tabs.
@Observable
final class Browser {
    /// Every tab of every space, and the private ones (Tab.owner).
    private(set) var tabs: [Tab] = []
    /// The tab in front, of the space in front or private. Another in front
    /// ends picking on the one that was (Hiding.swift).
    private(set) var activeID: Tab.ID? {
        didSet {
            if let session = picking, session.tab != activeID { stopHiding() }
            if let active, case .space(let id) = active.owner { selections[id] = active.id }
        }
    }
    /// The space in front (Spaces.swift): Personal while spaces are off.
    private(set) var spaceID: UUID
    /// The tab each space had in front when it was left.
    @ObservationIgnored private var selections: [UUID: Tab.ID] = [:]
    /// The spaces (Spaces.swift).
    let library: SpaceLibrary
    /// What every pin is (Pins.swift).
    let pins: PinStore
    /// The spaces' website stores (Spaces.swift).
    @ObservationIgnored let stores: WebsiteStores
    /// A short line said over the page a moment, and gone (RootView).
    private(set) var notice: String?
    @ObservationIgnored private var noticeClears: Task<Void, Never>?

    @ObservationIgnored let history: History
    @ObservationIgnored let bookmarks: BookmarkStore
    @ObservationIgnored let settings: Settings
    /// What you have taken off each site (Hiding.swift).
    let curtain: Curtain
    /// Picking, while it is on (Hiding.swift).
    var picking: PickingSession?
    /// What a tap on that page offered, to hide, widen or let go.
    var offered: VeilMessage.Choice?
    /// Carries what every page's picker says back (Hiding.swift).
    @ObservationIgnored let veilRelay = VeilRelay()
    /// The script putting on what is kept, made once per change to it; empty
    /// when nothing is (Hiding.swift).
    @ObservationIgnored var keptStyle: String?
    /// Where Personal's tabs are kept between launches, each other space's
    /// beside it (SpaceSessionFile); nil keeps none.
    @ObservationIgnored private let sessionFile: URL?
    /// Each space's session as last written, so only one that changed is
    /// written again.
    @ObservationIgnored private var written: [UUID: Session] = [:]
    /// Pages closed here a moment ago, for your other devices to offer
    /// (Syncing); never a private tab's.
    @ObservationIgnored private(set) var recentlyClosed: [DeviceTabs.Closed] = []
    /// Told when the ordinary tabs change, so sync shows them on your other
    /// devices (Syncing).
    @ObservationIgnored var changed: (() -> Void)?
    /// Sync through iCloud, once the app has made it.
    @ObservationIgnored var sync: Syncing?

    init(history: History, bookmarks: BookmarkStore, settings: Settings, curtain: Curtain = Curtain(),
         library: SpaceLibrary = SpaceLibrary(), pins: PinStore = PinStore(), stores: WebsiteStores = WebsiteStores(),
         sessionFile: URL? = Store.file(SpaceSessionFile.name(for: Space.firstID, stem: "tabs"))) {
        self.history = history
        self.bookmarks = bookmarks
        self.settings = settings
        self.curtain = curtain
        self.library = library
        self.pins = pins
        self.stores = stores
        self.sessionFile = sessionFile
        spaceID = Space.firstID
        veilRelay.received = { [weak self] said, origin in self?.heard(said, from: origin) }
        // A deletion a crash cut short, finished before any of its tabs
        // could come back — and before the space to show is chosen.
        for id in settings.deletingSpaces { finishDeleting(id) }
        let asked = settings.currentSpace
        if settings.usesSpaces, library.space(asked) != nil {
            spaceID = asked
        } else if asked != Space.firstID {
            settings.currentSpace = Space.firstID
        }
        restore()
        // Always a tab to type into: a first launch, or a space of none,
        // starts with an empty one.
        if spaceTabs.isEmpty { newTab() }
        stores.sweep()
    }

    var active: Tab? { tabs.first { $0.id == activeID } }
    /// Every space's tabs, the private ones left out.
    var ordinaryTabs: [Tab] { tabs.filter { !$0.isPrivate } }
    var privateTabs: [Tab] { tabs.filter(\.isPrivate) }

    // MARK: - opening and closing

    /// A new tab in the space in front, or private, at the end or right
    /// after `after` — and then in `after`'s space — going to `url` if there
    /// is one.
    @discardableResult
    func newTab(url: URL? = nil, private isPrivate: Bool = false, select: Bool = true, after: Tab? = nil) -> Tab {
        // Only a tab still here says where: one closed since, or of a space
        // deleted since, says nothing.
        let after = after.flatMap { opener in tabs.contains { $0 === opener } ? opener : nil }
        let owner: TabOwner = isPrivate ? .private : after.map(\.owner).flatMap { $0 == .private ? nil : $0 } ?? .space(spaceID)
        let tab = makeTab(owner)
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
        // Never for a page closed since, or of a space deleted since.
        guard tabs.contains(where: { $0 === opener }) else { return nil }
        let tab = Tab(owner: opener.owner, configuration: configuration, sharing: opener.privateHiding)
        if let url = request.url { tab.opening(url) }
        insert(tab, after: opener)
        // In front if its opener's space — or private — is; a page of a
        // space out of sight opens it there, to be found on going back.
        if opener.owner == active?.owner {
            activeID = tab.id
        } else if case .space(let id) = opener.owner {
            selections[id] = tab.id
        }
        save()
        return tab
    }

    /// A tab of `owner`, made with its store; its page made once it is shown.
    private func makeTab(_ owner: TabOwner) -> Tab {
        let tab = Tab(owner: owner, configuration: Tab.configuration(store: store(for: owner)))
        tab.browser = self
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

    /// A tab in front: its space with it, if it is another's.
    func select(_ tab: Tab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        if case .space(let id) = tab.owner, id != spaceID { enter(id) }
        activeID = tab.id
        save()
    }

    /// The tab gone, and if it was in front, the one beside it of the same
    /// space — or private — in front instead: the next, else the one before.
    /// The last private one gone goes back to the space in front; the space's
    /// last gone leaves an empty one, never none.
    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if picking?.tab == tab.id { stopHiding() }
        if tab.pin != nil { return rest(tab, at: index) }
        if case .space(let space) = tab.owner, let url = Continuity.page(tab.url) {
            let now = Date().timeIntervalSince1970
            recentlyClosed = DeviceTabs.recent(recentlyClosed + [DeviceTabs.Closed(url: url.absoluteString, title: tab.title,
                                                                                  space: space, at: now)], now: now)
        }
        let wasActive = tab.id == activeID
        tabs.remove(at: index)
        tab.close()
        if wasActive {
            let kin = { (other: Tab) in other.owner == tab.owner }
            if let next = tabs[index...].first(where: kin) ?? tabs.last(where: kin) {
                activeID = next.id
            } else if tab.isPrivate, let back = selections[spaceID].flatMap({ id in spaceTabs.first { $0.id == id } }) ?? spaceTabs.last {
                activeID = back.id
            } else {
                activeID = nil
            }
        }
        if activeID == nil {
            newTab()
            return
        }
        save()
    }

    /// The space in front's tabs gone — its pins stay — or all the private
    /// ones.
    func closeAll(private isPrivate: Bool) {
        for tab in (isPrivate ? privateTabs : looseTabs) { close(tab) }
    }

    // MARK: - spaces (Spaces.swift)

    /// Another space in front, with the tab that was in front there when it
    /// was left — or an empty one, for a space with none.
    func enter(_ id: UUID) {
        guard library.space(id) != nil, id == Space.firstID || settings.usesSpaces else { return }
        let leavingPrivate = active?.isPrivate == true
        guard id != spaceID || leavingPrivate else { return }
        spaceID = id
        settings.currentSpace = id
        let row = spaceTabs
        if let kept = selections[id], row.contains(where: { $0.id == kept }) {
            activeID = kept
        } else if let last = row.last(where: { $0.pin == nil }) {
            activeID = last.id
        } else {
            // Nothing in front there yet: an empty tab beside its pins.
            newTab()
            return
        }
        save()
    }

    /// A space, its tabs, and its own cookies and sign-ins, gone: the same
    /// whether deleted here or on another device. Personal stays. Its pages
    /// are never opened again under Personal's sign-ins.
    func deleteSpace(_ id: UUID) {
        guard id != Space.firstID, library.space(id) != nil else { return }
        // Written down before anything goes, so a launch after a crash
        // finishes the job (init).
        settings.deletingSpaces.insert(id)
        if spaceID == id { enter(Space.firstID) }
        if let session = picking, tabs.first(where: { $0.id == session.tab })?.owner == .space(id) { stopHiding() }
        for tab in tabs where tab.owner == .space(id) { tab.close() }
        tabs.removeAll { $0.owner == .space(id) }
        selections[id] = nil
        finishDeleting(id)
        save()
    }

    /// What a deleted space kept, gone, whichever step it had reached: its
    /// store (its own, never Personal's), its file, its pins, and itself.
    /// Crossed off only once all that is known to be on disk; otherwise the
    /// next launch does it again.
    private func finishDeleting(_ id: UUID) {
        guard id != Space.firstID else {
            settings.deletingSpaces.remove(id)
            return
        }
        if let gone = library.space(id), case .space = gone.storeKey(profileHome: Space.firstID) {
            stores.erase(id)
        }
        let mark = Disk.mark()
        forgetSession(of: id)
        pins.forget(space: id)
        library.remove(id)
        // Written as they now are, changed or not: a write that failed
        // before, with nothing changed since, is tried again.
        pins.save()
        library.save()
        let landed = Disk.drain(since: mark)
        let gone = sessionFile(of: id).map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
        if landed && gone { settings.deletingSpaces.remove(id) }
    }

    // MARK: - pins (Pins.swift)

    /// The tab's page pinned in its space, the tab kept as it is: last among
    /// its pins, a square or a row.
    func pin(_ tab: Tab, listed: Bool = false) {
        guard canPin(tab), case .space(let space) = tab.owner, let url = tab.url else { return }
        let def = PinDef(id: UUID(), letter: PinDef.letter(for: url), home: url.absoluteString, title: tab.title,
                         listed: listed ? true : nil)
        pins.add(def, in: space)
        tab.pin = def.id
        save()
    }

    /// Not a pin any more, anywhere it was — every space, for a shared one —
    /// the page kept in front as an ordinary tab.
    func unpin(_ tab: Tab) {
        guard let id = tab.pin else { return }
        tab.pin = nil
        pins.remove(id)
        pinsChanged()
    }

    /// A pin closed: its page let go, the pin kept, back at its home when it
    /// is next shown if pins go home, else where it was. In front, the tab
    /// beside it takes its place, or an empty one.
    private func rest(_ tab: Tab, at index: Int) {
        guard let id = tab.pin else { return }
        let wasActive = tab.id == activeID
        let resting = makeTab(tab.owner)
        resting.pin = id
        let home = pins.def(id)?.homeURL
        if let url = settings.pinsGoHome ? home ?? tab.url : tab.url ?? home {
            resting.restore(url: url, title: tab.title)
            resting.restsAtHome = Browser.samePage(url, home)
        }
        tabs[index] = resting
        tab.close()
        if wasActive {
            if let next = looseTabs.last { activeID = next.id } else { newTab() }
        }
        save()
    }

    /// Back to the page it was pinned at.
    func goHome(_ tab: Tab) {
        guard let home = pinDef(of: tab)?.homeURL, !Browser.samePage(home, tab.url) else { return }
        tab.load(home)
    }

    /// The page it is on, its home from now on.
    func setHome(_ tab: Tab) {
        guard let id = tab.pin, let url = tab.url, Continuity.page(url) != nil else { return }
        pins.edit(id) { $0.home = url.absoluteString }
    }

    /// Open as New Tab: a pin taken somewhere else gives that page to an
    /// ordinary tab and is back at its home, fresh; one at its home opens
    /// its page in a new tab.
    func openAsNewTab(_ tab: Tab) {
        guard let id = tab.pin, let def = pins.def(id), let home = def.homeURL else { return }
        guard !Browser.samePage(home, tab.url) else {
            newTab(url: home)
            return
        }
        tab.pin = nil
        reconcilePins(in: tab.owner)
        save()
    }

    /// Its name, letter, or whether it is a row, as `edit` leaves them.
    func editPin(_ tab: Tab, _ edit: (inout PinDef) -> Void) {
        guard let id = tab.pin else { return }
        pins.edit(id, edit)
    }

    /// Shown by every space from now on, each with a tab of its own for it.
    func showEverywhere(_ tab: Tab) {
        guard let id = tab.pin, case .space(let space) = tab.owner else { return }
        pins.share(id, from: space)
        pinsChanged()
    }

    /// A shared pin kept by this space alone: the others' tabs for it are
    /// let go — or kept, as ordinary tabs, if they were taken elsewhere.
    func keepHere(_ tab: Tab) {
        guard let id = tab.pin, case .space(let space) = tab.owner else { return }
        pins.keep(id, in: space)
        pinsChanged()
    }

    /// The space in front's pins in a new order.
    func movePins(_ order: [UUID]) {
        pins.reorder(order, in: spaceID)
    }

    /// The pins changed — here or on another device: every space's tabs
    /// made to match them.
    func pinsChanged() {
        for space in spaces { reconcilePins(in: .space(space.id)) }
        save()
    }

    private func reconcilePins(in space: UUID) { reconcilePins(in: .space(space)) }

    /// A space's tabs made to match its pins: a tab for each it shows, made
    /// only once shown; a tab whose pin it no longer has an ordinary tab
    /// again — let go instead if it was only resting, out of sight.
    private func reconcilePins(in owner: TabOwner) {
        guard case .space(let space) = owner else { return }
        var seen = Set<UUID>()
        var letGo: [Tab] = []
        for tab in tabs where tab.owner == owner {
            guard let id = tab.pin else { continue }
            guard pins.has(id, in: space), seen.insert(id).inserted else {
                tab.pin = nil
                if tab.restsAtHome && !tab.isBuilt && tab.id != activeID { letGo.append(tab) }
                continue
            }
        }
        if !letGo.isEmpty {
            let gone = Set(letGo.map(\.id))
            tabs.removeAll { gone.contains($0.id) }
            letGo.forEach { $0.close() }
        }
        for def in pins.row(in: space, showingShared: settings.usesSpaces) where !seen.contains(def.id) {
            guard let home = def.homeURL else { continue }
            let tab = makeTab(owner)
            tab.pin = def.id
            tab.restore(url: home, title: def.title)
            tab.restsAtHome = true
            insert(tab, after: nil)
        }
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

    // MARK: - the sessions

    /// What is written for a space: its tabs' addresses and titles and which
    /// one was in front. A private tab is never written anywhere.
    nonisolated struct Session: Codable, Equatable, Sendable {
        nonisolated struct Entry: Codable, Equatable, Sendable {
            var url: String
            var title: String
            /// The pin it is (Pins.swift); nil for an ordinary tab, and in
            /// every file from before pins.
            var pinID: UUID?
        }
        var tabs: [Entry]
        var active: Int?
    }

    /// The space in front's session.
    var session: Session { session(of: spaceID) }

    func session(of space: UUID) -> Session { session(of: space, from: tabs.filter { $0.owner == .space(space) }) }

    /// `row`: the space's tabs, in their order.
    private func session(of space: UUID, from row: [Tab]) -> Session {
        let kept = row.filter { Continuity.page($0.url) != nil }
        let entries = kept.compactMap { tab in tab.url.map { Session.Entry(url: $0.absoluteString, title: tab.title, pinID: tab.pin) } }
        let front = selections[space].flatMap { id in kept.firstIndex { $0.id == id } }
        return Session(tabs: entries, active: front)
    }

    /// Where a space's tabs are kept: Personal's in the file there always
    /// was, each other's beside it.
    private func sessionFile(of space: UUID) -> URL? {
        sessionFile.map { $0.deletingLastPathComponent().appendingPathComponent(SpaceSessionFile.name(for: space, stem: "tabs")) }
    }

    /// Every space whose tabs changed, written.
    private func save() {
        changed?()
        guard sessionFile != nil else { return }
        // Each space's tabs found in one pass, not one per space.
        var rows: [UUID: [Tab]] = [:]
        for tab in tabs { if case .space(let id) = tab.owner { rows[id, default: []].append(tab) } }
        for space in spaces {
            let snapshot = session(of: space.id, from: rows[space.id] ?? [])
            guard written[space.id] != snapshot, let file = sessionFile(of: space.id) else { continue }
            written[space.id] = snapshot
            Disk.write(file) { try? JSONEncoder().encode(snapshot) }
        }
    }

    /// A deleted space's file gone, and any write of it still waiting with it.
    private func forgetSession(of space: UUID) {
        written[space] = nil
        if let file = sessionFile(of: space) { Disk.remove(file) }
    }

    /// Every space's tabs as they were left, each page made only once shown.
    private func restore() {
        for space in spaces {
            restore(space.id)
            reconcilePins(in: space.id)
        }
        let row = spaceTabs
        activeID = selections[spaceID].flatMap { id in row.first { $0.id == id } }?.id ?? row.last?.id
    }

    private func restore(_ space: UUID) {
        guard let file = sessionFile(of: space), let data = try? Data(contentsOf: file) else { return }
        guard let read = try? JSONDecoder().decode(Session.self, from: data) else {
            Store.quarantine(file)
            return
        }
        let owner = TabOwner.space(space)
        for (index, entry) in read.tabs.enumerated() {
            guard var url = URL(string: entry.url) else { continue }
            let tab = makeTab(owner)
            // A pin still the space's, back at its home if pins go home.
            if let id = entry.pinID, pins.has(id, in: space),
               !tabs.contains(where: { $0.owner == owner && $0.pin == id }) {
                tab.pin = id
                let home = pins.def(id)?.homeURL
                if settings.pinsGoHome, let home { url = home }
                tab.restsAtHome = Browser.samePage(url, home)
            }
            tab.restore(url: url, title: entry.title)
            insert(tab, after: nil)
            // The one in front by its place among what was written, before
            // anything that no longer reads was dropped.
            if index == read.active { selections[space] = tab.id }
        }
        // A private or empty tab was in front, and no session keeps those:
        // the last that came back is, never none.
        if selections[space] == nil { selections[space] = tabs.last { $0.owner == owner }?.id }
        written[space] = session(of: space)
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
