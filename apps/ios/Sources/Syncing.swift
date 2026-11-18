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
//   "app" (AppScope): the search engine (and the Mac's custom one) and the
//     blocker, as the Mac's own settings items, and this device's open tabs,
//     one item written by it alone (DeviceTabs) — never a private tab.
//   "profile-<Personal>" (PersonalScope): the bookmarks, as the same tree
//     the Mac keeps, and history.
// What it doesn't keep — the Mac's spaces, pins and its other settings — it
// carries along untouched: only what this device owns can be found missing
// here and deleted everywhere.
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

    fileprivate func showOtherTabs(_ tabs: [DeviceTabs]) {
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

/// The search engine and the blocker, and every device's open tabs: only
/// this device's own are its to change or delete.
private final class AppScope: SyncScope {
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

    func snapshot(agreed: [String: String]) -> [String: String] {
        var items = browser.settings.syncItems
        items.merge(SyncItems.tabs(openTabs(agreed: agreed[own]))) { mine, _ in mine }
        return items
    }

    func owns(_ key: String, _ text: String) -> Bool {
        Settings.synced.contains(key) || key == own
    }

    func apply(_ live: [String: String]) {
        let blocked = browser.settings.blocks
        browser.settings.applySynced(live)
        if browser.settings.blocks != blocked { browser.applyBlocking() }
    }

    func settled(_ live: [String: String]) {
        syncing.showOtherTabs(SyncItems.otherTabs(live, except: syncing.device, now: Date().timeIntervalSince1970))
    }

    /// The settings are written as they are set.
    func persist() {}

    /// This device's open tabs as its other devices see them. Stamped afresh
    /// only when they changed, or once a day so they aren't taken for a
    /// device gone quiet: otherwise every capture would make an edit. Asked
    /// twice running, the answer is the same.
    private func openTabs(agreed: String?) -> DeviceTabs {
        var seen = Set<String>()
        let pages = browser.ordinaryTabs.compactMap { tab -> DeviceTabs.Page? in
            guard let url = Continuity.page(tab.url), seen.insert(url.absoluteString).inserted else { return nil }
            return DeviceTabs.Page(url: url.absoluteString, title: tab.title)
        }
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let now = Date().timeIntervalSince1970
        var mine = DeviceTabs(device: syncing.device, name: UIDevice.current.name, kind: pad ? .ipad : .iphone,
                              tabs: Array(pages.prefix(200)), at: now)
        for before in [agreed.flatMap { SyncMerge.value(DeviceTabs.self, $0) }, offered].compactMap({ $0 })
            where before.tabs == mine.tabs && before.name == mine.name && now - before.at < 24 * 60 * 60 {
            mine.at = before.at
            break
        }
        offered = mine
        return mine
    }
}

/// The Personal profile's bookmarks, as the Mac's tree, and history.
private final class PersonalScope: SyncScope {
    let name = Syncing.personal
    private unowned let browser: Browser

    init(browser: Browser) {
        self.browser = browser
    }

    /// A history still reading its file would look empty, and what the
    /// other devices have would then look deleted here.
    var isReady: Bool { browser.history.isLoaded }

    func snapshot(agreed: [String: String]) -> [String: String] {
        var items = SyncItems.bookmarks(browser.bookmarks.roots)
        items.merge(browser.history.syncItems()) { mine, _ in mine }
        return items
    }

    func owns(_ key: String, _ text: String) -> Bool {
        if key.hasPrefix("bm:") || key.hasPrefix("kids:") { return SyncItems.understood(key, text) }
        return browser.history.understands(key)
    }

    func apply(_ live: [String: String]) {
        browser.bookmarks.adopt(SyncItems.applyBookmarks(live))
        browser.history.applySynced(live)
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
