import Combine
import EdenCore
import Observation
import UIKit

// Sync with your other devices through iCloud: Eden on your Macs, iPhone and
// iPad, in your own private CloudKit database (CloudSync and CloudKitStore,
// in EdenCore, which the Mac app shares; see its Sync.swift). On unless
// turned off in Settings. Never in a test run (EDEN_PROBE): its iCloud is
// not its to change.
//
// What this device syncs, in the scopes the Mac uses:
//   "app": the search engine (and the Mac's custom one) and the blocker,
//     as the Mac's own settings items, and this device's open tabs, one item
//     written by it alone (DeviceTabs) — never a private tab.
//   "profile-<Personal>": the bookmarks, as the same tree the Mac keeps, and
//     history.
// What it doesn't keep — the Mac's spaces, pins and its other settings — it
// carries along untouched: only what this device understands can be found
// missing here and deleted everywhere.
//
// A pass runs a moment after a tab, a bookmark, a visit or a setting that
// syncs changes, when another device changes something (a silent push),
// when Eden comes forward or goes to the background, and every two minutes
// while it is in front.

@Observable
final class Syncing {
    /// Where the last pass got to, for Settings.
    private(set) var status: CloudSync.Status = .idle
    /// Your other devices' open tabs, newest first.
    private(set) var otherTabs: [DeviceTabs] = []

    @ObservationIgnored private unowned let browser: Browser
    @ObservationIgnored private var engine: CloudSync?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var bag: Set<AnyCancellable> = []
    /// The tabs last offered (see `openTabs`).
    @ObservationIgnored private var offered: DeviceTabs?

    static let deviceKey = "sync.device"
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
    static var possible: Bool { !Store.testing && CloudKitStore.entitled }

    // MARK: - on and off

    /// At launch: carries on if it is on.
    func start() {
        guard on, engine == nil, Syncing.possible else { return }
        let made = CloudSync(store: CloudKitStore(), device: device, file: Store.file("cloud-sync.json"))
        made.changed = { [weak self] status in self?.status = status }
        engine = made
        browser.changed = { [weak self] in self?.schedule() }
        browser.bookmarks.saved = { [weak self] in self?.schedule() }
        browser.settings.changed = { [weak self] in self?.schedule() }
        browser.history.recentChanges.sink { [weak self] in self?.schedule() }.store(in: &bag)
        UIApplication.shared.registerForRemoteNotifications()
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
        pending?.cancel()
        pending = nil
        timer?.invalidate()
        timer = nil
        bag.removeAll()
        browser.changed = nil
        browser.bookmarks.saved = nil
        browser.settings.changed = nil
        engine?.forget()
        engine = nil
        status = .idle
        otherTabs = []
    }

    /// The app came forward or went back.
    func active(_ now: Bool) {
        guard engine != nil else { return }
        timer?.invalidate()
        timer = nil
        if now {
            timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule(after: 0) }
            }
        }
        schedule(after: 0)
    }

    /// A pass a moment from now; anything else that changes meanwhile joins it.
    func schedule(after delay: TimeInterval = 2) {
        guard engine != nil else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.pass()
        }
    }

    // MARK: - a pass

    func pass() async {
        guard let engine else { return }
        let history = browser.history
        // A history still being read would look empty, and what the other
        // devices have would then look deleted here: the pass waits for it.
        while !history.isLoaded {
            // Cancelled — scheduled again, or sync turned off — it ends here.
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
        guard !Task.isCancelled, self.engine === engine else { return }
        await engine.pass([appScope(), personalScope()])
    }

    private func appScope() -> CloudScope {
        let own = SyncItems.tabsKey(device)
        return CloudScope(name: "app", current: { [unowned self] agreed in
            var items = browser.settings.syncItems
            items.merge(SyncItems.tabs(openTabs(agreed: agreed[own]))) { mine, _ in mine }
            return items
        }, apply: { [unowned self] live in
            let blocked = browser.settings.blocks
            browser.settings.applySynced(live)
            if browser.settings.blocks != blocked { browser.applyBlocking() }
            otherTabs = SyncItems.otherTabs(live, except: device, now: Date().timeIntervalSince1970)
        }, understood: { key, _ in
            Settings.synced.contains(key) || key == own
        })
    }

    private func personalScope() -> CloudScope {
        let history = browser.history
        let bookmarks = browser.bookmarks
        return CloudScope(name: Syncing.personal, current: { _ in
            var items = SyncItems.bookmarks(bookmarks.roots)
            items.merge(history.syncItems()) { mine, _ in mine }
            return items
        }, apply: { live in
            bookmarks.adopt(SyncItems.applyBookmarks(live))
            history.applySynced(live)
        }, understood: { key, text in
            if key.hasPrefix("bm:") || key.hasPrefix("kids:") { return SyncItems.understood(key, text) }
            return history.understands(key)
        })
    }

    /// This device's open tabs as its other devices see them. Stamped afresh
    /// only when they changed, or once a day so they aren't taken for a
    /// device gone quiet: otherwise every pass would save them. Asked twice
    /// in a pass (CloudSync reads the items again before applying), the
    /// answer is the same.
    private func openTabs(agreed: String?) -> DeviceTabs {
        var seen = Set<String>()
        let pages = browser.ordinaryTabs.compactMap { tab -> DeviceTabs.Page? in
            guard let url = Continuity.page(tab.url), seen.insert(url.absoluteString).inserted else { return nil }
            return DeviceTabs.Page(url: url.absoluteString, title: tab.title)
        }
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let now = Date().timeIntervalSince1970
        var mine = DeviceTabs(device: device, name: UIDevice.current.name, kind: pad ? .ipad : .iphone,
                              tabs: Array(pages.prefix(200)), at: now)
        for before in [agreed.flatMap { SyncMerge.value(DeviceTabs.self, $0) }, offered].compactMap({ $0 })
            where before.tabs == mine.tabs && before.name == mine.name && now - before.at < 24 * 60 * 60 {
            mine.at = before.at
            break
        }
        offered = mine
        return mine
    }

    // MARK: - for Settings

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

/// Sync started as the app launches, whether to show its window or, woken
/// by CloudKit's silent push in the background, without one; and that push
/// answered with a pass, the system told once it is done (Syncing).
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set by the app as it makes its browser, before launching finishes.
    static var syncing: Syncing?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppDelegate.syncing?.start()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        guard let syncing = AppDelegate.syncing, syncing.on else { return .noData }
        syncing.start()
        await syncing.pass()
        return .newData
    }
}
