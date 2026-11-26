import AppKit
import Combine
import WebKit
import XCTest
@testable import Eden

/// Try again, and ⌘R, on a page that never arrived. A tab woken offline
/// from its history had nothing in its view for WebKit to reload, and
/// every reload went nowhere once the connection was back (#62). A link
/// that failed was retried as the page it was on.
@MainActor
final class RetryFailedLoadTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["EDEN_PROBE"] == nil {
            setenv("EDEN_PROBE", "retry-failed-load-\(getpid())", 1)
        }
        super.setUp()
    }

    func testATabWokenOfflineComesBackOnReload() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let first = try LocalPageServer(["/": Self.page("Alive")])
        let port = first.port
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        let window = Self.window()
        defer { window.close() }
        window.contentView = tab.web
        tab.go(to: first.url("/"))
        try await until("the page loads") { await self.title(tab.web) == "Alive" }

        // Asleep, then woken from its history with the site gone.
        tab.sleep(picture: nil)
        first.stop()
        XCTAssertTrue(tab.wake())
        window.contentView = tab.web
        try await until("the woken page says it didn't come") { tab.failure != nil }

        // The site is back; Try again asks for it.
        let back = try LocalPageServer(["/": Self.page("Alive")], port: port)
        defer { back.stop() }
        tab.reload()
        XCTAssertNil(tab.failure)
        try await until("Try again brings the page back") { await self.title(tab.web) == "Alive" }
        XCTAssertNil(tab.failure)
        XCTAssertEqual(back.requests, ["/"])
    }

    /// What happened on the Mac: the woken page still trying, offline, and
    /// ⌘R pressed while it did. WebKit has no page in the view to reload, so
    /// drops the reload, but goes on reporting its address as one on its
    /// way; the tab then looked like it had a page, and every reload after
    /// the failure was asked of WebKit and dropped the same way.
    func testAReloadWhileAWokenPageIsStillComingDoesNotStrandIt() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let first = try LocalPageServer(["/": Self.page("Alive")])
        let port = first.port
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        let window = Self.window()
        defer { window.close() }
        window.contentView = tab.web
        tab.go(to: first.url("/"))
        try await until("the page loads") { await self.title(tab.web) == "Alive" }

        // Asleep, then woken onto a site that takes the request and never
        // answers.
        tab.sleep(picture: nil)
        first.stop()
        var stalling = LocalPageServer.Page(type: "text/html", body: "")
        stalling.hangs = true
        let silent = try LocalPageServer(["/": stalling], port: port)
        // Held requests keep it serving until it is stopped, so a wait below
        // that gives up must not leave it running.
        defer { silent.stop() }
        XCTAssertTrue(tab.wake())
        window.contentView = tab.web
        try await until("the woken page is asked for") { silent.requests == ["/"] }

        tab.reload()
        // The connection goes; the page never came.
        silent.stop()
        try await until("the woken page says it didn't come") { tab.failure != nil }

        let back = try LocalPageServer(["/": Self.page("Alive")], port: port)
        defer { back.stop() }
        tab.reload()
        XCTAssertNil(tab.failure)
        try await until("Try again brings the page back") { await self.title(tab.web) == "Alive" }
        XCTAssertNil(tab.failure)
    }

    /// A link clicked on the page, which leaves the tab's address and card
    /// to WebKit, as `go(to:)` doesn't.
    func testTryAgainOnAFailedLinkAsksForTheLink() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let port = try Self.freePort()
        let link = "<!doctype html><title>Here</title><a id=go href='http://127.0.0.1:\(port)/'>There</a>"
        let here = try LocalPageServer(["/": .init(type: "text/html; charset=utf-8", body: link, uncached: true)])
        defer { here.stop() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        let window = Self.window()
        defer { window.close() }
        window.contentView = tab.web
        tab.go(to: here.url("/"))
        try await until("the first page loads") { await self.title(tab.web) == "Here" }

        _ = try await tab.web.evaluateJavaScript("document.getElementById('go').click(); true")
        try await until("the link says it didn't come") { tab.failure != nil }

        let back = try LocalPageServer(["/": Self.page("There")], port: port)
        defer { back.stop() }
        tab.reload()
        try await until("Try again goes where the link went") { await self.title(tab.web) == "There" }
        XCTAssertNil(tab.failure)
        XCTAssertEqual(Self.pages(here), 1, "the page the link was on is not reloaded instead")
    }

    /// A form that failed is not sent again as a plain visit to where it
    /// was going, which would arrive without what was filled in: Try again
    /// reloads as it always did, here the page the form is on.
    func testTryAgainOnAFailedFormDoesNotVisitItsAddress() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let port = try Self.freePort()
        let here = try LocalPageServer(["/": Self.form(posting: port)])
        defer { here.stop() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        let window = Self.window()
        defer { window.close() }
        window.contentView = tab.web
        tab.go(to: here.url("/"))
        try await until("the form loads") { await self.title(tab.web) == "Form" }

        _ = try await tab.web.evaluateJavaScript("document.forms[0].submit(); true")
        try await until("the form says it didn't go") { tab.failure != nil }

        let back = try LocalPageServer(["/send": Self.page("Sent")], port: port)
        defer { back.stop() }
        tab.reload()
        try await until("Try again reloads the form's page") {
            Self.pages(here) == 2 && tab.failure == nil
        }
        XCTAssertEqual(back.requests, [], "the form's address is not visited without the form")
    }

    /// A link that failed, then a form the page behind it sent that failed
    /// too: Try again is for the form, which reloads, not the link.
    func testAFormFailingAfterALinkDoesNotRetryTheLink() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let port = try Self.freePort()
        let here = try LocalPageServer(["/": Self.form(posting: port)])
        defer { here.stop() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        let window = Self.window()
        defer { window.close() }
        window.contentView = tab.web
        tab.go(to: here.url("/"))
        try await until("the form loads") { await self.title(tab.web) == "Form" }

        // Each failure said, the second over the first's card.
        var failures = 0
        let counting = tab.$failure.dropFirst().sink { if $0 != nil { failures += 1 } }
        defer { counting.cancel() }
        tab.go(to: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/link")))
        try await until("the link says it didn't come") { failures == 1 }
        _ = try await tab.web.evaluateJavaScript("document.forms[0].submit(); true")
        try await until("the form says it didn't go") { failures == 2 }
        XCTAssertNotNil(tab.failure)

        let back = try LocalPageServer(["/link": Self.page("Link"), "/send": Self.page("Sent")], port: port)
        defer { back.stop() }
        tab.reload()
        try await until("Try again reloads the form's page") {
            Self.pages(here) == 2 && tab.failure == nil
        }
        XCTAssertEqual(back.requests, [], "neither the link nor the form's address is visited")
    }

    /// A port with nothing behind it, for now.
    private static func freePort() throws -> UInt16 {
        let gone = try LocalPageServer([:])
        gone.stop()
        return gone.port
    }

    /// How many times the form's own page was asked for, its icon aside.
    private static func pages(_ server: LocalPageServer) -> Int {
        server.requests.filter { $0 == "/" }.count
    }

    private static func form(posting port: UInt16) -> LocalPageServer.Page {
        .init(type: "text/html; charset=utf-8",
              body: "<!doctype html><title>Form</title>"
                  + "<form method=post action='http://127.0.0.1:\(port)/send'><input name=q value=filled></form>",
              uncached: true)
    }

    private static func page(_ title: String) -> LocalPageServer.Page {
        .init(type: "text/html; charset=utf-8", body: "<!doctype html><title>\(title)</title><p>\(title)</p>", uncached: true)
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The page's title, or nil for a page that can't answer.
    private func title(_ web: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            var answered = false
            let answer = { (title: String?) in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: title)
            }
            web.evaluateJavaScript("document.title") { value, error in
                answer(error == nil ? value as? String : nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { answer(nil) }
        }
    }

    private func until(_ what: String, timeout: TimeInterval = 15, _ check: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await check() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting: \(what)")
        throw CancellationError()
    }
}
