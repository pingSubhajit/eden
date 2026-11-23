import EdenCore
import AppKit
import SwiftUI
import XCTest
@testable import Eden

/// The tab you go to is scrolled into sight in a column too long for its
/// window (#29): the column scrolls to the row named by the tab's id, and
/// when its rows became pieces named by the layout's own kind of id, no row
/// answered to a tab's id and the column stayed where it was. Hosted as
/// PairSeparateTests does, in a borderless window far off every screen.
@MainActor
final class ColumnScrollToTests: XCTestCase {
    private var browser: Browser?
    private var window: NSWindow?
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        setenv("EDEN_PROBE", "column-scroll-to-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("column-scroll-to-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.subhajit.eden.beta.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        window?.contentView = nil
        window?.close()
        browser?.window = nil
        browser?.closeAll()
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        window = nil
        browser = nil
        try await Task.sleep(for: .milliseconds(250))
        try await super.tearDown()
    }

    func testTheTabGoneToIsScrolledIntoSight() async throws {
        let (browser, tabs, window) = try await setUpColumn()
        let scroll = try XCTUnwrap(column(in: window), "the column's scroll view")
        let content = try XCTUnwrap(scroll.documentView).frame.height
        let visible = scroll.contentView.bounds.height
        XCTAssertGreaterThan(content, visible + 100, "more rows than room")

        browser.select(tabs[tabs.count - 1])
        try await until { scroll.contentView.bounds.minY + visible >= content - 40 }
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.minY + visible, content - 40,
                                    "down at the last tab")

        browser.select(tabs[0])
        try await until { scroll.contentView.bounds.minY < 40 }
        XCTAssertLessThan(scroll.contentView.bounds.minY, 40, "back up at the first")
    }

    // MARK: - helpers

    private func setUpColumn() async throws -> (Browser, [Eden.Tab], NSWindow) {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.usesTabGroups, prefs.splitView, prefs.roomyTabs, prefs.newTabPlace)
        restorePreferences = {
            (prefs.usesTabGroups, prefs.splitView, prefs.roomyTabs, prefs.newTabPlace) = previous
        }
        // Whatever an earlier suite left in this process's one world — its
        // pins, a square among them, or its saved tabs — is not this
        // column's (CleanWorld).
        CleanWorld.reset()
        let browser = Browser(record: WindowRecord())
        self.browser = browser
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = false
        browser.prefs.roomyTabs = false
        // Each new tab after the last, so the last made is the last row.
        browser.prefs.newTabPlace = .next
        for number in 1...30 {
            if browser.tabs.last?.isBlank != true { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        let tabs = browser.tabs
        XCTAssertEqual(tabs.count, 30, "only this test's tabs")
        XCTAssertTrue(tabs.allSatisfy { $0.pin == nil }, "no pins")
        browser.select(tabs[0])
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs))
        window.orderFrontRegardless()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        self.window = window
        browser.window = window
        try await settle()
        return (browser, tabs, window)
    }

    /// The scroll view holding the rows: the tallest document of those in
    /// the window.
    private func column(in window: NSWindow) -> NSScrollView? {
        func scrolls(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
        }
        return window.contentView.map(scrolls)?.max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    /// Until `done`, or ten seconds: a scroll's spring takes longer on a
    /// busy Mac than a fixed wait allows.
    private func until(_ done: () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !done(), Date() < end { try await Task.sleep(for: .milliseconds(50)) }
    }
}
