import CryptoKit
import WebKit
import XCTest
@testable import EdenCore

/// A site's session cookies kept across a quit (SessionCookies): written
/// sealed a moment after they change, put back before a page loads, gone
/// with a fresh start or the store's site data.
@MainActor
final class SessionCookiesTests: XCTestCase {
    private var folder: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("session-cookies-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func keeper() -> SessionCookies {
        let key = key
        return SessionCookies(folder: folder, key: { key })
    }

    private func cookie(_ name: String, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: ".youtube.example", .path: "/", .name: name, .value: "secret-\(name)", .secure: "TRUE",
        ]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    private func names(_ store: WKWebsiteDataStore) async -> [String] {
        await store.httpCookieStore.allCookies().map(\.name).sorted()
    }

    func testASessionCookieComesBackInTheNextRunAndALastingOneIsLeftToWebKit() async throws {
        let before = WKWebsiteDataStore.nonPersistent()
        let first = keeper()
        first.keep(before, as: "space", restoring: true)
        await before.httpCookieStore.setCookie(cookie("wide"))
        await before.httpCookieStore.setCookie(cookie("PREF", expires: Date().addingTimeInterval(86_400)))
        try await Task.sleep(for: .milliseconds(100))
        await first.flush()

        let sealed = try Data(contentsOf: folder.appendingPathComponent("space.sealed"))
        XCTAssertNil(sealed.range(of: Data("secret-wide".utf8)), "sealed, not written in the clear")

        // The next run: a store with nothing in it, as WebKit leaves one.
        let after = WKWebsiteDataStore.nonPersistent()
        let second = keeper()
        second.keep(after, as: "space", restoring: true)
        let back = expectation(description: "back before a page loads")
        second.whenRestored(after) { back.fulfill() }
        await fulfillment(of: [back], timeout: 5)
        let names = await names(after)
        XCTAssertEqual(names, ["wide"], "the session cookie back; the lasting one is WebKit's to keep")
        let restored = await after.httpCookieStore.allCookies()
        let wide = try XCTUnwrap(restored.first)
        XCTAssertTrue(wide.isSessionOnly)
        XCTAssertTrue(wide.isSecure)
        XCTAssertEqual(wide.value, "secret-wide")
    }

    func testAFreshStartForgetsThem() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let first = keeper()
        first.keep(store, as: "space", restoring: true)
        await store.httpCookieStore.setCookie(cookie("wide"))
        try await Task.sleep(for: .milliseconds(100))
        await first.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("space.sealed").path))

        let fresh = WKWebsiteDataStore.nonPersistent()
        let next = keeper()
        next.keep(fresh, as: "space", restoring: false)
        await next.flush()
        let names = await names(fresh)
        XCTAssertEqual(names, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("space.sealed").path))
    }

    func testForgettingAStoreTakesItsFile() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let keeper = keeper()
        keeper.keep(store, as: "space", restoring: true)
        await store.httpCookieStore.setCookie(cookie("wide"))
        try await Task.sleep(for: .milliseconds(100))
        await keeper.flush()
        keeper.forget(store)
        await keeper.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("space.sealed").path))
        keeper.forget(named: "another")
    }

    func testAWrongKeyPutsNothingBack() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let first = keeper()
        first.keep(store, as: "space", restoring: true)
        await store.httpCookieStore.setCookie(cookie("wide"))
        try await Task.sleep(for: .milliseconds(100))
        await first.flush()

        let other = SymmetricKey(size: .bits256)
        let stranger = SessionCookies(folder: folder, key: { other })
        let after = WKWebsiteDataStore.nonPersistent()
        stranger.keep(after, as: "space", restoring: true)
        let back = expectation(description: "done, with nothing")
        stranger.whenRestored(after) { back.fulfill() }
        await fulfillment(of: [back], timeout: 5)
        let names = await names(after)
        XCTAssertEqual(names, [])
    }

    func testClearingWhileTheyAreComingBackPutsNothingBack() async throws {
        let before = WKWebsiteDataStore.nonPersistent()
        let first = keeper()
        first.keep(before, as: "space", restoring: true)
        await before.httpCookieStore.setCookie(cookie("wide"))
        try await Task.sleep(for: .milliseconds(100))
        await first.flush()

        // Clear Website Data opening a space's store, and so its restore,
        // and clearing it at once.
        let after = WKWebsiteDataStore.nonPersistent()
        let second = keeper()
        second.keep(after, as: "space", restoring: true)
        second.cleared(after)
        var went = false
        second.whenRestored(after) { went = true }
        XCTAssertTrue(went, "nothing to wait for once cleared")
        try await Task.sleep(for: .milliseconds(300))
        await second.flush()
        let names = await names(after)
        XCTAssertEqual(names, [], "what was cleared stays cleared")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("space.sealed").path))
    }

    func testAFlushWaitsForTheWriteAlreadyUnderWay() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let keeper = keeper()
        keeper.keep(store, as: "space", restoring: true)
        await store.httpCookieStore.setCookie(cookie("wide"))
        // Past the settling, the write begun: a flush now still waits for it.
        try await Task.sleep(for: .milliseconds(520))
        await keeper.flush()
        XCTAssertFalse(keeper.unwritten)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("space.sealed").path))
    }

    func testWithTheDeviceLockedTheyWaitForItToOpen() async throws {
        let before = WKWebsiteDataStore.nonPersistent()
        let first = keeper()
        first.keep(before, as: "space", restoring: true)
        await before.httpCookieStore.setCookie(cookie("wide"))
        try await Task.sleep(for: .milliseconds(100))
        await first.flush()

        // Launched in the background before the first unlock: no key yet.
        let lock = Lock(key: key)
        let locked = SessionCookies(folder: folder, key: { lock.key })
        locked.protectedData(open: false)
        let after = WKWebsiteDataStore.nonPersistent()
        locked.keep(after, as: "space", restoring: true)
        var went = false
        locked.whenRestored(after) { went = true }
        await locked.flush()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(went, "pages wait rather than load signed out")

        lock.open()
        locked.protectedData(open: true)
        let back = expectation(description: "back once it opens")
        locked.whenRestored(after) { back.fulfill() }
        await fulfillment(of: [back], timeout: 5)
        XCTAssertTrue(went)
        let names = await names(after)
        XCTAssertEqual(names, ["wide"])
    }

    func testAStoreNotKeptLoadsAtOnce() {
        var went = false
        keeper().whenRestored(.nonPersistent()) { went = true }
        XCTAssertTrue(went)
    }
}

/// A key not to be had until the device is unlocked.
private final class Lock: @unchecked Sendable {
    private let unlocked: SymmetricKey
    private let state = NSLock()
    private var isOpen = false

    init(key: SymmetricKey) { unlocked = key }

    var key: SymmetricKey? {
        state.lock()
        defer { state.unlock() }
        return isOpen ? unlocked : nil
    }

    func open() {
        state.lock()
        isOpen = true
        state.unlock()
    }
}
