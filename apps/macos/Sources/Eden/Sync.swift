import EdenCore
import AppKit
import Combine
import SwiftUI
import SystemConfiguration
import os

// Sync with your other devices through iCloud: Eden on your Macs, iPhone
// and iPad, in your own private CloudKit database. The engine is EdenCore's
// (CloudSync over Apple's CKSyncEngine, shared with the iOS app); this file
// is the Mac's side of it: its kinds of data as scopes, when they changed,
// and the switch.
//
// On unless turned off (Settings › General › Sync with iCloud), on a build
// signed with iCloud: build.sh embeds the provisioning profile that grants
// it. A build without one says so in Settings and never touches CloudKit,
// which would end the app. Never in a test world (EDEN_PROBE), which isn't
// your Mac's Eden: its iCloud is not its to change.
//
// The scopes, each merged on its own (SyncMerge for the rules):
//   "app" (AppScope): the settings listed in SyncSettings, and each
//     device's open tabs, one item per device (DeviceTabs), written by that
//     device alone — here the ordinary tabs of the Personal profile's
//     windows, never a shy (private) tab, a pop-up's, one the bench drives,
//     or a page that isn't on the web.
//   "profile-<id>" (ProfileScope): a profile's spaces (name, colour, icon,
//     order, whether it has sign-ins of its own — never the sign-ins
//     themselves, its cookies, tabs or downloads folder), pins, bookmarks
//     and history. Personal is the same profile on every device; the iPhone
//     and iPad have only it.
// What never syncs: passwords, cookies and site data, tab groups, private
// windows, extensions, the downloads folder, window sizes.
//
// When: CKSyncEngine sends what changed here and fetches what changed
// elsewhere on its own schedule (with a push from iCloud when another
// device saves). Eden adds a capture a moment after anything synced
// changes here — spaces, pins, bookmarks, settings, history, a window's
// tabs — and a fetch when it comes forward and every five minutes while it
// is in front.

enum SyncSettings {
    struct Setting {
        let key: String
        let read: @MainActor (Preferences) -> String?
        let write: @MainActor (Preferences, String) -> Void
    }

    /// The settings that follow you: how Eden looks and behaves, not what
    /// belongs to this Mac (folders, window sizes, passwords, extensions).
    @MainActor static let all: [Setting] = [
        raw("look", \.look),
        raw("glyph", \.glyph),
        raw("search.engine", \.engine),
        coded("search.custom", \.customEngine),
        coded("search.suggest", \.engineSuggests),
        coded("search.keywords", \.keywords),
        coded("spaces", \.usesSpaces),
        raw("tabs.close.after", \.tabLife),
        raw("tabs.newPlace", \.newTabPlace),
        coded("tabs.shortcuts", \.showsTabShortcuts),
        coded("shield", \.shielded),
        coded("privacy.clickIDs", \.removesClickIDs),
        coded("privacy.gpc", \.sendsPrivacySignal),
        coded("quit.confirm", \.confirmsQuit),
    ]

    /// Their keys, readable anywhere (SyncItems.understood).
    static let known = SyncItems.knownSettings

    /// Settings the Mac no longer has, pinned rows and pins going home being
    /// always on here (#6), that the iPhone still switches: carried for it
    /// as they are, never written or deleted by the Mac.
    static let carried: Set<String> = ["pins.list", "pins.home"]

    private static func coded<T: Codable & Equatable>(_ key: String, _ path: ReferenceWritableKeyPath<Preferences, T>) -> Setting {
        Setting(key: key, read: { SyncMerge.text($0[keyPath: path]) }, write: { prefs, text in
            guard let value = SyncMerge.value(T.self, text), prefs[keyPath: path] != value else { return }
            prefs[keyPath: path] = value
        })
    }

    private static func raw<T: RawRepresentable & Equatable>(_ key: String, _ path: ReferenceWritableKeyPath<Preferences, T>) -> Setting
        where T.RawValue: Codable {
        Setting(key: key, read: { SyncMerge.text($0[keyPath: path].rawValue) }, write: { prefs, text in
            guard let raw = SyncMerge.value(T.RawValue.self, text), let value = T(rawValue: raw),
                  prefs[keyPath: path] != value else { return }
            prefs[keyPath: path] = value
        })
    }

    @MainActor static func items(_ prefs: Preferences) -> [String: String] {
        var out: [String: String] = [:]
        for setting in all { out["set:" + setting.key] = setting.read(prefs) }
        return out
    }

    @MainActor static func apply(_ live: [String: String], to prefs: Preferences) {
        for setting in all {
            if let text = live["set:" + setting.key] { setting.write(prefs, text) }
        }
    }
}

@MainActor
final class Sync: ObservableObject {
    static let shared = Sync()

    /// Whether sync is on: the switch, on unless turned off.
    @Published private(set) var on: Bool { didSet { tellPresence() } }
    /// Where sync is, for Settings.
    @Published private(set) var status: CloudSync.Status = .idle
    /// Your other devices' open tabs, newest first, for the History menu.
    @Published private(set) var otherTabs: [DeviceTabs] = [] { didSet { tellPresence() } }
    /// Whether another device has a tab open, for the column (Elsewhere.swift).
    let presence = ElsewherePresence()

    private func tellPresence() { presence.set(on ? otherTabs.filter(\.hasTabs) : []) }

    /// Your other devices' open tabs, as offered here (Elsewhere): none while
    /// sync is off.
    var elsewhere: [DeviceTabs] { on ? otherTabs : [] }

    /// When Eden was last in use on this Mac, to the minute: what the other
    /// devices read to offer carrying on from it (DeviceTabs.seen).
    static var seen: Double?

    static func minute(_ time: Double) -> Double { (time / 60).rounded(.down) * 60 }

    nonisolated static let onKey = "sync.icloud"
    nonisolated static let deviceKey = "sync.device"
    /// What sync does, for Console (subsystem com.subhajit.eden.beta,
    /// category Sync): never an item's contents.
    nonisolated static let log = Logger(subsystem: "com.subhajit.eden.beta", category: "Sync")
    /// Posted when a window's tabs were written down (Browser.writeRow):
    /// this Mac's open tabs, to capture.
    nonisolated static let tabsChanged = Notification.Name("EdenSyncTabsChanged")

    /// This Mac's id in iCloud: made once, kept with the settings.
    let device: String = {
        if let kept = Store.settings.string(forKey: Sync.deviceKey), !kept.isEmpty { return kept }
        let made = UUID().uuidString
        Store.settings.set(made, forKey: Sync.deviceKey)
        return made
    }()

    private var cloud: CloudSync?
    private lazy var appScope = AppScope(sync: self)
    private var profileScopes: [UUID: ProfileScope] = [:]
    private var bag: Set<AnyCancellable> = []
    private var historyBag: [UUID: AnyCancellable] = [:]
    private var timer: Timer?

    private init() {
        on = Store.settings.object(forKey: Sync.onKey) as? Bool ?? true
    }

    /// Whether this Eden may sync at all: signed with iCloud, and not a test
    /// world's.
    static var possible: Bool { !Store.testing && CloudKitTransport.entitled }

    nonisolated static func scope(_ profile: UUID) -> String { "profile-" + profile.uuidString }

    // MARK: - on and off

    /// At launch: carries on if it is on.
    func start() {
        guard on, cloud == nil else { return }
        begin()
    }

    func turnOn() {
        Store.settings.set(true, forKey: Sync.onKey)
        on = true
        begin()
    }

    /// Off: what this Mac kept about syncing is forgotten, so turning it on
    /// again joins afresh, the other devices' items winning where both have
    /// one. What is in the browser stays as it is; what is in iCloud stays
    /// for your other devices.
    func turnOff() {
        end()
        // What it kept couldn't be deleted: said, rather than a clean stop.
        let forgotten = cloud?.stop(forgetting: true) ?? true
        cloud = nil
        Store.settings.set(false, forKey: Sync.onKey)
        on = false
        status = forgotten ? .idle : .problem(.unwritable)
        otherTabs = []
        heardTabs = []
        asks = [:]
        asked = []
        heardAsks = []
    }

    private func begin() {
        guard cloud == nil else { return }
        guard Sync.possible else {
            status = Store.testing ? .idle : .problem(.notEntitled)
            return
        }
        let made = CloudSync(transport: CloudKitTransport(), device: device,
                             store: SQLiteReplicaStore(url: Store.file("cloud.sqlite"),
                                                       formerReplica: Store.file("cloud-replica.json"),
                                                       formerBases: Store.file("cloud-sync.json")))
        made.changed = { [weak self] status in
            self?.status = status
            switch status {
            case .synced: Sync.log.info("synced")
            case .problem(let problem): Sync.log.error("sync failed: \(problem.sentence, privacy: .public)")
            default: break
            }
        }
        made.stoppedItself = { [weak self] problem in self?.stopped(by: problem) }
        cloud = made
        scopesChanged()

        let changed: (Notification) -> Void = { [weak self] _ in self?.cloud?.localChange() }
        for name in [Spaces.changed, Pins.changed, Bookmarks.saved, Sync.tabsChanged] {
            NotificationCenter.default.publisher(for: name).sink(receiveValue: changed).store(in: &bag)
        }
        // Said before the change: CloudSync captures a moment later.
        Shared.prefs.objectWillChange.sink { [weak self] in self?.cloud?.localChange() }.store(in: &bag)
        Profiles.shared.$list.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scopesChanged() } }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        // Put down: when, said now, so another device can offer to carry on.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                Sync.seen = Sync.minute(Date().timeIntervalSince1970)
                self?.cloud?.localChange()
            }.store(in: &bag)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if NSApp.isActive { self?.refresh() } }
        }
        // iCloud's push when another device changes something (Links, and
        // CKSyncEngine itself).
        NSApp.registerForRemoteNotifications()
        Task { await made.start() }
    }

    private func end() {
        bag.removeAll()
        historyBag.removeAll()
        timer?.invalidate()
        timer = nil
    }

    /// Eden's data deleted from iCloud: the switch turns off, and Settings says why.
    private func stopped(by problem: CloudProblem) {
        end()
        cloud = nil
        Store.settings.set(false, forKey: Sync.onKey)
        on = false
        otherTabs = []
        status = .problem(problem)
    }

    /// What changed elsewhere, fetched now.
    func refresh() {
        guard let cloud else { return }
        Task { await cloud.refresh() }
    }

    /// iCloud's push said another device changed something.
    func pushArrived() {
        Sync.log.info("push arrived")
        refresh()
    }

    /// The scopes, again: a profile made or deleted.
    private func scopesChanged() {
        let profiles = Profiles.shared.list
        var scopes: [SyncScope] = [appScope]
        for profile in profiles {
            let scope = profileScopes[profile.id] ?? ProfileScope(profile: profile)
            profileScopes[profile.id] = scope
            scopes.append(scope)
            if historyBag[profile.id] == nil {
                historyBag[profile.id] = scope.history.recentChanges.sink { [weak self] in self?.cloud?.localChange() }
            }
        }
        for gone in Set(profileScopes.keys).subtracting(profiles.map(\.id)) {
            profileScopes[gone] = nil
            historyBag[gone] = nil
        }
        cloud?.scopes = scopes
    }

    /// The other devices' tabs as last heard, before any page asked closed
    /// there is taken out.
    private var heardTabs: [DeviceTabs] = []
    /// Every device's asks among the items as last heard, by key: an ask
    /// still there still stands.
    private var heardAsks: Set<String> = []
    /// Asks of other devices, to be written at the next pass: written once,
    /// then only carried (SyncItems.ask).
    fileprivate private(set) var asks: [String: String] = [:]
    /// The pages asked closed or opened there, shown so in their device's
    /// list while the ask stands (Elsewhere.asAsked).
    private var asked: [Elsewhere.Asked] = []
    /// Asks of this Mac done, by key: its snapshot leaves them out, and
    /// they go everywhere (SyncItems.standingAsks).
    fileprivate private(set) var answered: Set<String> = []
    /// Asks of this Mac being done now, not taken up twice meanwhile.
    private var answering: Set<String> = []
    /// Asks of this Mac whose tabs didn't reach disk, waiting to be tried
    /// again.
    private var retries = AskRetries()

    /// One of another device's pages, closed there: asked of it through
    /// iCloud, and gone from its list here at once. Done there when it
    /// next syncs, if it is an Eden that knows how.
    func askToClose(_ page: DeviceTabs.Page, on device: String) {
        guard on, let url = URL(string: page.url) else { return }
        ask(SyncItems.ask(close: page.url, on: device, now: Date().timeIntervalSince1970),
            device: device, page: History.identity(for: url), opening: nil)
    }

    /// An ask written down to send, and its page shown as asked meanwhile.
    private func ask(_ item: [String: String], device: String, page: String, opening: DeviceTabs.Page?) {
        guard let key = item.keys.first else { return }
        asks.merge(item) { _, new in new }
        asked.append(Elsewhere.Asked(device: device, page: page, at: Date().timeIntervalSince1970, key: key, opening: opening))
        showOtherTabs(heardTabs)
        cloud?.localChange()
    }

    /// One of this Mac's tabs, opened on another device too: carried onto
    /// that device's group in the column. Asked of it through iCloud, as a
    /// close is, and in its list here at once; opened there, behind the page
    /// in front, when it next syncs. False for a tab the other devices
    /// aren't shown (Sync.page(of:in:)).
    @discardableResult
    func askToOpen(_ tab: Tab, in space: UUID, on device: String) -> Bool {
        guard on, let page = Sync.page(of: tab, in: space), let url = URL(string: page.url) else { return false }
        ask(SyncItems.ask(open: page, on: device, now: Date().timeIntervalSince1970),
            device: device, page: History.identity(for: url), opening: page)
        return true
    }

    /// After each pass: the asks written are only carried from now on; the
    /// asks of this Mac done; and the other devices' tabs shown.
    fileprivate func settled(_ live: [String: String]) {
        asks = asks.filter { live[$0.key] == nil }
        heardAsks = Set(live.keys.filter(SyncItems.isAsk))
        // Done and gone everywhere: nothing more to leave out.
        answered.formIntersection(heardAsks)
        retries.keep(heardAsks)
        answerAsks(in: live)
        showOtherTabs(SyncItems.otherTabs(live, except: device, now: Date().timeIntervalSince1970))
    }

    /// What other devices asked of this Mac, done after the pass: pages
    /// closed, as ⌘W closes them, and pages opened behind the one in front.
    /// Each ask counts as done — and goes everywhere at the next pass —
    /// only once its tabs have changed and are on disk (SyncItems.answer):
    /// until then it stands, and a quit or a crash in between leaves it to
    /// be done at the next launch. One that can't be done yet, a page sent
    /// with no window to open it in, waits for a pass with one.
    private func answerAsks(in live: [String: String]) {
        let now = Date().timeIntervalSince1970
        let waiting = answered.union(answering)
        let due = { (key: String) in !waiting.contains(key) && self.retries.ready(key, now: now) }
        let closing = SyncItems.closeAsks(live, on: device, now: now).filter { due($0.key) }
        let opening = SyncItems.openAsks(live, on: device, now: now).filter { due($0.key) }
        guard !closing.isEmpty || !opening.isEmpty else { return }
        answering.formUnion(closing.keys)
        answering.formUnion(opening.keys)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let windows = Browsers.all.filter { $0.profileID == Profile.personalID && !$0.isPopup }
            let target = windows.first(where: { $0 === Browsers.front }) ?? windows.first
            let pages = Set(closing.values.compactMap { URL(string: $0.url).map(History.identity(for:)) })
            var done = Set(closing.keys)
            if target != nil { done.formUnion(opening.keys) }
            let landed = SyncItems.answer({
                for browser in windows { browser.closeAsked(pages) }
                if let target {
                    for page in opening.values.sorted(by: { $0.at < $1.at }).map(\.page) { target.openSent(page) }
                }
            }, rewrite: {
                // Every row these windows hold, the spaces off screen too,
                // written now rather than at the session's own moment later.
                for browser in windows {
                    browser.writeSession(now: true)
                    for (space, row) in browser.parked { browser.writeSession(now: true, space: space, row: row) }
                }
            })
            self.answering.subtract(closing.keys)
            self.answering.subtract(opening.keys)
            guard landed else {
                self.retries.failed(done, now: Date().timeIntervalSince1970)
                return
            }
            guard !done.isEmpty else { return }
            self.retries.forget(done)
            self.answered.formUnion(done)
            self.cloud?.localChange()
        }
    }

    /// Your other devices' tabs as a test world has them, sync on or off
    /// with no iCloud behind it: what the column draws for them, and carries
    /// a tab onto. Test runs only.
    func pretend(_ tabs: [DeviceTabs], on: Bool) {
        guard Store.testing else { return }
        self.on = on
        asks = [:]
        asked = []
        heardAsks = []
        showOtherTabs(tabs)
    }

    private func showOtherTabs(_ tabs: [DeviceTabs]) {
        heardTabs = tabs
        let (shown, waiting) = Elsewhere.asAsked(tabs, asked: asked, standing: heardAsks.union(asks.keys),
                                                 now: Date().timeIntervalSince1970)
        asked = waiting
        if shown != otherTabs { otherTabs = shown }
    }

    /// The tabs last offered, and when they were first: asked twice in a
    /// pass (CloudSync reads the items again before applying), the answer is
    /// the same.
    private static var offered: DeviceTabs?

    /// This Mac's open tabs as its other devices see them: each page with
    /// its space, how far down it is read and whether as an article; the one
    /// in front; when Eden was last in use here; and what was closed a
    /// moment ago. Stamped afresh only when that changed, or once a day so
    /// they aren't taken for a Mac gone quiet: otherwise every pass would
    /// save them.
    static func openTabs(device: String, agreed: String?) -> DeviceTabs {
        var listed: [String: Int] = [:]
        var pages: [DeviceTabs.Page] = []
        var front: Int?
        let windows = Browsers.all.filter { $0.profileID == Profile.personalID && !$0.isPopup }
        for browser in windows {
            let rows = [(browser.spaceID, browser.tabs)] + browser.parked.map { ($0.key, $0.value.tabs) }
            for (space, row) in rows {
                for tab in row {
                    guard let page = page(of: tab, in: space) else { continue }
                    let inFront = browser === Browsers.front && space == browser.spaceID && tab.id == browser.activeID
                    // Each page once: the tab in front, when it is one of two.
                    if let at = listed[page.url] {
                        if inFront {
                            pages[at] = page
                            front = at
                        }
                        continue
                    }
                    guard pages.count < 200 else { continue }
                    listed[page.url] = pages.count
                    if inFront { front = pages.count }
                    pages.append(page)
                }
            }
        }
        let now = Date().timeIntervalSince1970
        if NSApp.isActive { seen = minute(now) }
        let ghosts = windows.flatMap(\.ghosts).map { ghost in
            DeviceTabs.Closed(url: ghost.url.absoluteString, title: ghost.title, space: ghost.space, at: ghost.at.timeIntervalSince1970)
        }
        let closed = DeviceTabs.recent(ghosts.filter { Continuity.page(URL(string: $0.url)) != nil }.sorted { $0.at < $1.at }, now: now)
        var mine = DeviceTabs(device: device, name: macName, kind: .mac, tabs: pages, at: now,
                              front: front, seen: seen, closed: closed.isEmpty ? nil : closed)
        for before in [agreed.flatMap { SyncMerge.value(DeviceTabs.self, $0) }, offered].compactMap({ $0 })
            where before.says(mine) && now - before.at < 24 * 60 * 60 {
            mine.at = before.at
            break
        }
        offered = mine
        return mine
    }

    /// A tab as the other devices are shown it: its page, title, space,
    /// how far down it is read and whether as an article. Nil for one they
    /// aren't shown: private, a bench tab, a page that can't be carried, or
    /// a pin at its home — the pin, which every device has already; gone on
    /// to another page, it is that page.
    static func page(of tab: Tab, in space: UUID) -> DeviceTabs.Page? {
        guard !tab.shy, !tab.bench, let url = Continuity.page(tab.restAddress) else { return nil }
        if tab.pin != nil, PinDef.atHome(tab.home, showing: url) { return nil }
        let title = tab.name.flatMap { $0.isEmpty ? nil : $0 } ?? tab.title
        return DeviceTabs.Page(url: url.absoluteString, title: title, space: space,
                               scroll: DeviceTabs.Page.scroll(tab.reading), reading: tab.reader ? true : nil)
    }

    nonisolated static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    // MARK: - a profile's things

    /// A profile's spaces, pins and bookmarks as items.
    static func items(of profile: UUID, base: [String: String]) -> [String: String] {
        let spaces = Spaces.read(profile: profile)
        var bySpace: [UUID: [PinDef]] = [:]
        for space in spaces {
            let defs = Pins.defs(space.id)
            if !defs.isEmpty { bySpace[space.id] = defs }
        }
        var out = SyncItems.spaces(spaces, base: base)
        out.merge(SyncItems.pins(bySpace: bySpace, shared: Pins.shared(profile), base: base)) { a, _ in a }
        out.merge(SyncItems.bookmarks(Profiles.bookmarks(profile).roots)) { a, _ in a }
        return out
    }

    /// The merged items made so: spaces first, so pins have their space.
    static func apply(_ live: [String: String], to profile: Profile) {
        let id = profile.id
        let home = id == Profile.personalID ? Space.firstID : profile.home
        let local = Spaces.read(profile: id)
        let spaces = SyncItems.applySpaces(live, to: local, profile: id, home: home)
        for gone in local where !spaces.contains(where: { $0.id == gone.id }) {
            removeSpace(gone, profile: id)
        }
        if spaces != Spaces.read(profile: id) {
            // The order is the one merged, wherever the home is in it.
            Store.settings.set(true, forKey: "spaces.orderKept")
            Spaces.write(spaces, profile: id)
        }

        var localPins: [UUID: [PinDef]] = [:]
        for space in spaces { localPins[space.id] = Pins.defs(space.id) }
        let pins = SyncItems.applyPins(live, spaces: spaces.map(\.id), local: localPins, localShared: Pins.shared(id))
        Pins.adopt(pins.bySpace, in: spaces.map(\.id), shared: pins.shared, profile: id)

        Profiles.bookmarks(id).adopt(SyncItems.applyBookmarks(live))
    }

    /// A space deleted on another device: as Delete Space does here — its tabs,
    /// its pins, and, for one with sign-ins of its own, those too.
    private static func removeSpace(_ space: Space, profile: UUID) {
        if let window = Browsers.all.first(where: { $0.profileID == profile && !$0.isPopup && $0.spaces.contains { $0.id == space.id } }) {
            window.deleteSpace(space.id)
            return
        }
        Spaces.write(Spaces.read(profile: profile).filter { $0.id != space.id }, profile: profile)
        Session.erase(space: space.id)
        Pins.forget(space.id)
        if space.sharesSignIns != true { Spaces.erase(space.id) }
    }

    // MARK: - for Settings

    /// Whether sync stopped, or can't run, with something to say.
    var hasProblem: Bool {
        if case .problem = status { return true }
        return false
    }

    /// Where sync is, in a line.
    var summary: String {
        switch status {
        case .idle: return Sync.possible ? "Starting\u{2026}" : CloudProblem.notEntitled.sentence
        case .syncing: return "Syncing\u{2026}"
        case .synced(let when):
            let ago = RelativeDateTimeFormatter().localizedString(for: when, relativeTo: Date())
            return "Synced \(ago)"
        case .problem(let problem): return problem.sentence
        }
    }
}

/// The settings that sync, and every device's open tabs: only this Mac's
/// own are this Mac's to change or delete.
@MainActor
private final class AppScope: SyncScope {
    let name = "app"
    var isReady: Bool { true }
    private unowned let sync: Sync
    private var own: String { SyncItems.tabsKey(sync.device) }

    init(sync: Sync) {
        self.sync = sync
    }

    func snapshot(agreed: [String: String]) -> [String: String] {
        var items = SyncSettings.items(Shared.prefs)
        items.merge(SyncItems.tabs(Sync.openTabs(device: sync.device, agreed: agreed[own]))) { mine, _ in mine }
        items.merge(sync.asks) { mine, _ in mine }
        // What other devices asked of this Mac and it hasn't done yet.
        items.merge(SyncItems.standingAsks(agreed, of: sync.device, answered: sync.answered,
                                           now: Date().timeIntervalSince1970)) { mine, _ in mine }
        return items
    }

    /// Asks of this Mac, to close a page or open one, are this Mac's too:
    /// never written by it, they are deleted everywhere once acted on.
    func owns(_ key: String, _ text: String) -> Bool {
        if key.hasPrefix("set:"), SyncSettings.carried.contains(String(key.dropFirst(4))) { return false }
        return SyncItems.understood(key, text) || key == own || SyncItems.asks(key, of: sync.device)
    }

    func apply(_ live: [String: String]) {
        SyncSettings.apply(live, to: Shared.prefs)
    }

    func settled(_ live: [String: String]) {
        sync.settled(live)
    }

    /// The preferences are written as they are set.
    func persist() {}
}

/// A profile's spaces, pins, bookmarks and history.
@MainActor
private final class ProfileScope: SyncScope {
    let profile: Profile
    let history: History
    let name: String

    init(profile: Profile) {
        self.profile = profile
        history = Profiles.history(profile.id)
        name = Sync.scope(profile.id)
    }

    /// A history still reading its file would look empty, and what the
    /// other devices have would then look deleted here.
    var isReady: Bool { history.isLoaded }

    func snapshot(agreed: [String: String]) -> [String: String] {
        var items = Sync.items(of: profile.id, base: agreed)
        items.merge(history.syncItems()) { mine, _ in mine }
        return items
    }

    func owns(_ key: String, _ text: String) -> Bool {
        SyncItems.understood(key, text) || history.understands(key)
    }

    func apply(_ live: [String: String]) {
        Sync.apply(live, to: profile)
        history.applySynced(live)
    }

    func persist() {
        history.flush()
        Disk.drain()
    }
}

/// History › Tabs on Other Devices: each device with tabs open, newest
/// first, a submenu of its tabs — under the spaces they are open in, while
/// spaces are on. Choosing one brings it here: to its tab if it is open
/// here already, else in its own space, as far down as it was read.
/// Nothing while sync is off or no other device has any.
struct OtherTabsMenu: View {
    @ObservedObject private var sync = Sync.shared
    let browser: Browser

    var body: some View {
        if sync.elsewhere.contains(where: \.hasTabs) {
            Section("Tabs on Other Devices") {
                ForEach(sync.elsewhere.filter(\.hasTabs), id: \.device) { device in
                    Menu(device.name) {
                        ForEach(Array(groups(device).enumerated()), id: \.offset) { _, group in
                            if let title = group.title {
                                Section(title) { pages(group.pages, of: device) }
                            } else {
                                pages(group.pages, of: device)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A device's first pages under this window's spaces (Browser.spaceGroups).
    private func groups(_ device: DeviceTabs) -> [(title: String?, pages: [DeviceTabs.Page])] {
        browser.spaceGroups(Array(device.tabs.prefix(60)))
    }

    @ViewBuilder private func pages(_ pages: [DeviceTabs.Page], of device: DeviceTabs) -> some View {
        ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
            if let url = URL(string: page.url) {
                Button {
                    browser.open(Elsewhere.Offer(device: device, page: page))
                } label: {
                    MenuLine(title: page.title.isEmpty ? Address.pretty(url) : page.title, url: url)
                }
            }
        }
    }
}
