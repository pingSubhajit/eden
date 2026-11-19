import AppKit
import EdenCore
import WebKit
import XCTest
@testable import Eden

/// The Mac keeps its stores' session cookies (SessionCookies): the store a
/// tab is given has its session written down, sealed, and Clear Website
/// Data takes it.
@MainActor
final class SessionCookiesWiringTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "session-cookies-\(getpid())", 1)
        super.setUp()
    }

    private var saved: URL { Store.file("Session cookies") }

    func testATabsStoreHasItsSessionWrittenDownAndClearWebsiteDataTakesIt() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let store = Spaces.store(for: browser.spaceID)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".wiring.example", .path: "/", .name: "wide", .value: "1",
        ]))
        await store.httpCookieStore.setCookie(cookie)
        try await Task.sleep(for: .milliseconds(100))
        await SessionCookies.shared.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: saved.path)
        XCTAssertFalse(files.isEmpty, "the session written down")

        // Pages wait for nothing once it is back.
        var went = false
        SessionCookies.shared.whenRestored(store) { went = true }
        XCTAssertTrue(went)

        browser.clearSites()
        await SessionCookies.shared.flush()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: saved.path)) ?? []
        XCTAssertTrue(left.isEmpty, "gone with the site data")
    }

    func testAPrivateTabsStoreIsNeverKept() {
        var went = false
        SessionCookies.shared.whenRestored(.nonPersistent()) { went = true }
        XCTAssertTrue(went, "nothing to wait for, and nothing written")
    }
}
