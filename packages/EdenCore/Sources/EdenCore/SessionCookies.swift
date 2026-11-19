import CryptoKit
import Foundation
import os
import Security
import WebKit

// A site's cookies without an expiry, its session's: a sign-in made without
// "keep me signed in", a cart, a payment on its way, YouTube's theatre mode.
// WebKit keeps them in memory alone, so every quit, update or crash took them
// and signed you out of what they held. Chrome, Arc and Dia keep them while
// they bring your tabs back, and so does Eden: each store's, written a moment
// after they change, sealed with a key that never leaves this device's
// keychain, and put back in its store before the first page of a run loads
// (whenRestored). Never a private tab's: its store is never kept here.
// Never synced: a session is this device's.

@MainActor
public final class SessionCookies: NSObject {
    public static let shared = SessionCookies(folder: Store.file("Session cookies"), key: sealingKey)

    /// The keychain's key; a test run's world seals with one of its own,
    /// never touching the keychain of the person running it.
    nonisolated private static func sealingKey() -> SymmetricKey? {
        Store.testing ? SymmetricKey(data: Data(repeating: 7, count: 32)) : Keychain.key()
    }

    /// Where the sealed files go, one a store.
    private let folder: URL
    /// The key they are sealed with; nil if the keychain won't give one,
    /// and then nothing is kept or put back.
    private let key: @Sendable () -> SymmetricKey?
    /// Where every write and removal of a file happens, one after another in
    /// the order asked: never on the main actor, where a keychain or a disk
    /// that stalls would stall the app, and the quit's own time limit with it.
    private let disk = DispatchQueue(label: "Eden session cookies", qos: .utility)
    /// How much has been asked of `disk` and isn't done yet, counted from
    /// the moment it is asked: a quit or a move to the background waits.
    private let onDisk = OSAllocatedUnfairLock(initialState: 0)

    /// A store kept here: its file, whether its cookies are back, what waits
    /// on them, and its writes. `generation` moves on whenever what was kept
    /// stops counting (its site data cleared, the store forgotten): a restore
    /// or a write begun before stops at its next step rather than putting
    /// back, or writing down, what was just taken.
    private final class Kept {
        let store: WKWebsiteDataStore
        let name: String
        var restored = false
        /// Its file couldn't be opened while the device's protected data
        /// was closed: read again once it opens (protectedData).
        var locked = false
        var waiting: [() -> Void] = []
        var generation = 0
        /// A write waiting for the cookies to settle.
        var settling: Task<Void, Never>?
        /// A write under way, until its file is on the disk.
        var writing: Task<Void, Never>?

        init(store: WKWebsiteDataStore, name: String) {
            self.store = store
            self.name = name
        }
    }

    /// By name: one store under it, however many times WebKit hands it out.
    private var kept: [String: Kept] = [:]

    /// Whether the device's protected files and keychain are open: closed on
    /// an iPhone started and not yet unlocked, where Eden may be launched in
    /// the background. A restore that can't read them then waits, its pages
    /// with it, rather than letting them load signed out. On iOS not known
    /// until the app says (protectedData), and waited on until then; a Mac's
    /// are open whenever Eden runs.
    private var protectedOpen: Bool? = {
        #if os(iOS)
        nil
        #else
        true
        #endif
    }()

    /// How long after a change its store is written: long enough for a page
    /// setting a dozen at once to be one write.
    private static let settle: Duration = .milliseconds(500)

    public init(folder: URL, key: @escaping @Sendable () -> SymmetricKey?) {
        self.folder = folder
        self.key = key
    }

    // MARK: - keeping a store

    /// `store`'s session cookies kept from now on, under its name: its
    /// identifier, or "default" for WebKit's own store (`name` for a test's
    /// store, which has neither). `restoring`: the ones kept last run put
    /// back in it, as the tabs are; a fresh start forgets them instead.
    /// Pages wait for them (whenRestored). A private tab's store, kept
    /// nowhere, is never kept here either.
    public func keep(_ store: WKWebsiteDataStore, as name: String? = nil, restoring: Bool) {
        guard let name = name ?? Self.name(of: store), kept[name] == nil else { return }
        let one = Kept(store: store, name: name)
        kept[name] = one
        store.httpCookieStore.add(self)
        guard restoring else {
            remove(file(name))
            return done(one)
        }
        restore(one)
    }

    /// The device's protected data opened or closed, as the iPhone app hears
    /// it. Opened, what waited for it is read now.
    public func protectedData(open: Bool) {
        protectedOpen = open
        guard open else { return }
        for one in kept.values where one.locked {
            one.locked = false
            restore(one)
        }
    }

    /// `one`'s cookies from its file, put back. Nothing kept, nothing to
    /// wait for: pages load as they always did. Otherwise read and opened on
    /// the disk's queue, never here, where a keychain that is slow to answer
    /// would hold up the launch. A file that won't open with the device's
    /// protected data closed waits for it; any other that won't is let go,
    /// so pages never wait on what can't come.
    private func restore(_ one: Kept, again: Bool = false) {
        let source = file(one.name)
        guard FileManager.default.fileExists(atPath: source.path) else { return done(one) }
        let generation = one.generation
        Task {
            let reading = await onDisk { [key] in Self.read(source, key: key) }
            guard one.generation == generation else { return }
            guard case .cookies(let cookies) = reading else {
                if protectedOpen != true { one.locked = true }
                // Opened while it was being read: once more.
                else if !again { restore(one, again: true) }
                else { done(one) }
                return
            }
            for cookie in cookies {
                guard one.generation == generation else { return }
                await one.store.httpCookieStore.setCookie(cookie)
            }
            if one.generation == generation { done(one) }
        }
    }

    /// `go` once `store`'s session cookies are back: at once for a store not
    /// kept here, a private tab's, or one already back. Where a page is
    /// loaded, so the first one of a run is signed in as it was.
    public func whenRestored(_ store: WKWebsiteDataStore, _ go: @escaping () -> Void) {
        guard let one = kept(store), !one.restored else { return go() }
        one.waiting.append(go)
    }

    /// The one kept for `store`: the same object, or the same store handed
    /// out again (by its identifier; WebKit's own store as "default").
    private func kept(_ store: WKWebsiteDataStore) -> Kept? {
        kept.values.first { $0.store === store } ?? Self.name(of: store).flatMap { kept[$0] }
    }

    private static func name(of store: WKWebsiteDataStore) -> String? {
        guard store.isPersistent else { return nil }
        return store.identifier?.uuidString ?? "default"
    }

    private func done(_ one: Kept) {
        guard !one.restored else { return }
        one.restored = true
        let waiting = one.waiting
        one.waiting = []
        waiting.forEach { $0() }
    }

    // MARK: - forgetting

    /// A store's session cookies gone from the disk at once, as its site
    /// data goes (Clear Website Data), and kept again from the next one. A
    /// restore still under way stops, and what waited on it goes ahead:
    /// there is nothing to put back.
    public func cleared(_ store: WKWebsiteDataStore) {
        guard let one = kept(store) else { return }
        stop(one)
        remove(file(one.name))
        done(one)
    }

    /// A store no longer kept, and its file gone: its space or profile
    /// deleted.
    public func forget(_ store: WKWebsiteDataStore) {
        guard let one = kept(store) else { return }
        forget(named: one.name)
    }

    /// The same, by name: for a store this run never opened, its file.
    public func forget(named name: String) {
        if let one = kept.removeValue(forKey: name) {
            stop(one)
            one.store.httpCookieStore.remove(self)
            done(one)
        }
        remove(file(name))
    }

    /// Whatever was under way for `one` counts no more.
    private func stop(_ one: Kept) {
        one.generation += 1
        one.locked = false
        one.settling?.cancel()
        one.settling = nil
    }

    // MARK: - writing

    /// Whether a change is still to be written, or a file still to be
    /// written or removed.
    public var unwritten: Bool {
        onDisk.withLock { $0 > 0 } || kept.values.contains { $0.settling != nil || $0.writing != nil }
    }

    /// Every change written now, and every write under way on the disk:
    /// going to the background, where the app may not come back, and
    /// quitting.
    public func flush() async {
        for one in kept.values {
            if one.settling != nil {
                one.settling?.cancel()
                one.settling = nil
                write(one)
            }
            await one.writing?.value
        }
        await onDisk {}
    }

    private func changed(_ cookies: WKHTTPCookieStore) {
        guard let one = kept.values.first(where: { $0.store.httpCookieStore === cookies }),
              one.restored else { return }
        one.settling?.cancel()
        one.settling = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled, let self else { return }
            one.settling = nil
            self.write(one)
        }
    }

    /// A write of `one` as its cookies are now, after any already under way,
    /// so the last to finish is the latest. Dropped if what is kept for it
    /// stopped counting while its cookies were being read.
    private func write(_ one: Kept) {
        let generation = one.generation
        let before = one.writing
        let task = Task { [weak self] in
            await before?.value
            let session = await one.store.httpCookieStore.allCookies().filter(\.isSessionOnly)
            guard let self, one.generation == generation else { return }
            self.save(session, as: one.name)
        }
        one.writing = task
        Task { [weak one] in
            await task.value
            if one?.writing == task { one?.writing = nil }
        }
    }

    /// Sealed and written on the disk's queue, after anything asked of it
    /// before; a store cleared since asks for its removal after this, so
    /// what was cleared stays gone.
    private func save(_ session: [HTTPCookie], as name: String) {
        let destination = file(name)
        guard !session.isEmpty, let plain = try? JSONEncoder().encode(session.map(Saved.init)) else {
            return remove(destination)
        }
        enqueue { [folder, key] in
            guard let key = key(), let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #if os(iOS)
            try? sealed.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try? sealed.write(to: destination, options: .atomic)
            #endif
        }
    }

    private func remove(_ file: URL) {
        enqueue { try? FileManager.default.removeItem(at: file) }
    }

    /// `work` on the disk's queue, queued now, after everything asked of it
    /// before, and counted in `onDisk` until it is done.
    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        let counted = onDisk
        counted.withLock { $0 += 1 }
        disk.async {
            work()
            counted.withLock { $0 -= 1 }
        }
    }

    /// The same, awaited, with what it gives: no longer counted by the time
    /// whoever waits on it goes on.
    private func onDisk<Result: Sendable>(_ work: @escaping @Sendable () -> Result) async -> Result {
        let counted = onDisk
        counted.withLock { $0 += 1 }
        return await withCheckedContinuation { (finished: CheckedContinuation<Result, Never>) in
            disk.async {
                let result = work()
                counted.withLock { $0 -= 1 }
                finished.resume(returning: result)
            }
        }
    }

    /// A file read: its cookies, none if it doesn't open with the key (the
    /// key it was sealed with gone), or shut, its file or the key not to be
    /// had for now.
    private enum Reading: Sendable {
        case cookies([HTTPCookie])
        case shut
    }

    nonisolated private static func read(_ source: URL, key: @Sendable () -> SymmetricKey?) -> Reading {
        guard let sealed = try? Data(contentsOf: source), let key = key() else { return .shut }
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key),
              let saved = try? JSONDecoder().decode([Saved].self, from: plain)
        else { return .cookies([]) }
        return .cookies(saved.compactMap(\.cookie))
    }

    private func file(_ name: String) -> URL {
        folder.appendingPathComponent(name + ".sealed")
    }
}

extension SessionCookies: WKHTTPCookieStoreObserver {
    nonisolated public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        MainActor.assumeIsolated { changed(cookieStore) }
    }
}

// MARK: - a cookie, written down

extension SessionCookies {
    /// What a session cookie is made again from. No expiry: it is one.
    struct Saved: Codable, Equatable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let secure: Bool
        let httpOnly: Bool
        let sameSite: String?

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            secure = cookie.isSecure
            httpOnly = cookie.isHTTPOnly
            sameSite = cookie.sameSitePolicy?.rawValue
        }

        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path,
            ]
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite { properties[.sameSitePolicy] = sameSite }
            return HTTPCookie(properties: properties)
        }
    }
}

// MARK: - the key

extension SessionCookies {
    /// The key the files are sealed with: made once, kept in this device's
    /// keychain, never synced, readable once the device has been unlocked
    /// after starting. On the Mac too, the data protection keychain, never
    /// the login keychain's file, which asks for its password while it is
    /// locked. Fetched, or made, once a run, one call at a time, so two
    /// asking together can't make two keys. A Mac build signed without the
    /// profile that lets it use this keychain keeps no sessions, and says
    /// so in the log.
    enum Keychain {
        private static let service = "Eden session cookies"
        private static let found = OSAllocatedUnfairLock<SymmetricKey?>(initialState: nil)
        private static let log = Logger(subsystem: "com.subhajit.eden.beta", category: "SessionCookies")

        static func key() -> SymmetricKey? {
            found.withLock { known in
                if let known { return known }
                known = fetchOrMake()
                return known
            }
        }

        private static func fetchOrMake() -> SymmetricKey? {
            var item = query()
            item[kSecReturnData] = true
            item[kSecMatchLimit] = kSecMatchLimitOne
            var data: CFTypeRef?
            let read = SecItemCopyMatching(item as CFDictionary, &data)
            if read == errSecSuccess, let data = data as? Data { return SymmetricKey(data: data) }
            guard read == errSecItemNotFound else { return refused(read) }
            let made = SymmetricKey(size: .bits256)
            var new = query()
            new[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            new[kSecAttrSynchronizable] = false
            new[kSecValueData] = made.withUnsafeBytes { Data($0) }
            let added = SecItemAdd(new as CFDictionary, nil)
            return added == errSecSuccess ? made : refused(added)
        }

        private static func refused(_ status: OSStatus) -> SymmetricKey? {
            log.error("No key for session cookies (\(status, privacy: .public)): sites' sessions won't outlast a quit")
            return nil
        }

        private static func query() -> [CFString: Any] {
            [
                kSecUseDataProtectionKeychain: true,
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: "key",
            ]
        }
    }
}
