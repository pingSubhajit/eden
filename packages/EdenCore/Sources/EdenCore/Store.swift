import Foundation
import os

// Where everything Eden keeps is kept, on the Mac and on iPhone and iPad.
//
// One place, and one rule: a run started for testing never touches the folder
// or the settings of the browser somebody is actually using. Sharing them once
// cost a person their pinned tabs, which is not a mistake worth being able to
// make twice.
//
// The Mac app adds what belongs to its WebKit stores (its own Store.swift).

public enum Store {
    /// A run is a test run if it says so, or if it is being run straight out
    /// of the build folder rather than from an installed app. The second half
    /// is not belt and braces: a development build launched from a terminal
    /// once wrote over somebody's real session, and asking a person to
    /// remember a flag is not a safeguard.
    public static var testing: Bool {
        if ProcessInfo.processInfo.environment["EDEN_PROBE"] != nil { return true }
        return Bundle.main.executablePath?.contains("/.build/") == true
    }

    /// Which test world a test run lives in. EDEN_PROBE=1, or a run from
    /// the build folder, is the test world, "Eden (test)". EDEN_PROBE=
    /// <name> is a world of its own, "Eden (<name>)", with settings and
    /// WebKit stores of its own: two sessions testing at once, or a
    /// measurement that needs a browser nobody has installed anything in,
    /// never borrow each other's. Nil for the browser somebody is using.
    public static let world: String? = {
        guard testing else { return nil }
        let asked = (ProcessInfo.processInfo.environment["EDEN_PROBE"] ?? "").lowercased()
            .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        return asked.isEmpty || asked == "1" || asked == "test" ? "test" : asked
    }()

    /// A world named after the process it runs in, its name ending in that
    /// process's id, as every test suite names its own ("<suite>-<pid>"):
    /// no run after this one will ever be in it, so it goes when the
    /// process ends, its folder and its settings with it (#7). A world of a
    /// fixed name, the bench's or the test world, stays from run to run.
    public static var throwaway: Bool {
        guard let world else { return false }
        return world.hasSuffix("-\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// What a throwaway world's folder and settings are named by: the
    /// world, and when its process started. A pid comes round again; the
    /// moment its process started, to the microsecond, tells a run that has
    /// ended from a live one that was handed its pid since (sweep).
    private static let throwawayName: String? = {
        guard throwaway, let world,
              case .running(let start) = process(ProcessInfo.processInfo.processIdentifier) else { return nil }
        return "\(world).\(start)"
    }()

    /// What the kernel says of a process.
    enum ProcessState: Equatable {
        /// Running, since this moment, in microseconds since 1970.
        case running(Int64)
        /// No process has that pid.
        case gone
        /// The kernel couldn't be asked: nothing can be said either way.
        case unknown
    }

    /// The process `pid`, as the kernel has it.
    static func process(_ pid: pid_t) -> ProcessState {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return .unknown }
        // Asked of a pid no process has, the call answers with nothing.
        guard size > 0 else { return .gone }
        let start = info.kp_proc.p_starttime
        return .running(Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec))
    }

    /// Asked for by the first use of the folder or the settings: a
    /// throwaway world is set to go when the process exits, once, and what
    /// earlier ones left behind goes now (sweep).
    private static let discardsAtExit: Void = {
        guard throwawayName != nil else { return }
        atexit { Store.discardWorld() }
        sweep()
    }()

    /// The throwaway world's folder and settings, gone, so neither is left
    /// in Library for every test run there has been. The settings are
    /// written out first and then their file taken off the disk. Not let go
    /// of as a domain: the preferences daemon carries that out in its own
    /// time, by writing the file again, empty, after it was taken off.
    /// Settings written while the process is on its way out may still land
    /// after this; the next run sweeps them.
    private static func discardWorld() {
        if !noteWritten { _ = writeNote() }
        try? FileManager.default.removeItem(at: folder)
        guard let settingsSuite else { return }
        CFPreferencesAppSynchronize(settingsSuite as CFString)
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: library.appendingPathComponent("Preferences/\(settingsSuite).plist"))
    }

    /// What throwaway worlds of runs that have ended left behind: a run
    /// that crashed never got to its exit, and settings written while a
    /// process is on its way out can land after it took their file away.
    /// Only a throwaway world's name, "<name>-<pid>.<start>", whose process
    /// is gone: no process has that pid, or the one that has it started at
    /// another moment. Nothing else ever matches: the browser you use, a
    /// bench world, a world named before throwaway names had their start.
    private static func sweep() {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in (try? files.contentsOfDirectory(atPath: support.path)) ?? []
        where name.hasPrefix("Eden (") && name.hasSuffix(")") && ended(String(name.dropFirst(6).dropLast())) {
            try? files.removeItem(at: support.appendingPathComponent(name))
        }
        sweepStores()
        let preferences = files.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Preferences")
        let prefix = "com.subhajit.eden.beta.test."
        for name in (try? files.contentsOfDirectory(atPath: preferences.path)) ?? []
        where name.hasPrefix(prefix) && name.hasSuffix(".plist")
            && ended(String(name.dropFirst(prefix.count).dropLast(".plist".count))) {
            try? files.removeItem(at: preferences.appendingPathComponent(name))
        }
    }

    // MARK: - a throwaway world's WebKit stores (#20)

    /// Where throwaway worlds write down the WebKit stores they make, one
    /// note each, named as the world's folder is. A space or a profile a
    /// test makes is new each run, and so is its store, in WebKit's folder
    /// for the test runner, which every test run shares: only a note says
    /// whose a store is. Kept apart from the world's folder, which goes at
    /// exit and which tests may empty, so the note outlives the run.
    private static var storeNotes: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eden test stores", isDirectory: true)
    }

    /// A throwaway world's stores: the folder WebKit keeps them in, and
    /// their identifiers.
    private struct StoreNote: Codable {
        var folder: String
        var stores: [UUID]
    }

    /// This run's stores, and whether the note on disk says all of them.
    nonisolated(unsafe) private static var note: StoreNote?
    nonisolated(unsafe) private static var noteWritten = true

    /// The folder WebKit keeps stores made by identifier in, for this
    /// process: Library/WebKit/<program>/WebsiteDataStore, or without the
    /// program in a sandbox's container, as WebKit makes the path.
    private static var webKitStores: URL? {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return library.appendingPathComponent("WebKit/WebsiteDataStore", isDirectory: true)
        }
        return Bundle.main.bundleIdentifier.map {
            library.appendingPathComponent("WebKit/\($0)/WebsiteDataStore", isDirectory: true)
        }
    }

    /// A space's or a profile's WebKit store made with identifier `id`
    /// (WKWebsiteDataStore(forIdentifier:)), or a test's own: in a throwaway
    /// world, written down before WebKit has written anything to it, so the
    /// sweep of a later run takes it away once this one has ended, however
    /// it ended. A note that couldn't be written is tried again with the
    /// next store and at exit. Nothing anywhere else.
    public static func madeStore(_ id: UUID) {
        _ = discardsAtExit
        guard throwawayName != nil, let folder = webKitStores else { return }
        var made = note ?? StoreNote(folder: folder.path, stores: [])
        guard !made.stores.contains(id) || !noteWritten else { return }
        if !made.stores.contains(id) { made.stores.append(id) }
        note = made
        noteWritten = writeNote()
    }

    /// This run's note, on disk; whether it got there.
    private static func writeNote() -> Bool {
        guard let throwawayName, let note, let data = try? JSONEncoder().encode(note) else { return false }
        do {
            try FileManager.default.createDirectory(at: storeNotes, withIntermediateDirectories: true)
            try data.write(to: storeNotes.appendingPathComponent(throwawayName), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The stores of throwaway worlds whose run has ended (ended), taken
    /// from WebKit's folder by the identifiers their note gives. One written
    /// to in the last two minutes is left for a later run: WebKit's own
    /// processes may still be writing it out after the run itself has gone.
    /// So is one that wouldn't go. A note goes only with its last store.
    private static func sweepStores() {
        let files = FileManager.default
        for name in (try? files.contentsOfDirectory(atPath: storeNotes.path)) ?? [] where ended(name) {
            let file = storeNotes.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file), var made = try? JSONDecoder().decode(StoreNote.self, from: data) else {
                try? files.removeItem(at: file)
                continue
            }
            let stores = URL(fileURLWithPath: made.folder, isDirectory: true)
            made.stores = made.stores.filter { !removeStore($0, from: stores) }
            if made.stores.isEmpty {
                try? files.removeItem(at: file)
            } else {
                try? JSONEncoder().encode(made).write(to: file, options: .atomic)
            }
        }
    }

    /// The store `id` taken from `stores`, if it is quiet: true once it is
    /// gone, or was never written.
    private static func removeStore(_ id: UUID, from stores: URL) -> Bool {
        let files = FileManager.default
        let candidates = [id.uuidString.lowercased(), id.uuidString].map { stores.appendingPathComponent($0, isDirectory: true) }
        guard let folder = candidates.first(where: { files.fileExists(atPath: $0.path) }) else { return true }
        guard !written(folder, within: 120) else { return false }
        do {
            try files.removeItem(at: folder)
            return true
        } catch {
            return false
        }
    }

    /// Whether anything in `folder`, or the folder itself, was written to
    /// in the last `seconds`.
    private static func written(_ folder: URL, within seconds: TimeInterval) -> Bool {
        let since = Date().addingTimeInterval(-seconds)
        let key = URLResourceKey.contentModificationDateKey
        func recent(_ url: URL) -> Bool {
            ((try? url.resourceValues(forKeys: [key]))?.contentModificationDate).map { $0 > since } ?? false
        }
        if recent(folder) { return true }
        let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [key])
        while let url = all?.nextObject() as? URL { if recent(url) { return true } }
        return false
    }

    /// Whether `name` is a throwaway world's ("<world>-<pid>.<start>") whose
    /// process has ended: certainly, as the kernel says, never because it
    /// couldn't say.
    static func ended(_ name: String) -> Bool {
        func digits(_ text: Substring) -> Bool { !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber } }
        guard let dot = name.lastIndex(of: "."), let dash = name[..<dot].lastIndex(of: "-") else { return false }
        let pidText = name[name.index(after: dash)..<dot], startText = name[name.index(after: dot)...]
        guard digits(pidText), pidText.count <= 5, digits(startText), let pid = pid_t(pidText),
              let start = Int64(startText), pid != ProcessInfo.processInfo.processIdentifier else { return false }
        switch process(pid) {
        case .gone: return true
        case .running(let now): return now != start
        case .unknown: return false
        }
    }

    /// A test run there to be weighed and timed rather than driven
    /// (EDEN_MEASURE beside EDEN_PROBE). It keeps what the shipped
    /// browser does where test runs otherwise differ — hidden pages slowed
    /// the way WebKit slows them, App Nap left to macOS — so what gets
    /// measured is what people get.
    public static var measuring: Bool {
        testing && ProcessInfo.processInfo.environment["EDEN_MEASURE"] != nil
    }

    /// The fixed identifiers of a test world's WebKit stores: 1 for websites,
    /// 2 for extensions. The test world's are 5E4C0000-0000-4000-8000-00000000000k,
    /// the ones fresh.sh wipes; a named world puts a hash of its name (FNV-1a,
    /// 32 bits) in place of the second and third groups of zeros, so each
    /// keeps its own from one run to the next.
    public static func probeStore(_ kind: UInt32) -> UUID {
        var hash: UInt32 = 0
        if let world, world != "test" {
            hash = 2_166_136_261
            for byte in world.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        }
        let text = String(format: "5E4C%04X-%04X-4000-8000-%012X", hash >> 16, hash & 0xFFFF, kind)
        return UUID(uuidString: text)!
    }

    /// The app was called Office Browser until September 2026. Everything it
    /// kept — the session, the pins, the history, what is hidden on each site
    /// — moves to the new name the first time the new name runs, and the
    /// settings are copied across. Nothing is left to be lost.
    public static let folder: URL = {
        _ = discardsAtExit
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let home = support.appendingPathComponent((throwawayName ?? world).map { "Eden (\($0))" } ?? "Eden",
                                                  isDirectory: true)
        if !testing {
            let old = support.appendingPathComponent("Office Browser", isDirectory: true)
            let files = FileManager.default
            if !files.fileExists(atPath: home.path), files.fileExists(atPath: old.path) {
                try? files.moveItem(at: old, to: home)
            }
        }
        return home
    }()

    public static func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// A file that didn't decode is set aside rather than overwritten the
    /// next time something is saved over it — bookmarks, history and a
    /// session are the kind of thing nobody wants to lose to a bad read with
    /// no trace of what was there. Failing to move it is fine: the read
    /// already came back empty either way, and there's nothing further to
    /// do about a folder that won't take a rename.
    public static func quarantine(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: file, to: aside)
    }

    /// Settings live apart too: a test that changes what the tabs wear or
    /// where the tabs go must not change yours.
    public static let settings: UserDefaults = {
        _ = discardsAtExit
        guard let settingsSuite else {
            carryOver(into: .standard)
            return .standard
        }
        return UserDefaults(suiteName: settingsSuite) ?? .standard
    }()

    /// The name of a test run's settings, nil for the browser somebody uses:
    /// "com.subhajit.eden.beta.test" for the test world, with ".<name>" for
    /// a world of its own. What clears a test world clears this one.
    public static let settingsSuite: String? = {
        guard testing else { return nil }
        return world == "test" ? "com.subhajit.eden.beta.test" : "com.subhajit.eden.beta.test.\(throwawayName ?? world ?? "")"
    }()

    /// The old bundle's defaults, read once and written under the new one.
    private static func carryOver(into fresh: UserDefaults) {
        guard !fresh.bool(forKey: "carried"),
              let old = UserDefaults(suiteName: "com.driceroland.officebrowser")
        else { return }
        for (key, value) in old.dictionaryRepresentation()
        where fresh.object(forKey: key) == nil && !key.hasPrefix("NS") && !key.hasPrefix("Apple") {
            fresh.set(value, forKey: key)
        }
        // The window comes back where it was, under its new name.
        if let frame = old.string(forKey: "NSWindow Frame office-browser") {
            fresh.set(frame, forKey: "NSWindow Frame search")
        }
        fresh.set(true, forKey: "carried")
    }
}

/// Files written in the background, one at a time and the newest last.
///
/// Each save used to go to a concurrent queue on its own: two saves of the
/// same file a moment apart could land in either order, and the session
/// written at quit could be overwritten by an older one still on its way —
/// yesterday's tabs coming back instead of today's. Here every write joins
/// one serial queue, and a write that a newer one of the same file has
/// overtaken is dropped, including when the newer one was written at once
/// on the way out.
public enum Disk {
    private static let queue = DispatchQueue(label: "search.disk", qos: .utility)
    private static let lock = NSLock()
    /// The newest write asked for, by file.
    nonisolated(unsafe) private static var newest: [URL: Int] = [:]
    nonisolated(unsafe) private static var count = 0
    /// The turn of the newest write that didn't land, by file: cleared when
    /// a later write of it does.
    nonisolated(unsafe) private static var failed: [URL: Int] = [:]
    /// A write that failed, for Console (subsystem com.subhajit.eden.beta,
    /// category Disk): the file's name and why, never where it is.
    private static let log = Logger(subsystem: "com.subhajit.eden.beta", category: "Disk")
    /// The files asked written while `recording` runs, where it runs.
    @TaskLocal private static var recorder: Recorder?

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var files: Set<URL> = []

        func add(_ file: URL) {
            lock.lock()
            files.insert(file)
            lock.unlock()
        }

        var all: Set<URL> {
            lock.lock()
            defer { lock.unlock() }
            return files
        }
    }

    /// `encode` runs where the write does. `now` writes on the calling
    /// thread: quitting doesn't wait for a queue.
    public static func write(_ file: URL, now: Bool = false, _ encode: @escaping @Sendable () -> Data?) {
        lock.lock()
        count += 1
        let turn = count
        newest[file] = turn
        lock.unlock()
        recorder?.add(file)
        // Overtaken: something newer of this file was asked for since.
        let current: @Sendable () -> Bool = {
            lock.lock()
            defer { lock.unlock() }
            return newest[file] == turn
        }
        let put: @Sendable () -> Void = {
            guard current(), let data = encode() else { return }
            // Written beside it with no lock held, and only put in its place
            // under the lock: held for the whole write, a write at once on the
            // main thread waited for whatever was being written in the
            // background — the whole history, say.
            let folder = file.deletingLastPathComponent()
            let aside = folder.appendingPathComponent(".\(file.lastPathComponent).\(turn).writing")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                try data.write(to: aside)
            } catch {
                log.error("couldn't write \(file.lastPathComponent, privacy: .public): \(Disk.reason(error), privacy: .public)")
                lock.lock()
                if newest[file] == turn { failed[file] = turn }
                lock.unlock()
                return
            }
            lock.lock()
            defer { lock.unlock() }
            if newest[file] == turn {
                if rename(aside.path, file.path) == 0 {
                    failed[file] = nil
                    return
                }
                let code = errno
                log.error("couldn't put \(file.lastPathComponent, privacy: .public) in place: \(String(cString: strerror(code)), privacy: .public) (\(code, privacy: .public))")
                failed[file] = turn
            }
            try? FileManager.default.removeItem(at: aside)
        }
        if now { put() } else { queue.async(execute: put) }
    }

    /// The file gone, after any write of it already asked for — and none
    /// asked for before this lands it again.
    public static func remove(_ file: URL) {
        lock.lock()
        count += 1
        let turn = count
        newest[file] = turn
        lock.unlock()
        queue.async {
            lock.lock()
            defer { lock.unlock() }
            guard newest[file] == turn else { return }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Everything asked for so far, written — for the way out.
    public static func drain() {
        queue.sync {}
    }

    /// Where the writes stand now, to ask later whether those asked for
    /// since all landed (`drain(since:)`).
    public static func mark() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Everything asked for so far, written; whether every write asked for
    /// since `mark` that is still a file's newest landed.
    public static func drain(since mark: Int) -> Bool {
        queue.sync {}
        lock.lock()
        defer { lock.unlock() }
        return !failed.values.contains { $0 > mark }
    }

    /// The same for `files` alone: a write of any other file that failed
    /// meanwhile — another part of the app's, on its own business — has no
    /// say.
    public static func drain(since mark: Int, only files: Set<URL>) -> Bool {
        queue.sync {}
        lock.lock()
        defer { lock.unlock() }
        return !failed.contains { files.contains($0.key) && $0.value > mark }
    }

    /// The files `body` asks written, as it runs: for asking whether those
    /// landed (`drain(since:only:)`). Recorded inside another recording,
    /// they count for the outer one too, so its check covers them.
    public static func recording(_ body: () -> Void) -> Set<URL> {
        let outer = recorder
        let made = Recorder()
        $recorder.withValue(made) { body() }
        let files = made.all
        for file in files { outer?.add(file) }
        return files
    }

    /// Why a write failed, without the path the error's own sentence may
    /// carry: its domain and code, and the system's word underneath.
    private static func reason(_ error: Error) -> String {
        let error = error as NSError
        var out = "\(error.domain) \(error.code)"
        if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain {
            out += ": " + String(cString: strerror(Int32(under.code)))
        }
        return out
    }
}
