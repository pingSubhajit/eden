import Combine
import EdenCore
import Observation
import UIKit
import os

// Sync with your other devices through iCloud: Eden on your Macs, iPhone and
// iPad, in your own private CloudKit database. The engine is EdenCore's
// (CloudSync over Apple's CKSyncEngine, shared with the Mac app; see its
// Sync.swift); this is the iPhone and iPad's side of it. On unless turned
// off in Settings. Never in a test run (EDEN_PROBE): its iCloud is not its
// to change.
//
// What this device syncs, in the scopes the Mac uses:
//   "app" (AppScope): the search engine (and the Mac's custom one), the
//     blocker, and whether spaces, pinned rows and pins going home are on, as
//     the Mac's own settings items; and this device's open tabs, one item
//     written by it alone (DeviceTabs) — never a private tab.
//   "profile-<Personal>" (PersonalScope): the bookmarks, as the same tree
//     the Mac keeps, history, and Personal's spaces and pins.
// What it doesn't keep — the Mac's other settings, other profiles — it
// carries along untouched: only what this device owns can be found missing
// here and deleted everywhere.
//
// An Eden from before spaces carried the Mac's spaces, pins and their
// settings without keeping them. The first time this one syncs, each scope
// takes them over (SyncOwnership): this device's lists are first made what
// every device last agreed — what was made here since kept with them, a
// setting never chosen here taken as agreed — and only then does it speak
// for them. Otherwise its empty lists, and its defaults, would read as
// everything deleted and every choice undone, on every device.
//
// When: CKSyncEngine sends and fetches on its own schedule (with a push
// from iCloud when another device saves). Eden adds a capture a moment
// after a tab, a bookmark, a visit or a setting that syncs changes, and a
// fetch when it comes forward and every five minutes while it is in front.

@Observable
final class Syncing {
    /// Where sync is, for Settings.
    private(set) var status: CloudSync.Status = .idle
    /// Your other devices' open tabs, newest first.
    private(set) var otherTabs: [DeviceTabs] = []

    @ObservationIgnored private unowned let browser: Browser
    @ObservationIgnored private var cloud: CloudSync?
    /// When Eden was last in use here, to the minute: what the other devices
    /// read to offer carrying on from this one (DeviceTabs.seen).
    @ObservationIgnored fileprivate var seen: Double?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var bag: Set<AnyCancellable> = []

    static let deviceKey = "sync.device"
    /// What sync does, for Console (subsystem com.subhajit.eden.beta,
    /// category Sync): never an item's contents.
    static let log = Logger(subsystem: "com.subhajit.eden.beta", category: "Sync")
    static let personal = "profile-" + Space.personalProfileID.uuidString

    /// This device's id in iCloud: made once, kept with the settings.
    @ObservationIgnored let device: String = {
        if let kept = Store.settings.string(forKey: Syncing.deviceKey), !kept.isEmpty { return kept }
        let made = UUID().uuidString
        Store.settings.set(made, forKey: Syncing.deviceKey)
        return made
    }()

    init(browser: Browser) {
        self.browser = browser
    }

    var on: Bool { browser.settings.syncs }

    /// Whether this Eden may sync at all: never a test run's.
    static var possible: Bool { !Store.testing && CloudKitTransport.entitled }

    // MARK: - on and off

    /// At launch, whether to show the window or woken by a push without one:
    /// carries on if it is on.
    func start() {
        guard on, cloud == nil, Syncing.possible else { return }
        let made = CloudSync(transport: CloudKitTransport(), device: device,
                             store: SQLiteReplicaStore(url: Store.file("cloud.sqlite"),
                                                       formerReplica: Store.file("cloud-replica.json"),
                                                       formerBases: Store.file("cloud-sync.json")))
        made.changed = { [weak self] status in
            self?.status = status
            switch status {
            case .synced: Syncing.log.info("synced")
            case .problem(let problem): Syncing.log.error("sync failed: \(problem.sentence, privacy: .public)")
            default: break
            }
        }
        made.stoppedItself = { [weak self] problem in self?.stopped(by: problem) }
        made.scopes = [AppScope(syncing: self, browser: browser), PersonalScope(browser: browser)]
        cloud = made
        browser.changed = { [weak self] in self?.cloud?.localChange() }
        browser.bookmarks.saved = { [weak self] in self?.cloud?.localChange() }
        browser.settings.changed = { [weak self] in self?.cloud?.localChange() }
        browser.library.changed = { [weak self] in self?.cloud?.localChange() }
        browser.pins.changed = { [weak self] in self?.cloud?.localChange() }
        browser.history.recentChanges.sink { [weak self] in self?.cloud?.localChange() }.store(in: &bag)
        UIApplication.shared.registerForRemoteNotifications()
        Task { await made.start() }
        active(UIApplication.shared.applicationState == .active)
    }

    func turnOn() {
        browser.settings.syncs = true
        start()
    }

    /// Off: what this device kept about syncing is forgotten, so turning it
    /// on again joins afresh. What is on the device, and in iCloud for your
    /// other devices, stays.
    func turnOff() {
        browser.settings.syncs = false
        detach()
        // What it kept couldn't be deleted: said, rather than a clean stop.
        let forgotten = cloud?.stop(forgetting: true) ?? true
        cloud = nil
        status = forgotten ? .idle : .problem(.unwritable)
        otherTabs = []
    }

    private func detach() {
        timer?.invalidate()
        timer = nil
        bag.removeAll()
        browser.changed = nil
        browser.bookmarks.saved = nil
        browser.settings.changed = nil
        browser.library.changed = nil
        browser.pins.changed = nil
    }

    /// Eden's data deleted from iCloud: the switch turns off, and Settings says why.
    private func stopped(by problem: CloudProblem) {
        browser.settings.syncs = false
        detach()
        cloud = nil
        otherTabs = []
        status = .problem(problem)
    }

    /// The app came forward or went back: a fetch on coming forward, and one
    /// every five minutes while in front.
    func active(_ now: Bool) {
        timer?.invalidate()
        timer = nil
        // Put down: when, said now, so another device can offer to carry on.
        if !now, cloud != nil {
            seen = Syncing.minute(Date().timeIntervalSince1970)
            cloud?.localChange()
        }
        guard now, cloud != nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// What changed elsewhere, fetched now.
    func refresh() {
        guard let cloud else { return }
        Task { await cloud.refresh() }
    }

    /// iCloud's push said another device changed something.
    func pushArrived() async {
        Syncing.log.info("push arrived")
        await cloud?.refresh()
    }

    fileprivate static func minute(_ time: Double) -> Double { (time / 60).rounded(.down) * 60 }

    func showOtherTabs(_ tabs: [DeviceTabs]) {
        if tabs != otherTabs { otherTabs = tabs }
    }

    // MARK: - for Settings

    /// Whether sync stopped, or can't run, with something to say.
    var hasProblem: Bool {
        if case .problem = status { return true }
        return false
    }

    var summary: String {
        switch status {
        case .idle: return on ? "Starting\u{2026}" : "Off"
        case .syncing: return "Syncing\u{2026}"
        case .synced(let when):
            return "Synced " + RelativeDateTimeFormatter().localizedString(for: when, relativeTo: Date())
        case .problem(let problem): return problem.sentence
        }
    }
}

/// When a scope began speaking for what an Eden from before spaces carried:
/// the version it took over, kept per scope (Settings.ownership).
enum SyncOwnership {
    static let version = 1
}

/// The settings that sync, and every device's open tabs: only this device's
/// own are its to change or delete.
final class AppScope: SyncScope {
    let name = "app"
    var isReady: Bool { true }
    private unowned let syncing: Syncing
    private unowned let browser: Browser
    /// The tabs last offered (see `openTabs`).
    private var offered: DeviceTabs?
    private var own: String { SyncItems.tabsKey(syncing.device) }

    init(syncing: Syncing, browser: Browser) {
        self.syncing = syncing
        self.browser = browser
    }

    /// Whether it speaks for the spaces and pins settings yet.
    private var owned: Bool { browser.settings.ownership(of: name) >= SyncOwnership.version }

    func snapshot(agreed: [String: String]) -> [String: String] {
        if !owned { takeOwnership(of: agreed) }
        var items = browser.settings.syncItems
        if !owned { for key in Settings.spaceSettings { items[key] = nil } }
        items.merge(SyncItems.tabs(openTabs(agreed: agreed[own]))) { mine, _ in mine }
        return items
    }

    /// The spaces and pins settings taken over: each never chosen here is
    /// what every device agreed; one chosen here stays this device's choice.
    private func takeOwnership(of agreed: [String: String]) {
        let settings = browser.settings
        let taken = agreed.filter { Settings.spaceSettings.contains($0.key) && settings.untouched($0.key) }
        if !taken.isEmpty { apply(taken) }
        settings.setOwnership(SyncOwnership.version, of: name)
    }

    func owns(_ key: String, _ text: String) -> Bool {
        guard key != own else { return true }
        guard Settings.synced.contains(key) else { return false }
        return owned || !Settings.spaceSettings.contains(key)
    }

    func apply(_ live: [String: String]) {
        let settings = browser.settings
        let blocked = settings.blocks, spaces = settings.usesSpaces
        settings.applySynced(live)
        if settings.blocks != blocked { browser.applyBlocking() }
        if settings.usesSpaces != spaces {
            if !settings.usesSpaces { browser.leaveSpaces() }
            browser.pinsChanged()
        }
    }

    func settled(_ live: [String: String]) {
        syncing.showOtherTabs(SyncItems.otherTabs(live, except: syncing.device, now: Date().timeIntervalSince1970))
    }

    /// The settings are written as they are set.
    func persist() {}

    /// This device's open tabs as its other devices see them: each page with
    /// its space, how far down it is read and whether as an article; the one
    /// in front; when Eden was last in use here; and what was closed a
    /// moment ago. Stamped afresh only when that changed, or once a day so
    /// they aren't taken for a device gone quiet: otherwise every capture
    /// would make an edit. Asked twice running, the answer is the same.
    private func openTabs(agreed: String?) -> DeviceTabs {
        var listed: [String: Int] = [:]
        var front: Int?
        var pages: [DeviceTabs.Page] = []
        for tab in browser.ordinaryTabs {
            guard let url = Continuity.page(tab.url), case .space(let space) = tab.owner else { continue }
            // A pin at its home is the pin, which every device has already;
            // gone on to another page, it is that page.
            if PinDef.atHome(browser.pinDef(of: tab)?.homeURL, showing: url) { continue }
            let page = DeviceTabs.Page(url: url.absoluteString, title: tab.title, space: space,
                                       scroll: DeviceTabs.Page.scroll(tab.readFraction), reading: tab.isReading ? true : nil)
            let inFront = tab.id == browser.activeID
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
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let now = Date().timeIntervalSince1970
        if UIApplication.shared.applicationState == .active { syncing.seen = Syncing.minute(now) }
        let closed = DeviceTabs.recent(browser.recentlyClosed, now: now)
        var mine = DeviceTabs(device: syncing.device, name: UIDevice.current.name, kind: pad ? .ipad : .iphone,
                              tabs: pages, at: now, front: front, seen: syncing.seen, closed: closed.isEmpty ? nil : closed)
        for before in [agreed.flatMap { SyncMerge.value(DeviceTabs.self, $0) }, offered].compactMap({ $0 })
            where before.says(mine) && now - before.at < 24 * 60 * 60 {
            mine.at = before.at
            break
        }
        offered = mine
        return mine
    }
}

/// The Personal profile's bookmarks, as the Mac's tree, history, and its
/// spaces and pins.
final class PersonalScope: SyncScope {
    let name = Syncing.personal
    private unowned let browser: Browser
    /// The spaces whose pins it speaks for: those it has, and those every
    /// device last agreed on — so a space deleted here takes its pins with
    /// it everywhere. Set at each snapshot, which comes before what it owns
    /// is asked.
    private var spokenFor: Set<String> = []

    init(browser: Browser) {
        self.browser = browser
    }

    /// A history still reading its file would look empty, and what the
    /// other devices have would then look deleted here.
    var isReady: Bool { browser.history.isLoaded }

    /// Whether it speaks for the spaces and pins: taken over, and their
    /// files read. One that wouldn't read is taken over again from what
    /// every device agreed, never taken for nothing.
    private var owned: Bool {
        browser.settings.ownership(of: name) >= SyncOwnership.version
            && !browser.library.damaged && !browser.pins.damaged
    }

    func snapshot(agreed: [String: String]) -> [String: String] {
        if !owned { takeOwnership(of: agreed) }
        let agreedSpaces = agreed.keys.compactMap { key in key.hasPrefix("space:") ? String(key.dropFirst(6)) : nil }
        spokenFor = Set(browser.library.spaces.map(\.id.uuidString)).union(agreedSpaces)
        var items = SyncItems.bookmarks(browser.bookmarks.roots)
        items.merge(browser.history.syncItems()) { mine, _ in mine }
        guard owned else { return items }
        let spaces = browser.library.spaces
        items.merge(SyncItems.spaces(spaces, base: agreed)) { mine, _ in mine }
        let bySpace = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, browser.pins.catalog.pins(of: $0.id)) })
        items.merge(SyncItems.pins(bySpace: bySpace, shared: browser.pins.shared, base: agreed)) { mine, _ in mine }
        return items
    }

    /// The spaces and pins taken over: made what every device agreed, with
    /// whatever was made here since kept after them. Marked done only once
    /// it is all on disk, so a write that fails is tried again.
    private func takeOwnership(of agreed: [String: String]) {
        let mark = Disk.mark()
        let library = browser.library, pins = browser.pins
        let local = library.spaces
        let agreedSpaces = SyncItems.applySpaces(agreed, to: local, profile: Space.personalProfileID, home: Space.firstID)
        let known = Set(agreedSpaces.map(\.id))
        library.adopt(agreedSpaces + local.filter { !known.contains($0.id) })

        let ids = library.spaces.map(\.id)
        let catalog = pins.catalog
        let fromAgreed = SyncItems.applyPins(agreed, spaces: ids, local: catalog.bySpace, localShared: pins.shared)
        let agreedPins = Set((fromAgreed.bySpace.values.flatMap { $0 } + fromAgreed.shared).map(\.id))
        // This device's own pins after the agreed ones, but not a second of
        // a page they pin already: that one's tab carries on as theirs.
        let before = (bySpace: catalog.bySpace, shared: pins.shared)
        let shared = fromAgreed.shared + SyncItems.onePerPage(pins.shared.filter { !agreedPins.contains($0.id) },
                                                               besides: fromAgreed.shared)
        var bySpace = fromAgreed.bySpace
        for space in ids {
            let mine = SyncItems.onePerPage(catalog.pins(of: space).filter { !agreedPins.contains($0.id) },
                                            besides: (fromAgreed.bySpace[space] ?? []) + shared)
            if !mine.isEmpty { bySpace[space, default: []] += mine }
        }
        pins.adopt(bySpace, in: ids, shared: shared)
        browser.pinsMerged(SyncItems.handedOver(before: before.bySpace, beforeShared: before.shared,
                                                after: bySpace, afterShared: shared))
        browser.pinsChanged()
        // Both written now, changed or not: a write that failed last time,
        // with nothing changed since, must still be known to have landed.
        library.save()
        pins.save()
        guard Disk.drain(since: mark) else { return }
        library.recovered()
        pins.recovered()
        browser.settings.setOwnership(SyncOwnership.version, of: name)
    }

    func owns(_ key: String, _ text: String) -> Bool {
        if key.hasPrefix("bm:") || key.hasPrefix("kids:") { return SyncItems.understood(key, text) }
        if browser.history.understands(key) { return true }
        return owned && ownsSpaceOrPin(key, text)
    }

    /// Personal's spaces and pins, as this build reads them: a space, their
    /// order, and a pin, its title and each list's order — of a space it
    /// speaks for, or the shared ones. Anything else is carried.
    private func ownsSpaceOrPin(_ key: String, _ text: String) -> Bool {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        func list(_ space: String) -> Bool { space == SyncItems.sharedSpace || spokenFor.contains(space) }
        switch (parts.first, parts.count) {
        case ("space", 2):
            return UUID(uuidString: parts[1]) != nil && SyncMerge.value(SyncedSpace.self, text) != nil
        case ("order", 2) where key == SyncItems.spacesOrder:
            return SyncMerge.value([String].self, text) != nil
        case ("order", 3) where parts[1] == "pins":
            return list(parts[2]) && SyncMerge.value([String].self, text) != nil
        case ("pin", 3):
            return list(parts[1]) && UUID(uuidString: parts[2]) != nil && SyncMerge.value(SyncedPin.self, text) != nil
        case ("title", 3) where parts[1] == "pin":
            return UUID(uuidString: parts[2]) != nil && SyncMerge.value(String.self, text) != nil
        default:
            return false
        }
    }

    func apply(_ live: [String: String]) {
        browser.bookmarks.adopt(SyncItems.applyBookmarks(live))
        browser.history.applySynced(live)
        guard owned else { return }
        // The spaces first — one deleted elsewhere goes as one deleted here
        // does — then the pins of those left, then the tabs to match.
        let library = browser.library
        let spaces = SyncItems.applySpaces(live, to: library.spaces, profile: Space.personalProfileID, home: Space.firstID)
        for gone in library.spaces where !spaces.contains(where: { $0.id == gone.id }) {
            browser.spaceDeletedElsewhere(gone)
        }
        library.adopt(spaces)
        let ids = library.spaces.map(\.id)
        let before = (bySpace: browser.pins.catalog.bySpace, shared: browser.pins.shared)
        let pins = SyncItems.applyPins(live, spaces: ids, local: before.bySpace, localShared: before.shared)
        browser.pins.adopt(pins.bySpace, in: ids, shared: pins.shared)
        // Whichever device merged two pins of a page first, this one's tab
        // of the one given up carries on as the one kept.
        browser.pinsMerged(SyncItems.handedOver(before: before.bySpace, beforeShared: before.shared,
                                                after: pins.bySpace, afterShared: pins.shared))
        browser.pinsChanged()
    }

    func persist() {
        browser.history.flush()
        Disk.drain()
    }
}

/// Sync started as the app launches, whether to show its window or, woken
/// by iCloud's silent push in the background, without one; and that push
/// answered with a fetch, the system told once it is done (Syncing).
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set by the app as it makes its browser, before launching finishes.
    static var syncing: Syncing?

    func application(_ application: UIApplication,
                     willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        EdenApp.keepSessions(application)
        return true
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppDelegate.syncing?.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Syncing.log.info("registered for pushes (\(deviceToken.count, privacy: .public)-byte token)")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Syncing.log.error("couldn't register for pushes: \(error.localizedDescription, privacy: .public)")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        guard let syncing = AppDelegate.syncing, syncing.on else { return .noData }
        syncing.start()
        await syncing.pushArrived()
        return .newData
    }
}
