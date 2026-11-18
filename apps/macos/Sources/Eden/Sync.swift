import EdenCore
import AppKit
import Combine
import SwiftUI
import SystemConfiguration

// Sync with your other devices through iCloud: Eden on your Macs, iPhone
// and iPad, in your own private CloudKit database (CloudSync and
// CloudKitStore, in EdenCore, which the iOS app shares). No server of ours,
// no account but your Apple Account.
//
// On unless turned off (Settings › General › Sync with iCloud), on a build
// signed with iCloud: build.sh embeds the provisioning profile that grants
// it. A build without one says so in Settings and never touches CloudKit,
// which would end the app. Never in a test world (EDEN_PROBE), which isn't
// your Mac's Eden: its iCloud is not its to change.
//
// The scopes, each merged on its own (SyncMerge for the rules):
//   "app": the settings listed in SyncSettings, and each device's open tabs,
//     one item per device (DeviceTabs), written by that device alone — here
//     the ordinary tabs of the Personal profile's windows, never a shy
//     (private) tab, a pop-up's, one the bench drives, or a page that isn't
//     on the web.
//   "profile-<id>": a profile's spaces (name, colour, icon, order, whether it
//     has sign-ins of its own — never the sign-ins themselves, its cookies,
//     tabs or downloads folder), pins, bookmarks and history. Personal is
//     the same profile on every device; the iPhone and iPad have only it.
// What never syncs: passwords, cookies and site data, tab groups, private
// windows, extensions, the downloads folder, window sizes.
//
// A pass runs a moment after anything synced changes here, when another
// device changes something (a silent push, Links), when Eden comes forward
// or goes back, and every two minutes. With nothing new, a pass is one small
// request to iCloud.

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
        coded("pins.list", \.listsPins),
        coded("pins.home", \.pinsGoHome),
        raw("tabs.close.after", \.tabLife),
        raw("tabs.newPlace", \.newTabPlace),
        coded("tabs.shortcuts", \.showsTabShortcuts),
        coded("shield", \.shielded),
        coded("privacy.clickIDs", \.removesClickIDs),
        coded("privacy.gpc", \.sendsPrivacySignal),
        coded("bookmarks.bar", \.bookmarksBar),
        coded("quit.confirm", \.confirmsQuit),
    ]

    /// Their keys, readable anywhere (SyncItems.understood).
    static let known = SyncItems.knownSettings

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
    @Published private(set) var on: Bool
    /// Where the last pass got to, for Settings.
    @Published private(set) var status: CloudSync.Status = .idle
    /// Your other devices' open tabs, newest first, for the History menu.
    @Published private(set) var otherTabs: [DeviceTabs] = []

    nonisolated static let onKey = "sync.icloud"
    nonisolated static let deviceKey = "sync.device"

    /// This Mac's id in iCloud: made once, kept with the settings.
    let device: String = {
        if let kept = Store.settings.string(forKey: Sync.deviceKey), !kept.isEmpty { return kept }
        let made = UUID().uuidString
        Store.settings.set(made, forKey: Sync.deviceKey)
        return made
    }()

    private var engine: CloudSync?
    private var bag: Set<AnyCancellable> = []
    private var historyBag: [UUID: AnyCancellable] = [:]
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    /// The pass under way, cancelled when sync is turned off.
    private var passing: Task<Void, Never>?

    private init() {
        on = Store.settings.object(forKey: Sync.onKey) as? Bool ?? true
    }

    /// Whether this Eden may sync at all: signed with iCloud, and not a test
    /// world's.
    static var possible: Bool { !Store.testing && CloudKitStore.entitled }

    // MARK: - on and off

    /// At launch: carries on if it is on.
    func start() {
        guard on, engine == nil else { return }
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
        stop()
        passing?.cancel()
        passing = nil
        engine?.forget()
        engine = nil
        Store.settings.set(false, forKey: Sync.onKey)
        on = false
        status = .idle
        otherTabs = []
    }

    private func begin() {
        guard Sync.possible else {
            status = Store.testing ? .idle : .problem(.notEntitled)
            return
        }
        if engine == nil {
            let made = CloudSync(store: CloudKitStore(), device: device, file: Store.file("cloud-sync.json"))
            made.changed = { [weak self] status in self?.status = status }
            engine = made
        }
        let poke: (Notification) -> Void = { [weak self] _ in self?.schedule() }
        for name in [Spaces.changed, Pins.changed, Bookmarks.saved, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            NotificationCenter.default.publisher(for: name).sink(receiveValue: poke).store(in: &bag)
        }
        Shared.prefs.objectWillChange.sink { [weak self] in self?.schedule() }.store(in: &bag)
        Profiles.shared.$list.sink { [weak self] _ in self?.schedule() }.store(in: &bag)
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 0) }
        }
        // Another device's change arrives as a silent push (Links).
        NSApp.registerForRemoteNotifications()
        schedule(after: 1)
    }

    private func stop() {
        bag.removeAll()
        historyBag.removeAll()
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
    }

    /// A pass a moment from now; anything else that changes meanwhile joins it.
    func schedule(after delay: TimeInterval = 3) {
        guard on, engine != nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.pass() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    nonisolated static func scope(_ profile: UUID) -> String { "profile-" + profile.uuidString }

    // MARK: - a pass

    func pass() {
        guard on, let engine else { return }
        pending = nil
        let profiles = Profiles.shared.list
        // A history still being read would look empty, and what the other
        // devices have would then look deleted here: the pass waits for it.
        let histories = profiles.map { Profiles.history($0.id) }
        guard histories.allSatisfy(\.isLoaded) else { return schedule(after: 1) }
        for (profile, history) in zip(profiles, histories) where historyBag[profile.id] == nil {
            historyBag[profile.id] = history.recentChanges.sink { [weak self] in self?.schedule() }
        }
        var scopes = [appScope()]
        for (profile, history) in zip(profiles, histories) {
            scopes.append(CloudScope(name: Sync.scope(profile.id), current: { agreed in
                var items = Sync.items(of: profile.id, base: agreed)
                items.merge(history.syncItems()) { mine, _ in mine }
                return items
            }, apply: { live in
                Sync.apply(live, to: profile)
                history.applySynced(live)
            }, understood: { key, text in
                SyncItems.understood(key, text) || history.understands(key)
            }))
        }
        passing = Task {
            guard !Task.isCancelled else { return }
            await engine.pass(scopes)
        }
    }

    /// The settings, and every device's open tabs: only this Mac's own are
    /// this Mac's to change or delete.
    private func appScope() -> CloudScope {
        let prefs = Shared.prefs
        let device = device
        let own = SyncItems.tabsKey(device)
        return CloudScope(name: "app", current: { agreed in
            var items = SyncSettings.items(prefs)
            items.merge(SyncItems.tabs(Sync.openTabs(device: device, agreed: agreed[own]))) { mine, _ in mine }
            return items
        }, apply: { [weak self] live in
            SyncSettings.apply(live, to: prefs)
            self?.otherTabs = SyncItems.otherTabs(live, except: device, now: Date().timeIntervalSince1970)
        }, understood: { key, text in
            SyncItems.understood(key, text) || key == own
        })
    }

    /// The tabs last offered, and when they were first: asked twice in a
    /// pass (CloudSync reads the items again before applying), the answer is
    /// the same.
    private static var offered: DeviceTabs?

    /// This Mac's open tabs as its other devices see them. Stamped afresh
    /// only when they changed, or once a day so they aren't taken for a Mac
    /// gone quiet: otherwise every pass would save them.
    static func openTabs(device: String, agreed: String?) -> DeviceTabs {
        var seen = Set<String>()
        var pages: [DeviceTabs.Page] = []
        for browser in Browsers.all where browser.profileID == Profile.personalID && !browser.isPopup {
            for tab in browser.tabs + browser.parkedTabs where !tab.shy && !tab.bench {
                guard let url = Continuity.page(tab.restAddress), seen.insert(url.absoluteString).inserted else { continue }
                let title = tab.name.flatMap { $0.isEmpty ? nil : $0 } ?? tab.title
                pages.append(DeviceTabs.Page(url: url.absoluteString, title: title))
            }
        }
        let now = Date().timeIntervalSince1970
        var mine = DeviceTabs(device: device, name: macName, kind: .mac, tabs: Array(pages.prefix(200)), at: now)
        for before in [agreed.flatMap { SyncMerge.value(DeviceTabs.self, $0) }, offered].compactMap({ $0 })
            where before.tabs == mine.tabs && before.name == mine.name && now - before.at < 24 * 60 * 60 {
            mine.at = before.at
            break
        }
        offered = mine
        return mine
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

/// History › Tabs on Other Devices: each device with tabs open, newest
/// first, a submenu of its tabs. Nothing while sync is off or no other
/// device has any.
struct OtherTabsMenu: View {
    @ObservedObject private var sync = Sync.shared
    let browser: Browser

    var body: some View {
        if sync.on, !sync.otherTabs.isEmpty {
            Section("Tabs on Other Devices") {
                ForEach(sync.otherTabs, id: \.device) { device in
                    Menu(device.name) {
                        ForEach(Array(device.tabs.prefix(60).enumerated()), id: \.offset) { _, page in
                            if let url = URL(string: page.url) {
                                Button {
                                    browser.open(url, foreground: true)
                                } label: {
                                    MenuLine(title: page.title.isEmpty ? Address.pretty(url) : page.title, url: url)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
