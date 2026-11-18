import EdenCore
import AppKit
import WebKit
import XCTest
@testable import Eden

/// Handoff (Handoff.swift): what a tab offers your other devices, what Eden
/// takes from them, and a window's activity as its tab in front changes.
@MainActor
final class HandoffTests: XCTestCase {
    private var browser: Browser!
    private var window: NSWindow!
    private var oldHandsOff = false

    override class func setUp() {
        setenv("EDEN_PROBE", "handoff-\(getpid())", 1)
        super.setUp()
    }

    /// The world this suite made, when it was the one that named it: gone
    /// with its settings, as the other suites leave theirs.
    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("handoff-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.subhajit.eden.beta.test.\(world)")
        }
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        oldHandsOff = browser.prefs.handsOff
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
    }

    override func tearDown() {
        browser?.prefs.handsOff = oldHandsOff
        browser?.closeAll()
        browser = nil
        window = nil
        super.tearDown()
    }

    private let page = URL(string: "https://example.com/article?id=7")!

    // MARK: - what a tab offers

    func testAnOrdinaryWebPageIsOfferedWhenTurnedOn() {
        XCTAssertEqual(Handoff.offered(page, on: true, private: false, bench: false, popup: false), page)
        let plain = URL(string: "HTTP://example.com/")!
        XCTAssertEqual(Handoff.offered(plain, on: true, private: false, bench: false, popup: false), plain)
    }

    func testNothingIsOfferedWhenTurnedOff() {
        XCTAssertNil(Handoff.offered(page, on: false, private: false, bench: false, popup: false))
    }

    func testPrivateBenchAndPopupTabsOfferNothing() {
        XCTAssertNil(Handoff.offered(page, on: true, private: true, bench: false, popup: false))
        XCTAssertNil(Handoff.offered(page, on: true, private: false, bench: true, popup: false))
        XCTAssertNil(Handoff.offered(page, on: true, private: false, bench: false, popup: true))
    }

    func testOnlyWebPagesAreOffered() {
        for text in ["eden://settings", "file:///Users/someone/notes.html", "about:blank", "data:text/html,hi",
                     "chrome-extension://abcdefghijklmnop/popup.html", "https:///nohost",
                     "https://someone:secret@example.com/", "https://someone@example.com/"] {
            XCTAssertNil(Handoff.offered(URL(string: text), on: true, private: false, bench: false, popup: false), text)
        }
        XCTAssertNil(Handoff.offered(nil, on: true, private: false, bench: false, popup: false))
    }

    // MARK: - what Eden takes

    private func activity(_ type: String, _ text: String?) -> NSUserActivity {
        let activity = NSUserActivity(activityType: type)
        activity.webpageURL = text.flatMap(URL.init(string:))
        return activity
    }

    func testEdensOwnAndTheSystemsWebActivitiesAreTaken() {
        XCTAssertEqual(Handoff.received(activity(Handoff.browsing, page.absoluteString)), page)
        XCTAssertEqual(Handoff.received(activity(NSUserActivityTypeBrowsingWeb, page.absoluteString)), page)
    }

    func testOtherActivitiesAndNonWebPagesAreNotTaken() {
        XCTAssertNil(Handoff.received(activity("com.example.notes.editing", page.absoluteString)))
        // A file: or javascript: page can't come at all: NSUserActivity
        // refuses any webpageURL that isn't http or https, with an exception.
        XCTAssertNil(Handoff.received(activity(Handoff.browsing, "https://user:pass@example.com/")))
        XCTAssertNil(Handoff.received(activity(Handoff.browsing, nil)))
    }

    // MARK: - the title

    func testTitleIsTheTabsNameElseThePagesElseNone() {
        XCTAssertEqual(Handoff.title(name: "Reading", page: "Example Domain"), "Reading")
        XCTAssertEqual(Handoff.title(name: nil, page: "  Example Domain \n"), "Example Domain")
        XCTAssertNil(Handoff.title(name: nil, page: "   "))
        XCTAssertNil(Handoff.title(name: "  ", page: "Example Domain"))
    }

    // MARK: - a window's activity

    func testAWindowHoldsOneActivityThatFollowsItsTab() throws {
        let a = UUID(), b = UUID()
        Handoff.offer(page, title: "Article", for: a, in: window)
        let first = try XCTUnwrap(window.userActivity)
        XCTAssertEqual(first.activityType, Handoff.browsing)
        XCTAssertEqual(first.webpageURL, page)
        XCTAssertEqual(first.title, "Article")
        XCTAssertTrue(first.isEligibleForHandoff)
        XCTAssertFalse(first.isEligibleForSearch)
        XCTAssertFalse(first.isEligibleForPublicIndexing)

        // Another tab comes in front: the same activity, now its page.
        let other = URL(string: "https://example.org/")!
        Handoff.offer(other, title: nil, for: b, in: window)
        XCTAssertTrue(window.userActivity === first)
        XCTAssertEqual(window.userActivity?.webpageURL, other)
        XCTAssertNil(window.userActivity?.title)

        // The old tab's view going after the new one came leaves it alone.
        Handoff.withdraw(a, from: window)
        XCTAssertEqual(window.userActivity?.webpageURL, other)
        XCTAssertEqual(Handoff.offered(in: window)?.address, other)

        // The tab in front's view going takes the offer away.
        Handoff.withdraw(b, from: window)
        XCTAssertNil(window.userActivity)
        XCTAssertNil(Handoff.offered(in: window))
    }

    func testOfferingNothingWithdrawsAndANewOfferStartsAfresh() throws {
        let a = UUID()
        Handoff.offer(page, title: nil, for: a, in: window)
        let first = try XCTUnwrap(window.userActivity)
        Handoff.offer(nil, title: nil, for: a, in: window)
        XCTAssertNil(window.userActivity)
        Handoff.offer(page, title: nil, for: a, in: window)
        let second = try XCTUnwrap(window.userActivity)
        XCTAssertFalse(second === first, "an invalidated activity is never advertised again")
    }

    func testEachWindowHasItsOwn() throws {
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                             backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        let a = UUID(), b = UUID()
        Handoff.offer(page, title: nil, for: a, in: window)
        Handoff.offer(URL(string: "https://example.org/")!, title: nil, for: b, in: other)
        XCTAssertFalse(try XCTUnwrap(window.userActivity) === other.userActivity)
        Handoff.withdraw(a, from: window)
        XCTAssertNil(window.userActivity)
        XCTAssertEqual(other.userActivity?.webpageURL, URL(string: "https://example.org/"))
        Handoff.withdraw(b, from: other)
    }

    // MARK: - a tab and the switch

    private func tab(_ url: URL, title: String, shy: Bool = false) -> Tab {
        let tab = Tab(shy: shy, configuration: Web.configuration(space: browser.spaceID))
        tab.restore(url: url, title: title)
        return tab
    }

    func testApplyOffersTheTabsPageOnlyWithTheSwitchOn() {
        let reading = tab(page, title: "Article")
        browser.prefs.handsOff = false
        Handoff.apply(reading, in: browser, window: window)
        XCTAssertNil(window.userActivity)

        browser.prefs.handsOff = true
        Handoff.apply(reading, in: browser, window: window)
        XCTAssertEqual(window.userActivity?.webpageURL, page)
        XCTAssertEqual(window.userActivity?.title, "Article")

        browser.prefs.handsOff = false
        Handoff.apply(reading, in: browser, window: window)
        XCTAssertNil(window.userActivity)
    }

    func testApplyOffersNothingForAPrivateTab() {
        browser.prefs.handsOff = true
        let hidden = tab(page, title: "Article", shy: true)
        Handoff.apply(hidden, in: browser, window: window)
        XCTAssertNil(window.userActivity)
    }

    func testApplyNamesTheActivityForTheTabsOwnName() {
        browser.prefs.handsOff = true
        let reading = tab(page, title: "Example Domain")
        reading.name = "Reading"
        Handoff.apply(reading, in: browser, window: window)
        XCTAssertEqual(window.userActivity?.title, "Reading")
        Handoff.withdraw(reading.id, from: window)
    }
}
