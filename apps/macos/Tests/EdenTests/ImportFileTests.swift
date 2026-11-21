import EdenCore
import Foundation
import XCTest
import Darwin
import AppKit
@testable import Eden

final class ImportFileTests: XCTestCase {
    private static var probeWorld: String?

    override class func setUp() {
        super.setUp()
        // Named for this process, as every suite's world is: Store throws
        // such a world away at exit, and sweeps it if a run never got there.
        let world = "import-tests-\(getpid())"
        probeWorld = world
        setenv("EDEN_PROBE", world, 1)
    }

    /// What its windows left in the world the next suite shares: their
    /// pins, folders and saved tabs (CleanWorld).
    override func tearDown() async throws {
        await MainActor.run { CleanWorld.reset() }
        try await super.tearDown()
    }

    override class func tearDown() {
        Disk.drain()
        if let probeWorld, Store.world == probeWorld {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults(suiteName: "com.subhajit.eden.beta.test.\(probeWorld)")?.removePersistentDomain(forName: "com.subhajit.eden.beta.test.\(probeWorld)")
        }
        unsetenv("EDEN_PROBE")
        super.tearDown()
    }

    func testBookmarksParserKeepsNetscapeFoldersAndDecodedTitles() {
        let html = #"""
        <DL><p>
          <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Bar</H3><DL><p>
            <DT><A HREF="https://example.com/?a=1&amp;b=2">A &amp; B</A>
          </DL><p>
          <DT><H3>Folder &amp; one</H3><DL><p>
            <DT><A HREF="https://inside.example/">Nested</A>
          </DL><p>
        </DL>
        """#

        let bookmarks = BookmarksFile.parse(html)
        XCTAssertEqual(bookmarks.map(\.title), ["A & B", "Folder & one"])
        XCTAssertEqual(bookmarks[0].url, "https://example.com/?a=1&b=2")
        XCTAssertEqual(bookmarks[1].children?.map(\.title), ["Nested"])
    }

    func testFolderReadsOnlyRootAndImmediateFilesInLexicographicOrder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefixFolder = root.appendingPathComponent("a", isDirectory: true)
        let siblingFolder = root.appendingPathComponent("a-branch", isDirectory: true)
        let deepFolder = prefixFolder.appendingPathComponent("deep", isDirectory: true)
        let hiddenFolder = root.appendingPathComponent(".hidden", isDirectory: true)
        let outside = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: prefixFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deepFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: true)

        try writeBookmark("Root", url: "https://root.example/", to: root.appendingPathComponent("a.html"))
        try writeBookmark("Inside", url: "https://inside.example/", to: prefixFolder.appendingPathComponent("inside.html"))
        try writeBookmark("Sibling", url: "https://sibling.example/", to: siblingFolder.appendingPathComponent("inside.html"))
        try writeBookmark("Deep", url: "https://deep.example/", to: deepFolder.appendingPathComponent("too-deep.html"))
        try writeBookmark("Hidden", url: "https://hidden.example/", to: root.appendingPathComponent(".hidden.html"))
        try writeBookmark("Hidden folder", url: "https://hidden-folder.example/", to: hiddenFolder.appendingPathComponent("hidden.html"))
        let unreadable = root.appendingPathComponent("unreadable.csv")
        try "unreadable fixture".write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        let canReadUnreadable: Bool
        do {
            let handle = try FileHandle(forReadingFrom: unreadable)
            _ = try handle.read(upToCount: 1)
            try handle.close()
            canReadUnreadable = true
        } catch {
            canReadUnreadable = false
        }
        let outsideFile = outside.appendingPathComponent("outside.html")
        try writeBookmark("Symlink", url: "https://outside.example/", to: outsideFile)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.html"), withDestinationURL: outsideFile)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-folder", isDirectory: true), withDestinationURL: outside)

        let first = try ImportFile.read(root)
        let second = try ImportFile.read(root)
        let expected = ["Sibling", "Root", "Inside"]
        XCTAssertEqual(first.bookmarks.map(\.title), expected)
        XCTAssertEqual(second.bookmarks.map(\.title), expected)
        if !canReadUnreadable {
            XCTAssertTrue(first.passwords.isEmpty, "an unreadable folder member must not discard the valid bookmarks or become a password file")
        }
    }

    func testProgressResetsForNewStagesAndThrottlesRepeatedUpdates() {
        let lock = NSLock()
        var updates: [ImportFile.Progress] = []
        let control = ImportFile.Control { update in
            lock.lock()
            updates.append(update)
            lock.unlock()
        }

        let started = ProcessInfo.processInfo.systemUptime
        control.report(.init(message: "Reading file", completed: 0, total: 100_000))
        for count in 1...10_000 {
            control.report(.init(message: "Reading file", completed: count, total: 100_000))
        }
        Thread.sleep(forTimeInterval: 0.12)
        control.report(.init(message: "Saving passwords", completed: 0, total: 3))
        Thread.sleep(forTimeInterval: 0.12)
        control.report(.init(message: "Saving passwords", completed: 3, total: 3))

        lock.lock()
        let captured = updates
        lock.unlock()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThanOrEqual(captured.count, Int(elapsed / 0.1) + 1)
        XCTAssertEqual(captured.first?.completed, 0)
        let savingStage = captured.first { $0.message == "Saving passwords" }
        XCTAssertEqual(savingStage?.completed, 0, "a new phase should reset its displayed count")
        XCTAssertEqual(captured.last?.completed, 3)
        XCTAssertEqual(captured.last?.total, 3)
    }

    func testProgressThrottleBoundsRapidDistinctFileMessages() {
        let lock = NSLock()
        var updates: [ImportFile.Progress] = []
        let control = ImportFile.Control { update in
            lock.lock()
            updates.append(update)
            lock.unlock()
        }

        let started = ProcessInfo.processInfo.systemUptime
        control.report(.init(message: "Folder: Scanning", completed: 0))
        for index in 1...5_000 {
            control.report(.init(message: "file-\(index): File complete", completed: 1))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        lock.lock()
        let count = updates.count
        lock.unlock()

        XCTAssertLessThanOrEqual(count, Int(elapsed / 0.1) + 1, "filename and finished-file changes must share the global throttle")
    }

    func testHTMLParserProgressCanCancelDuringRegexEnumeration() throws {
        let html = "<DL>" + (0..<2_000).map { index in
            #"<DT><A HREF="https://example.com/\#(index)">Bookmark \#(index)</A>"#
        }.joined() + "</DL>"
        let control = ImportFile.Control()
        var progressThrough = 0
        XCTAssertThrowsError(try BookmarksFile.parse(html, control: control, progress: { stage, completed, _ in
            if stage == "Parsing bookmarks" {
                progressThrough = completed
                if completed > 1_000 { control.cancel() }
            }
        })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThan(progressThrough, 1_000)
        XCTAssertLessThan(progressThrough, (html as NSString).length)
    }

    func testPasswordCSVPrecancelAndProgressNeverContainsItsContents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("passwords.csv")
        let secret = "private-test-password-91c"
        let csv = "url,username,password\nhttps://example.com,alice,\(secret)\n"
        try csv.write(to: file, atomically: true, encoding: .utf8)
        let cancelled = ImportFile.Control()
        cancelled.cancel()
        XCTAssertThrowsError(try ImportFile.read(file, control: cancelled)) { error in
            XCTAssertTrue(error is CancellationError)
        }

        var updates: [ImportFile.Progress] = []
        let control = ImportFile.Control { updates.append($0) }
        let imported = try ImportFile.read(file, control: control)
        XCTAssertEqual(imported.passwords, [csv])
        XCTAssertTrue(updates.contains { $0.message == "passwords.csv: Reading CSV" })
        XCTAssertTrue(updates.allSatisfy { !$0.message.contains(secret) })
        XCTAssertTrue(updates.contains { $0.total != nil })

        updates.removeAll()
        let safeToSkip = "url,username,password\n,alice,\(secret)\n"
        let vaultControl = ImportFile.Control { updates.append($0) }
        let result = Vault.take(csv: safeToSkip, control: vaultControl)
        XCTAssertEqual(result.kept, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(updates.contains { $0.message == "Reading password CSV…" })
        XCTAssertTrue(updates.allSatisfy { !$0.message.contains(secret) })
    }

    /// Another browser's bookmarks come in as pinned rows, in a folder
    /// named after it ("Chrome Bookmarks"), the pages of its folders among them in order, a
    /// pinned folder being one level deep (#6); the list stays as it was.
    @MainActor
    func testImportedBookmarksArePinnedInAFolderNamedAfterTheBrowser() throws {
        let browser = makeImportTestBrowser()
        let previousRecords = Store.settings.data(forKey: "import.records")
        let listBefore = Profiles.bookmarks(browser.profileID).roots
        let (source, root) = try makeChromiumSource(name: "Pinning \(UUID().uuidString)")
        defer {
            if let record = ImportRecords.of(source.name) { PinShelf.withdraw(record.bookmarkIDs, via: browser) }
            try? FileManager.default.removeItem(at: root)
            if let previousRecords { Store.settings.set(previousRecords, forKey: "import.records") }
            else { Store.settings.removeObject(forKey: "import.records") }
            browser.closeAll()
            Disk.drain()
        }

        let profile = try makeProfile("Default", under: root)
        try writeChromiumBookmarks([
            chromiumURL("Loose", "https://loose-import.example/"),
            ["type": "folder", "name": "Work", "children": [chromiumURL("Filed", "https://filed-import.example/")]],
        ], to: profile)
        let took = browser.takeBookmarks(from: .chromium(source))
        XCTAssertEqual(took.added, 2)
        let folder = try XCTUnwrap(browser.pinShelf.roots.first { $0.isFolder && $0.title == PinShelf.folderName(import: source.name) })
        func pages(_ nodes: [Bookmark]) -> [String] {
            nodes.flatMap { $0.isFolder ? pages($0.children ?? []) : [$0.url ?? ""] }
        }
        XCTAssertEqual(folder.children?.map(\.url), ["https://loose-import.example/", "https://filed-import.example/"],
                       "Work's page in the one folder, in order, and no folder inside it")
        XCTAssertTrue(Pins.defs(browser.spaceID).filter { pages([folder]).contains($0.home) }.allSatisfy { $0.listed == true })
        XCTAssertEqual(Profiles.bookmarks(browser.profileID).roots, listBefore, "the bookmarks list is left as it was")
        let record = try XCTUnwrap(ImportRecords.of(source.name))
        XCTAssertEqual(record.bookmarks, 2)
        XCTAssertEqual(Set(record.bookmarkIDs), Set(Bookmarks.folders([folder]).map(\.node.id) + Pins.defs(browser.spaceID)
            .filter { pages([folder]).contains($0.home) }.map(\.id)))

        // Again: nothing twice.
        let again = browser.takeBookmarks(from: .chromium(source))
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.already, 2)
    }

    /// A bookmarks file comes in the same way, in a folder named after it:
    /// its name, then Bookmarks.
    @MainActor
    func testFileBookmarksArePinnedInAFolderNamedAfterTheFile() async throws {
        let browser = makeImportTestBrowser()
        let folder = try makeTemporaryDirectory()
        let stem = "Exported \(UUID().uuidString.prefix(8))"
        let name = stem + " Bookmarks"
        let file = folder.appendingPathComponent("\(stem).html")
        try writeBookmark("From the file", url: "https://from-a-file.example/", to: file)
        defer {
            if let made = browser.pinShelf.roots.first(where: { $0.isFolder && $0.title == name }) { browser.pinShelf.remove(made.id) }
            try? FileManager.default.removeItem(at: folder)
            browser.closeAll()
            Disk.drain()
        }
        let took = await browser.takeFile(file)
        XCTAssertEqual(took.bookmarks, 1)
        let made = try XCTUnwrap(browser.pinShelf.roots.first { $0.isFolder && $0.title == name })
        XCTAssertEqual(made.children?.map(\.url), ["https://from-a-file.example/"])
    }

    /// A large bookmarks file merged into the pins: the window keeps
    /// drawing — the main actor runs other work between the merge's
    /// batches — and the longest it is held at once is printed, as measured.
    @MainActor
    func testALargeBookmarksFileKeepsTheWindowResponsive() async throws {
        let browser = makeImportTestBrowser()
        let (file, folder, name) = try writeLargeBookmarksFile(count: 1_500)
        defer {
            if let made = browser.pinShelf.roots.first(where: { $0.isFolder && $0.title == name }) { browser.pinShelf.remove(made.id) }
            try? FileManager.default.removeItem(at: folder)
            browser.closeAll()
            Disk.drain()
        }
        let history = try await historyWithOneOfTheFilesPages(browser)
        let beats = MainBeats()
        var merging = 0
        beats.onBeat = { if browser.fileImport?.message == "Merging bookmarks…" { merging += 1 } }
        let began = ProcessInfo.processInfo.systemUptime
        let took = await browser.takeFile(file)
        let measured = beats.stop()
        print("IMPORT-STALL 1500 bookmarks: longest main-thread stall \(Int(measured.longest * 1000)) ms, \(measured.beats) beats in \(Int((ProcessInfo.processInfo.systemUptime - began) * 1000)) ms")
        XCTAssertGreaterThan(merging, 5, "the window had turns while the bookmarks merged")
        XCTAssertEqual(took.bookmarks, 1_500)
        XCTAssertFalse(took.cancelled)
        XCTAssertEqual(browser.pinShelf.roots.first { $0.title == name }?.children?.count, 1_500)
        XCTAssertEqual(traces(browser), history, "bookmarks touch no history, as they never did: no title, no visit, no entry")
    }

    /// Cancel heard while a large file's bookmarks merge: they never come
    /// in, none of them, and nothing is left of them, no pin, no folder.
    @MainActor
    func testALargeBookmarksFileCancelledMidMergeLeavesNothing() async throws {
        let browser = makeImportTestBrowser()
        let (file, folder, name) = try writeLargeBookmarksFile(count: 1_500)
        defer {
            if let made = browser.pinShelf.roots.first(where: { $0.isFolder && $0.title == name }) { browser.pinShelf.remove(made.id) }
            try? FileManager.default.removeItem(at: folder)
            browser.closeAll()
            Disk.drain()
        }
        let pins = Pins.defs(browser.spaceID)
        let tabs = browser.tabs.count
        let history = try await historyWithOneOfTheFilesPages(browser)
        let beats = MainBeats()
        var cancelledAt: Int?
        beats.onBeat = {
            guard cancelledAt == nil, let job = browser.fileImport, job.message == "Merging bookmarks…",
                  let total = job.total, job.completed > 0, job.completed < total else { return }
            cancelledAt = job.completed
            browser.cancelFileImport()
        }
        let took = await browser.takeFile(file)
        _ = beats.stop()
        let at = try XCTUnwrap(cancelledAt, "cancelled midway")
        XCTAssertLessThan(at, 1_500)
        XCTAssertTrue(took.cancelled)
        XCTAssertEqual(took.bookmarks, 0)
        XCTAssertNil(browser.pinShelf.roots.first { $0.title == name }, "no folder")
        XCTAssertEqual(Pins.defs(browser.spaceID), pins, "no pin")
        XCTAssertEqual(browser.tabs.count, tabs, "no tab")
        XCTAssertEqual(took.said, "Import cancelled; nothing was changed")
        XCTAssertEqual(traces(browser), history,
                       "no history: the page there keeps its title and count, and none is added (the tabs made ahead were never wired to it)")
    }

    /// One of the large file's pages in history already, under a title of
    /// its own: what history holds of the file's pages, as traces.
    @MainActor
    private func historyWithOneOfTheFilesPages(_ browser: Browser) async throws -> [String] {
        let deadline = Date().addingTimeInterval(5)
        while !browser.history.isLoaded, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(browser.history.isLoaded)
        browser.history.take(try XCTUnwrap(URL(string: "https://large-7.example/page")), title: "Original history title",
                             count: 3, last: Date())
        browser.history.settle()
        let known = traces(browser)
        XCTAssertTrue(known.contains { $0.contains("Original history title") })
        return known
    }

    /// What history holds of the large files' pages: address, title, count.
    @MainActor
    private func traces(_ browser: Browser) -> [String] {
        browser.history.everything(matching: "large-").map { "\($0.key) \($0.title) \($0.count)" }.sorted()
    }

    @MainActor
    func testReplaceWithReadableEmptyProfileRemovesOnlyThatSourcesBookmarks() throws {
        let browser = makeImportTestBrowser()
        let previousRecords = Store.settings.data(forKey: "import.records")
        let (source, root) = try makeChromiumSource(name: "Replace Empty \(UUID().uuidString)")
        defer {
            if let record = ImportRecords.of(source.name) { PinShelf.withdraw(record.bookmarkIDs, via: browser) }
            try? FileManager.default.removeItem(at: root)
            if let previousRecords { Store.settings.set(previousRecords, forKey: "import.records") }
            else { Store.settings.removeObject(forKey: "import.records") }
            Disk.drain()
        }
        func pinned() -> [String] { Pins.defs(browser.spaceID).map(\.home) }

        let profile = try makeProfile("Default", under: root)
        let sourceURL = "https://replace-source.example/"
        try writeChromiumBookmarks([chromiumURL("From source", sourceURL)], to: profile)
        let first = browser.takeBookmarks(from: .chromium(source))
        XCTAssertEqual(first.added, 1)
        XCTAssertFalse(first.kept)
        let priorRecord = try XCTUnwrap(ImportRecords.of(source.name))
        XCTAssertEqual(priorRecord.bookmarks, 1)
        XCTAssertEqual(pinned().filter { $0 == sourceURL }.count, 1)

        // A row of your own, in the folder the import made.
        let theirs = try XCTUnwrap(browser.pinShelf.roots.first { $0.isFolder && $0.title == PinShelf.folderName(import: source.name) })
        let manualURL = "https://manual-bookmark.example/"
        let manual = try XCTUnwrap(browser.pinShelf.insert(.site("Manual", try XCTUnwrap(URL(string: manualURL))), into: theirs.id))
        defer { browser.pinShelf.remove(theirs.id) }
        let otherSource = try makeChromiumSource(name: "Other Browser \(UUID().uuidString)")
        defer {
            if let record = ImportRecords.of(otherSource.0.name) { PinShelf.withdraw(record.bookmarkIDs, via: browser) }
            try? FileManager.default.removeItem(at: otherSource.1)
        }
        let otherProfile = try makeProfile("Default", under: otherSource.1)
        let otherURL = "https://other-browser.example/"
        try writeChromiumBookmarks([chromiumURL("Other browser", otherURL)], to: otherProfile)
        XCTAssertEqual(browser.takeBookmarks(from: .chromium(otherSource.0)).added, 1)
        let otherRecordBefore = try XCTUnwrap(ImportRecords.of(otherSource.0.name))

        try writeChromiumBookmarks([], to: profile)
        let replacement = browser.takeBookmarks(from: .chromium(source), replacing: true)

        XCTAssertEqual(replacement.added, 0)
        XCTAssertEqual(replacement.already, 0)
        XCTAssertFalse(replacement.kept)
        XCTAssertFalse(pinned().contains(sourceURL), "a clean empty profile replaces its earlier import with nothing")
        XCTAssertTrue(pinned().contains(manualURL), "a row of your own must survive source replacement")
        XCTAssertEqual(browser.pinShelf.parent(of: manual.id), theirs.id, "with the folder it is in")
        XCTAssertTrue(pinned().contains(otherURL), "pins from another browser must survive source replacement")
        let sourceRecord = try XCTUnwrap(ImportRecords.of(source.name))
        XCTAssertEqual(sourceRecord.bookmarks, 0)
        XCTAssertTrue(sourceRecord.bookmarkIDs.isEmpty)
        XCTAssertEqual(ImportRecords.of(otherSource.0.name)?.bookmarkIDs, otherRecordBefore.bookmarkIDs)
    }

    /// The record is kept by the browser's name: Replace in another
    /// profile takes nothing out and keeps what it couldn't reach, so
    /// Replace in the profile the pins came into still finds them.
    @MainActor
    func testReplaceInAnotherProfileKeepsTheRecordForThisOne() throws {
        let browser = makeImportTestBrowser()
        let previousRecords = Store.settings.data(forKey: "import.records")
        let (source, root) = try makeChromiumSource(name: "Replace Elsewhere \(UUID().uuidString)")
        let other = Profiles.shared.add(named: "Elsewhere \(UUID().uuidString.prefix(6))")
        let elsewhere = Browser(record: WindowRecord(space: other.home))
        defer {
            if let record = ImportRecords.of(source.name) { PinShelf.withdraw(record.bookmarkIDs, via: browser) }
            elsewhere.closeAll()
            Profiles.shared.delete(other.id)
            try? FileManager.default.removeItem(at: root)
            if let previousRecords { Store.settings.set(previousRecords, forKey: "import.records") }
            else { Store.settings.removeObject(forKey: "import.records") }
            Disk.drain()
        }
        func pinned() -> [String] { Pins.defs(browser.spaceID).map(\.home) }

        let profile = try makeProfile("Default", under: root)
        let url = "https://replace-elsewhere.example/"
        try writeChromiumBookmarks([chromiumURL("From source", url)], to: profile)
        XCTAssertEqual(browser.takeBookmarks(from: .chromium(source)).added, 1)
        let first = try XCTUnwrap(ImportRecords.of(source.name))

        try writeChromiumBookmarks([], to: profile)
        let there = elsewhere.takeBookmarks(from: .chromium(source), replacing: true)
        XCTAssertFalse(there.kept)
        XCTAssertTrue(pinned().contains(url), "another profile's Replace leaves this one's pins")
        XCTAssertEqual(Set(ImportRecords.of(source.name)?.bookmarkIDs ?? []), Set(first.bookmarkIDs), "and their record")

        XCTAssertFalse(browser.takeBookmarks(from: .chromium(source), replacing: true).kept)
        XCTAssertFalse(pinned().contains(url), "Replace in its own profile takes them out")
        XCTAssertEqual(ImportRecords.of(source.name)?.bookmarkIDs, [])
        XCTAssertEqual(ImportRecords.of(source.name)?.bookmarks, 0)
    }

    @MainActor
    func testReplaceWithMissingOrMalformedProfilePreservesEarlierImportAndProvenance() throws {
        let browser = makeImportTestBrowser()
        let previousRecords = Store.settings.data(forKey: "import.records")
        let (source, root) = try makeChromiumSource(name: "Replace Partial \(UUID().uuidString)")
        defer {
            if let record = ImportRecords.of(source.name) { PinShelf.withdraw(record.bookmarkIDs, via: browser) }
            try? FileManager.default.removeItem(at: root)
            if let previousRecords { Store.settings.set(previousRecords, forKey: "import.records") }
            else { Store.settings.removeObject(forKey: "import.records") }
            Disk.drain()
        }
        func pinned() -> [String] { Pins.defs(browser.spaceID).map(\.home) }

        let usual = try makeProfile("Default", under: root)
        let broken = try makeProfile("Profile 1", under: root)
        let originalURL = "https://original-profile.example/"
        try writeChromiumBookmarks([chromiumURL("Original", originalURL)], to: usual)
        XCTAssertEqual(browser.takeBookmarks(from: .chromium(source), profile: "Default").added, 1)
        let originalRecord = try XCTUnwrap(ImportRecords.of(source.name))

        let missing = browser.takeBookmarks(from: .chromium(source), profile: "Missing profile", replacing: true)
        XCTAssertTrue(missing.kept)
        XCTAssertTrue(pinned().contains(originalURL))
        let afterMissing = try XCTUnwrap(ImportRecords.of(source.name))
        XCTAssertEqual(afterMissing.bookmarks, originalRecord.bookmarks)
        XCTAssertEqual(afterMissing.bookmarkIDs, originalRecord.bookmarkIDs)

        let readableURL = "https://readable-profile.example/"
        try writeChromiumBookmarks([chromiumURL("Updated", readableURL)], to: usual)
        try Data("malformed profile bookmarks".utf8).write(to: broken.appendingPathComponent("Bookmarks"))
        let partial = browser.takeBookmarks(from: .chromium(source), replacing: true)

        XCTAssertTrue(partial.kept, "a malformed profile means the set was not completely read")
        XCTAssertTrue(pinned().contains(originalURL), "unreadable replacement must preserve prior source pins")
        XCTAssertTrue(pinned().contains(readableURL), "readable profiles still contribute their current bookmarks")
        let afterMalformed = try XCTUnwrap(ImportRecords.of(source.name))
        XCTAssertEqual(afterMalformed.bookmarks, 2)
        XCTAssertTrue(originalRecord.bookmarkIDs.allSatisfy(afterMalformed.bookmarkIDs.contains), "prior source provenance must remain attached")
    }

    @MainActor
    func testArcImportKeepsSpacesFoldersPinsAndImportRecordCounts() throws {
        let browser = makeImportTestBrowser()
        let previousRecords = Store.settings.data(forKey: "import.records")
        let previousUsesSpaces = browser.prefs.usesSpaces
        let previousUsesTabGroups = browser.prefs.usesTabGroups
        let previousSpaces = browser.spaces
        let suffix = UUID().uuidString
        let workName = "Arc Engineering \(suffix)"
        let personalName = "Arc Personal \(suffix)"
        let oldArcFolder = Arc.file.deletingLastPathComponent()
        let oldArcFolderExisted = FileManager.default.fileExists(atPath: oldArcFolder.path)
        let oldArcFile = try? Data(contentsOf: Arc.file)
        try FileManager.default.createDirectory(at: oldArcFolder, withIntermediateDirectories: true)
        let previousProfiles = Set(Profiles.shared.list.map(\.id))
        defer {
            for space in Spaces.read() where space.name == workName || space.name == personalName {
                Pins.forget(space.id)
                Session.erase(space: space.id)
            }
            // The profile Arc's second one became, and everything in it.
            for profile in Profiles.shared.list where !previousProfiles.contains(profile.id) {
                Profiles.shared.delete(profile.id)
            }
            browser.spaces = previousSpaces
            Spaces.write(previousSpaces, profile: browser.profileID)
            browser.prefs.usesSpaces = previousUsesSpaces
            browser.prefs.usesTabGroups = previousUsesTabGroups
            if let oldArcFile { try? oldArcFile.write(to: Arc.file, options: .atomic) }
            else {
                try? FileManager.default.removeItem(at: Arc.file)
                if !oldArcFolderExisted { try? FileManager.default.removeItem(at: oldArcFolder) }
            }
            if let previousRecords { Store.settings.set(previousRecords, forKey: "import.records") }
            else { Store.settings.removeObject(forKey: "import.records") }
            Disk.drain()
        }

        let source = ImportSource.chromium(Chromium.Source(
            name: "Arc", folder: "Arc/User Data", service: "Arc Safe Storage", account: "Arc", app: "Arc.app"))
        let sidebar = try makeArcSidebarFixture(workName: workName, personalName: personalName)
        try sidebar.write(to: Arc.file, options: .atomic)
        browser.prefs.usesSpaces = false
        browser.prefs.usesTabGroups = true

        let imported = try XCTUnwrap(source.arcSidebar(profile: nil))
        XCTAssertEqual(source.arcCounts(profile: nil)?.spaces, 2)
        XCTAssertEqual(source.arcCounts(profile: nil)?.pinned, 5)
        XCTAssertEqual(imported.spaces.map(\.name), [workName, personalName])
        XCTAssertEqual(imported.spaces[0].pinned.count, 1, "Arc folders remain folders until Eden places their tabs in a group")
        if case .folder(let folder) = imported.spaces[0].pinned[0] {
            XCTAssertEqual(folder.title, "Research")
            XCTAssertEqual(Arc.count([imported.spaces[0].pinned[0]]), 2)
        } else {
            XCTFail("Arc's pinned folder was flattened while reading the sidebar")
        }

        let result = browser.takeArc(imported)
        ImportRecords.note(source.name, spaces: result.spaces, pinned: result.pins)
        XCTAssertEqual(result.spaces, 2)
        XCTAssertEqual(result.pins, 5, "each space's favourites from its own profile, and its pinned list as rows")

        let again = browser.takeArc(imported)
        XCTAssertEqual(again.spaces, 0)
        XCTAssertEqual(again.pins, 0)

        // Arc's first profile's space is this window's profile's; its
        // second profile ("Profile 1") is an Eden profile of its own, with
        // that space in it, signed in with the profile's own cookies.
        let work = try XCTUnwrap(browser.spaces.first { $0.name == workName })
        XCTAssertNil(browser.spaces.first { $0.name == personalName }, "another profile's space never shows in this window")
        let personal = try XCTUnwrap(Spaces.read().first { $0.name == personalName })
        XCTAssertEqual(work.sharesSignIns, true)
        XCTAssertEqual(work.profileID, browser.profileID)
        XCTAssertEqual(personal.sharesSignIns, true)
        XCTAssertNotEqual(personal.profileID, browser.profileID)
        XCTAssertEqual(Profiles.shared.profile(personal.profileID).name, "Profile 1")
        XCTAssertEqual(Profiles.shared.profile(personal.profileID).home, personal.id)
        // The favourites as squares, Arc's pinned list as rows, its folder a
        // kept group.
        let research = try XCTUnwrap(Pins.groups(work.id).first { $0.name == "Research" })
        XCTAssertEqual(Pins.defs(work.id).map(\.home),
                       ["https://favorite-work.example/", "https://work-one.example/", "https://work-two.example/"])
        XCTAssertEqual(Pins.defs(work.id).map { $0.listed == true }, [false, true, true])
        XCTAssertEqual(Pins.defs(work.id).map(\.group), [nil, research.id, research.id])
        XCTAssertEqual(Pins.defs(personal.id).map(\.home),
                       ["https://favorite-personal.example/", "https://personal.example/"])
        XCTAssertEqual(Pins.defs(personal.id).last?.group, nil)
        let record = try XCTUnwrap(ImportRecords.of(source.name))
        XCTAssertEqual(record.spaces, 2)
        XCTAssertEqual(record.pinned, 5)
    }

    func testZIPReadCleansExtractionAndOnlyZIPHistoryMarksSafari() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let export = root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try writeBookmark("From zip", url: "https://zip.example/", to: export.appendingPathComponent("bookmarks.html"))
        let history: [String: Any] = [
            "metadata": ["data_type": "history"],
            "history": [["url": "https://history.example/", "title": "History", "time_usec": 1_000_000, "visits_count": 1]],
        ]
        let historyData = try JSONSerialization.data(withJSONObject: history)
        try historyData.write(to: export.appendingPathComponent("history.json"))

        let archive = root.appendingPathComponent("export.zip")
        try runDitto(arguments: ["-c", "-k", "--sequesterRsrc", export.path, archive.path])
        let tempBefore = officeImportFolders()
        let preCancelled = ImportFile.Control()
        preCancelled.cancel()
        XCTAssertThrowsError(try ImportFile.read(archive, control: preCancelled)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(officeImportFolders(), tempBefore)
        let found = try ImportFile.read(archive)
        XCTAssertEqual(found.bookmarks.map(\.title), ["From zip"])
        XCTAssertEqual(found.places.count, 1)
        XCTAssertTrue(found.fromSafari)
        XCTAssertEqual(officeImportFolders(), tempBefore)

        let ordinary = root.appendingPathComponent("ordinary", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        try historyData.write(to: ordinary.appendingPathComponent("history.json"))
        XCTAssertFalse(try ImportFile.read(ordinary).fromSafari)

        let invalidArchive = root.appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: invalidArchive)
        XCTAssertTrue(try ImportFile.read(invalidArchive).isEmpty)
        XCTAssertEqual(officeImportFolders(), tempBefore)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eden-import-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private func makeImportTestBrowser() -> Browser {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    return Browser(record: WindowRecord())
}

private func makeChromiumSource(name: String) throws -> (Chromium.Source, URL) {
    let folder = "EdenTests/\(UUID().uuidString)"
    let root = Chromium.base.appendingPathComponent(folder, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (Chromium.Source(name: name, folder: folder, service: "Test Safe Storage", account: "Test", app: "Test.app"), root)
}

private func makeProfile(_ name: String, under root: URL) throws -> URL {
    let profile = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    return profile
}

private func chromiumURL(_ title: String, _ url: String) -> [String: Any] {
    ["type": "url", "name": title, "url": url]
}

private func writeChromiumBookmarks(_ entries: [[String: Any]], to profile: URL) throws {
    let bar: [String: Any] = ["children": entries]
    let other: [String: Any] = ["children": [] as [[String: Any]]]
    let synced: [String: Any] = ["children": [] as [[String: Any]]]
    let roots: [String: Any] = ["bookmark_bar": bar, "other": other, "synced": synced]
    let data = try JSONSerialization.data(withJSONObject: ["roots": roots])
    try data.write(to: profile.appendingPathComponent("Bookmarks"), options: .atomic)
}

private func makeArcSidebarFixture(workName: String, personalName: String) throws -> Data {
    func tab(_ id: String, _ title: String, _ url: String) -> [String: Any] {
        ["id": id, "title": title, "data": ["tab": ["savedURL": url, "savedTitle": title]]]
    }

    let items: [[String: Any]] = [
        ["id": "work-pins", "childrenIds": ["work-folder"]],
        ["id": "work-folder", "title": "Research", "data": ["list": [String: Any]()], "childrenIds": ["work-one", "work-two"]],
        tab("work-one", "One", "https://work-one.example/"),
        tab("work-two", "Two", "https://work-two.example/"),
        ["id": "personal-pins", "childrenIds": ["personal-tab"]],
        tab("personal-tab", "Personal page", "https://personal.example/"),
        ["id": "default-favorites", "childrenIds": ["favorite-work"]],
        tab("favorite-work", "Work favourite", "https://favorite-work.example/"),
        ["id": "profile-favorites", "childrenIds": ["favorite-personal"]],
        tab("favorite-personal", "Personal favourite", "https://favorite-personal.example/"),
    ]
    let profileOne: [String: Any] = ["custom": ["_0": ["directoryBasename": "Profile 1"]]]
    let spaces: [[String: Any]] = [
        ["title": workName, "profile": ["default": [String: Any]()],
         "customInfo": ["iconType": ["emoji_v2": "💻"]], "newContainerIDs": ["pinned", "work-pins"]],
        ["title": personalName, "profile": profileOne, "newContainerIDs": ["pinned", "personal-pins"]],
    ]
    let main: [String: Any] = [
        "items": items,
        "spaces": spaces,
        "topAppsContainerIDs": [["default": [String: Any]()], "default-favorites", profileOne, "profile-favorites"],
    ]
    return try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [main]]])
}

/// A bookmarks file of `count` pages in folders of fifty, named for this
/// run: the file, its folder, and the kept group it comes in as.
private func writeLargeBookmarksFile(count: Int) throws -> (file: URL, folder: URL, group: String) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eden-large-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stem = "Large \(UUID().uuidString.prefix(8))"
    var html = "<DL><p>\n"
    for start in stride(from: 0, to: count, by: 50) {
        html += "<DT><H3>Folder \(start / 50)</H3><DL><p>\n"
        for index in start..<min(start + 50, count) {
            html += #"<DT><A HREF="https://large-\#(index).example/page">Page \#(index)</A>"# + "\n"
        }
        html += "</DL><p>\n"
    }
    html += "</DL>\n"
    let file = folder.appendingPathComponent("\(stem).html")
    try html.write(to: file, atomically: true, encoding: .utf8)
    return (file, folder, stem + " Bookmarks")
}

/// The main thread's beat while something runs: a timer on the main queue
/// every two milliseconds, and the longest it went without beating, which
/// is the longest the window couldn't draw or take a click.
@MainActor
private final class MainBeats {
    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private var last = ProcessInfo.processInfo.systemUptime
    private(set) var longest: TimeInterval = 0
    private(set) var beats = 0
    /// Run at each beat, for a test to act mid-import.
    var onBeat: () -> Void = {}

    init() {
        timer.schedule(deadline: .now(), repeating: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.longest = max(self.longest, now - self.last)
                self.last = now
                self.beats += 1
                self.onBeat()
            }
        }
        timer.resume()
    }

    /// Stopped: the time since the last beat counts too, a stall that ran
    /// to the end being the longest of all.
    func stop() -> (longest: TimeInterval, beats: Int) {
        timer.cancel()
        longest = max(longest, ProcessInfo.processInfo.systemUptime - last)
        return (longest, beats)
    }
}

private func writeBookmark(_ title: String, url: String, to file: URL) throws {
    let html = #"<DL><DT><A HREF="\#(url)">\#(title)</A></DL>"#
    try html.write(to: file, atomically: true, encoding: .utf8)
}

private func runDitto(arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
}

private func officeImportFolders() -> Set<String> {
    let items = (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
    return Set(items.filter { $0.lastPathComponent.hasPrefix("office-import-") }.map(\.lastPathComponent))
}
