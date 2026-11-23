import AppKit
import EdenCore
import SwiftUI
import WebKit
import XCTest
@testable import Eden

/// What fifteen hundred pinned rows in folded folders cost a window (#9):
/// taking them in, opening another window once they are there, and every
/// window following a change to one of them. Measures, not checks: runs
/// only with PIN_COST set (`PIN_COST=1 swift test --filter PinCostTests`),
/// and prints what it measured as PIN-COST lines, so one build can be set
/// beside another. HeldPinsTests checks what is held.
@MainActor
final class PinCostTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []

    override class func setUp() {
        setenv("EDEN_PROBE", "pin-cost-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["PIN_COST"] == nil, "PIN_COST not set")
        try await super.setUp()
        CleanWorld.reset()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("pin-cost-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.subhajit.eden.beta.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers {
            Pins.setGroups(browser.spaceID, [], from: nil)
            browser.closeAll()
            CleanWorld.reset(space: browser.spaceID)
        }
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(200))
        try await super.tearDown()
    }

    // MARK: - measured

    /// 1,500 bookmarks in 30 folders of 50 taken in as pinned rows, their
    /// groups folded, then a second window opened on the space and drawn.
    func testMeasureFifteenHundredPinsInFoldedFolders() async throws {
        let first = makeBrowser()
        host(first)
        try await settle()

        let nodes = Self.folders(30, of: 50)
        var began = CACurrentMediaTime()
        let took = first.pinShelf.take(nodes, into: nil)
        let taking = CACurrentMediaTime() - began
        XCTAssertEqual(took.added, 1_500)
        for group in first.keptGroups where !group.collapsed { first.setGroupFolded(group.id, true) }
        first.writeSession(now: true)
        try await settle()

        began = CACurrentMediaTime()
        let second = makeBrowser()
        let making = CACurrentMediaTime() - began
        host(second)
        drain()
        let opening = CACurrentMediaTime() - began
        try await settle()

        // One pin renamed in the first window: the second follows.
        let renamed = try XCTUnwrap(Pins.defs(first.spaceID).first)
        began = CACurrentMediaTime()
        first.pinShelf.update(renamed.id, title: "Renamed", url: nil)
        let following = CACurrentMediaTime() - began

        print("PIN-COST take 1500: \(Self.ms(taking)) ms; tabs in the first window: \(first.tabs.count)")
        print("PIN-COST new window: \(Self.ms(making)) ms made, \(Self.ms(opening)) ms drawn; tabs: \(second.tabs.count)")
        print("PIN-COST a pin renamed, both windows following: \(Self.ms(following)) ms")
        XCTAssertEqual(Pins.defs(first.spaceID).count, 1_500)
    }

    /// Half of them on show: 750 rows in 15 open folders are tabs, 750 in
    /// 15 folded ones are held. Every pin held is looked for among the tabs
    /// and not found, which is what a window does each time the pins change.
    func testMeasureHalfOfThemUnfolded() async throws {
        let first = makeBrowser()
        host(first)
        try await settle()
        first.pinShelf.take(Self.folders(30, of: 50), into: nil)
        for (n, group) in first.keptGroups.enumerated() { first.setGroupFolded(group.id, n.isMultiple(of: 2)) }
        first.writeSession(now: true)
        try await settle()
        XCTAssertEqual(first.tabs.filter { $0.pin != nil }.count, 750)

        var began = CACurrentMediaTime()
        let second = makeBrowser()
        let making = CACurrentMediaTime() - began
        host(second)
        drain()
        try await settle()

        began = CACurrentMediaTime()
        for _ in 0..<10 { first.pinsChanged(in: first.spaceID) }
        let reading = (CACurrentMediaTime() - began) / 10

        let renamed = try XCTUnwrap(Pins.defs(first.spaceID).first)
        began = CACurrentMediaTime()
        first.pinShelf.update(renamed.id, title: "Renamed", url: nil)
        let following = CACurrentMediaTime() - began

        print("PIN-COST half unfolded, new window: \(Self.ms(making)) ms made; tabs: \(second.tabs.count)")
        print("PIN-COST half unfolded, the pins read again: \(Self.ms(reading)) ms a time")
        print("PIN-COST half unfolded, a pin renamed, both windows following: \(Self.ms(following)) ms")
    }

    /// 750 folded folders of two rows each, every row held, so the window
    /// has no tab in any of them: what putting its pins in order again
    /// costs (Browser.reconcilePins, as every window does on any change
    /// to a pin), and drawing the kept area, each laying out 750 folders
    /// with nothing in them.
    func testMeasureManyFoldedFoldersOfTwo() async throws {
        let browser = makeBrowser()
        browser.pinShelf.take(Self.folders(750, of: 2), into: nil)
        for group in browser.keptGroups where !group.collapsed { browser.setGroupFolded(group.id, true) }
        XCTAssertEqual(browser.tabs.filter { $0.pin != nil }.count, 0)
        XCTAssertEqual(browser.heldRows.count, 1_500)

        var began = CACurrentMediaTime()
        for _ in 0..<10 { browser.pinsChanged(in: browser.spaceID) }
        let ordering = (CACurrentMediaTime() - began) / 10
        began = CACurrentMediaTime()
        for _ in 0..<10 { _ = browser.keptItems() }
        let drawing = (CACurrentMediaTime() - began) / 10
        XCTAssertEqual(browser.keptGroups.count, 750)
        print("PIN-COST 750 folded folders of two, the pins put in order: \(Self.ms(ordering)) ms a time")
        print("PIN-COST 750 folded folders of two, the kept area drawn: \(Self.ms(drawing)) ms a time")
    }

    /// 1,500 rows held in folded folders, every one of them an extension's
    /// adapter after a full chrome.tabs.query: the pins read again, as every
    /// window does on any change to a pin, each time putting the adapters
    /// right (Extensions.rowsSettled), and that alone.
    func testMeasureAdaptersKeptRightThroughEveryRead() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("extensions need macOS 15.4") }
        let browser = makeBrowser()
        Browsers.register(browser)
        defer { Browsers.discard(browser) }
        browser.pinShelf.take(Self.folders(30, of: 50), into: nil)
        for group in browser.keptGroups where !group.collapsed { browser.setGroupFolded(group.id, true) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pin-cost-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Pin cost", "version": "1", "permissions": ["tabs"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.uniqueIdentifier = "pin-cost-\(UUID().uuidString)"
        context.setPermissionStatus(.grantedExplicitly, for: .tabs)
        XCTAssertEqual(Extensions.shared.visibleRows(of: browser, for: context).count, 1_500, "an adapter for every held row")

        var began = CACurrentMediaTime()
        for _ in 0..<10 { browser.pinsChanged(in: browser.spaceID) }
        let reading = (CACurrentMediaTime() - began) / 10
        began = CACurrentMediaTime()
        for _ in 0..<10 { Extensions.shared.rowsSettled(in: browser) }
        let settling = (CACurrentMediaTime() - began) / 10
        print("PIN-COST 1500 held adapters, the pins read again: \(Self.ms(reading)) ms a time")
        print("PIN-COST 1500 held adapters, kept right (rowsSettled): \(Self.ms(settling)) ms a time")
    }

    /// 750 folded folders of two rows each, every row held: what ⌘1–9
    /// works out its targets from, and the hints shown while ⌘ is held,
    /// each finding the row of every folder looked at last.
    func testMeasureNumberKeysAmongManyFolded() async throws {
        let browser = makeBrowser()
        browser.pinShelf.take(Self.folders(750, of: 2), into: nil)
        for group in browser.keptGroups where !group.collapsed { browser.setGroupFolded(group.id, true) }
        XCTAssertEqual(browser.heldRows.count, 1_500)
        var began = CACurrentMediaTime()
        for _ in 0..<10 { XCTAssertEqual(browser.tabShortcutTargets.count, 750) }
        let targets = (CACurrentMediaTime() - began) / 10
        let shows = browser.prefs.showsTabShortcuts
        defer { browser.prefs.showsTabShortcuts = shows }
        browser.prefs.showsTabShortcuts = true
        browser.commandHeld = true
        began = CACurrentMediaTime()
        for _ in 0..<10 { XCTAssertEqual(browser.tabShortcutNumbers.count, 9) }
        let hints = (CACurrentMediaTime() - began) / 10
        print("PIN-COST ⌘1–9 among 750 folded folders, the targets: \(Self.ms(targets)) ms a time")
        print("PIN-COST ⌘1–9 among 750 folded folders, the hints: \(Self.ms(hints)) ms a time")
    }

    /// The same 1,500 brought in from a bookmarks file, as Import does it.
    func testMeasureFifteenHundredPinsFromAFile() async throws {
        let first = makeBrowser()
        host(first)
        try await settle()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eden-pin-cost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var html = "<DL><p>\n"
        for f in 0..<30 {
            html += "<DT><H3>Folder \(f)</H3><DL><p>\n"
            for p in 0..<50 { html += #"<DT><A HREF="https://pin-cost-file-\#(f * 50 + p).example/">Page \#(f * 50 + p)</A>"# + "\n" }
            html += "</DL><p>\n"
        }
        html += "</DL>\n"
        let file = folder.appendingPathComponent("Pin Cost.html")
        try html.write(to: file, atomically: true, encoding: .utf8)

        let began = CACurrentMediaTime()
        let took = await first.takeFile(file)
        let taking = CACurrentMediaTime() - began
        XCTAssertEqual(took.bookmarks, 1_500)
        try await settle()

        let opened = CACurrentMediaTime()
        let second = makeBrowser()
        host(second)
        drain()
        let opening = CACurrentMediaTime() - opened
        print("PIN-COST file of 1500: \(Self.ms(taking)) ms; tabs in the first window: \(first.tabs.count)")
        print("PIN-COST new window after the file: \(Self.ms(opening)) ms drawn; tabs: \(second.tabs.count)")
    }

    // MARK: - the pieces

    /// `count` folders of `size` pages each, every page its own site.
    static func folders(_ count: Int, of size: Int, site: String = "pin-cost") -> [Bookmark] {
        (0..<count).map { f in
            Bookmark(title: "Folder \(f)", url: nil, children: (0..<size).map { p in
                let n = f * size + p
                return Bookmark(title: "Page \(n)", url: "https://\(site)-\(n).example/", children: nil)
            })
        }
    }

    static func ms(_ seconds: CFTimeInterval) -> Int { Int((seconds * 1000).rounded()) }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browsers.append(browser)
        return browser
    }

    /// The whole window, drawn off every screen.
    private func host(_ browser: Browser) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000 + CGFloat(windows.count) * 1000, width: 1200, height: 900),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(browser: browser))
        browser.window = window
        window.orderFrontRegardless()
        windows.append(window)
    }

    private func drain() {
        RunLoop.current.run(mode: .default, before: Date())
        for window in windows {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func settle() async throws {
        drain()
        try await Task.sleep(for: .milliseconds(300))
        drain()
    }
}
