import AppKit
import Combine
import WebKit
import XCTest
@testable import Eden

/// Try again, and ⌘R, on a page that never arrived. A tab woken offline
/// from its history had nothing in its view for WebKit to reload, and
/// every reload went nowhere once the connection was back (#62). A link
/// that failed was retried as the page it was on, a form in a tab of its
/// own as a plain visit (#64), and a peek never said it had failed (#63).
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

    /// A form that didn't go, sent from a page still in the view: the card
    /// says so, and Back to the Form takes it off the page, still filled in,
    /// to send again from there. Nothing is sent or reloaded meanwhile, and
    /// the form's address is never visited without it.
    func testAFormThatDidntGoGoesBackToItsPageStillFilledIn() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let (browser, tab, here, port, window) = try await failedForm(typing: "typed")
        defer { browser.closeAll(); window.close(); here.stop() }
        XCTAssertEqual(tab.failure, "The form didn't go.")
        XCTAssertEqual(tab.retryTitle, "Back to the Form")

        let back = try LocalPageServer(["/send": Self.page("Sent")], port: port)
        defer { back.stop() }
        tab.reload()
        XCTAssertNil(tab.failure)
        let filled = try await tab.web.evaluateJavaScript("document.forms[0].q.value") as? String
        XCTAssertEqual(filled, "typed", "what was filled in is still there")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(Self.pages(here), 1, "the form's page isn't reloaded")
        XCTAssertEqual(back.heard, [], "the form isn't sent, nor its address visited")
    }

    /// A link that failed, then a form the page behind it sent that failed
    /// too: the card is the form's, not the link's.
    func testAFormFailingAfterALinkGoesBackToTheForm() async throws {
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
        XCTAssertEqual(tab.retryTitle, "Back to the Form")

        let back = try LocalPageServer(["/link": Self.page("Link"), "/send": Self.page("Sent")], port: port)
        defer { back.stop() }
        tab.reload()
        XCTAssertNil(tab.failure)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(back.heard, [], "neither the link nor the form's address is visited")
    }

    /// A form that opened a tab of its own and didn't go: the tab held
    /// only the form's address, which Try again sent as a plain visit,
    /// without the form (#64). It forgets it, and closes, and you are back
    /// on the form's page, still filled in, told to send it again from
    /// there. One opened by hand stays, as a new tab.
    func testAFormThatOpenedATabOfItsOwnClosesBackToItsPage() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let port = try Self.freePort()
        let here = try LocalPageServer(["/": Self.form(posting: port)])
        defer { here.stop() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        let form = try XCTUnwrap(browser.active)
        let window = Self.window()
        defer { window.close() }
        window.contentView = form.web
        form.go(to: here.url("/"))
        try await until("the form loads") { await self.title(form.web) == "Form" }
        let send = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/send"))

        // As the form's own new tab: opened by its page.
        browser.newTab()
        let own = try XCTUnwrap(browser.active)
        own.opener = form.id
        window.contentView = own.web
        own.web.load(Self.posting(to: send))
        try await until("its tab goes") { !browser.tabs.contains { $0 === own } }
        XCTAssertNil(own.address, "the form's address is forgotten")
        XCTAssertEqual(browser.activeID, form.id, "back on the form's page")
        XCTAssertEqual(browser.announcement, "The form didn't go. Send it again from its page.")

        // Opened by hand: it stays, a new tab.
        browser.newTab()
        let mine = try XCTUnwrap(browser.active)
        window.contentView = mine.web
        mine.web.load(Self.posting(to: send))
        try await until("its address is forgotten") { mine.address == nil && mine.committed == nil && !mine.loading }
        XCTAssertTrue(browser.tabs.contains { $0 === mine })
        XCTAssertNil(mine.failure)
        let back = try LocalPageServer(["/send": Self.page("Sent")], port: port)
        defer { back.stop() }
        mine.reload()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(back.heard, [], "nothing is sent, nor its address visited")
    }

    /// The same, the form's new window a small window: it closes, nothing
    /// left in it, and the window it came from says why.
    func testAFormThatOpenedASmallWindowClosesIt() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let port = try Self.freePort()
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        let from = try XCTUnwrap(browser.active)
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.prepare(tab)
        tab.opener = from.id
        LittleWindow.show(tab, for: browser, front: false)
        let little = try XCTUnwrap(LittleWindow.holding(tab.id))
        defer { if LittleWindow.holding(tab.id) != nil { little.close() } }
        tab.web.load(Self.posting(to: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/send"))))
        try await until("its window goes") { LittleWindow.holding(tab.id) == nil }
        XCTAssertNil(tab.address)
        XCTAssertEqual(browser.announcement, "The form didn't go. Send it again from its page.")
    }

    /// The page a form brought, reloaded: WebKit sends the form again, and
    /// it is asked about first, as Try again on a form is. The same for a
    /// form whose page broke off as it came, which Try again reloads.
    func testReloadingThePageAFormBroughtAsksBeforeSendingItAgain() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        defer { Self.answerAgain() }
        let there = try LocalPageServer(["/send": Self.page("Sent")])
        defer { there.stop() }
        let here = try LocalPageServer(["/": Self.form(posting: there.port)])
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
        try await until("the form's page comes") { await self.title(tab.web) == "Sent" }
        let sent = LocalPageServer.Heard(method: "POST", path: "/send", body: "q=filled")
        XCTAssertEqual(Self.sent(there), [sent])

        Dialogs.answerInTest = .cancel
        tab.reload()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(Self.sent(there), [sent], "turned down, the form is not sent again")

        Dialogs.answerInTest = .alertFirstButtonReturn
        tab.reload()
        try await until("agreed to, the form is sent again") { Self.sent(there) == [sent, sent] }
    }

    /// A step back to the page a form brought, once it is no longer kept
    /// (here, in a tab brought back from the session, which keeps no page):
    /// WebKit sends the form again for it, asked about first. One still
    /// kept comes back as it was, nothing sent.
    func testGoingBackToThePageAFormBroughtAsksBeforeSendingItAgain() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        defer { Self.answerAgain() }
        let there = try LocalPageServer(["/send": Self.page("Sent"), "/next": Self.page("Next")])
        defer { there.stop() }
        let here = try LocalPageServer(["/": Self.form(posting: there.port)])
        defer { here.stop() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        let first = try XCTUnwrap(browser.active)
        let window = Self.window()
        defer { window.close() }
        window.contentView = first.web
        first.go(to: here.url("/"))
        try await until("the form loads") { await self.title(first.web) == "Form" }
        _ = try await first.web.evaluateJavaScript("document.forms[0].submit(); true")
        try await until("the form's page comes") { await self.title(first.web) == "Sent" }
        _ = try await first.web.evaluateJavaScript("location.href = '/next'; true")
        try await until("the next page comes") { await self.title(first.web) == "Next" }
        let state = first.web.interactionState

        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        window.contentView = tab.web
        tab.web.interactionState = state
        try await until("the session's page comes") { await self.title(tab.web) == "Next" }
        let sent = LocalPageServer.Heard(method: "POST", path: "/send", body: "q=filled")
        XCTAssertEqual(Self.sent(there).filter { $0 == sent }.count, 1)

        Dialogs.askedInTest = []
        Dialogs.answerInTest = .cancel
        tab.back()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(Dialogs.askedInTest, ["Send the Form Again?"])
        XCTAssertEqual(Self.sent(there).filter { $0 == sent }.count, 1, "turned down, the form is not sent again")

        Dialogs.answerInTest = .alertFirstButtonReturn
        tab.back()
        try await until("agreed to, the form is sent again") { Self.sent(there).filter { $0 == sent }.count == 2 }
        try await until("its page comes") { await self.title(tab.web) == "Sent" }
    }

    /// A page behind sending a form again by itself, here as an extension
    /// reloading it would: turned down, nothing asked over the tab in front
    /// and nothing sent.
    func testAPageBehindIsNotSentAFormAgainByItself() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        defer { Self.answerAgain() }
        let there = try LocalPageServer(["/send": Self.page("Sent")])
        defer { there.stop() }
        let here = try LocalPageServer(["/": Self.form(posting: there.port)])
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
        try await until("the form's page comes") { await self.title(tab.web) == "Sent" }
        let sent = LocalPageServer.Heard(method: "POST", path: "/send", body: "q=filled")
        browser.newTab()

        Dialogs.askedInTest = []
        Dialogs.answerInTest = .alertFirstButtonReturn
        tab.web.reload()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(Dialogs.askedInTest, [], "nothing asked")
        XCTAssertNil(browser.heldDialogs[tab.id], "nor kept to ask later")
        XCTAssertEqual(Self.sent(there).filter { $0 == sent }.count, 1, "nothing sent again")
    }

    /// A page under a peek, or in a window put out of sight, is turned down
    /// as one behind is, and so is a Send given once it has gone behind; the
    /// other page of a pair on screen is in sight, and is asked about,
    /// though it isn't the one picked.
    func testAPageIsAskedAboutWhenInSightNotUnderAPeekOrInAWindowAway() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        defer { Self.answerAgain() }
        let there = try LocalPageServer(["/send": Self.page("Sent"), "/other": Self.page("Other")])
        defer { there.stop() }
        let here = try LocalPageServer(["/": Self.form(posting: there.port)])
        defer { here.stop() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closePeek(); browser.closeAll() }
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        let window = Self.window()
        defer { window.close() }
        window.contentView = tab.web
        tab.go(to: here.url("/"))
        try await until("the form loads") { await self.title(tab.web) == "Form" }
        _ = try await tab.web.evaluateJavaScript("document.forms[0].submit(); true")
        try await until("the form's page comes") { await self.title(tab.web) == "Sent" }
        let sent = LocalPageServer.Heard(method: "POST", path: "/send", body: "q=filled")
        Dialogs.answerInTest = .alertFirstButtonReturn

        browser.peek(there.url("/other"), from: tab)
        XCTAssertTrue(browser.peekInFront)
        Dialogs.askedInTest = []
        tab.web.reload()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(Dialogs.askedInTest, [], "not asked over the peek")
        XCTAssertEqual(Self.sent(there).filter { $0 == sent }.count, 1, "nor sent")
        browser.closePeek()

        // Its window put out of sight, as when another profile takes it over.
        window.orderOut(nil)
        tab.web.reload()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(Dialogs.askedInTest, [], "not asked in a window out of sight")
        XCTAssertEqual(Self.sent(there).filter { $0 == sent }.count, 1, "nor sent")
        window.orderFrontRegardless()

        // Send given once another tab has been put in front, as an
        // extension might while the question is up: nothing is sent.
        Dialogs.answerInTest = nil
        tab.web.reload()
        try await until("it is asked about") { Dialogs.heldInTest.count == 1 }
        browser.newTab()
        Dialogs.heldInTest[0](.alertFirstButtonReturn)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(Self.sent(there).filter { $0 == sent }.count, 1, "a late Send sends nothing")
        Dialogs.answerInTest = .alertFirstButtonReturn
        Dialogs.askedInTest = []

        let other = try XCTUnwrap(browser.active)
        other.restore(url: there.url("/other"), title: "Other")
        browser.pair(other, with: tab, onLeft: false)
        XCTAssertEqual(browser.activeID, other.id)
        XCTAssertTrue(browser.visibleTabIDs.contains(tab.id))
        tab.web.reload()
        try await until("asked, and sent") { Self.sent(there).filter { $0 == sent }.count == 2 }
        XCTAssertEqual(Dialogs.askedInTest, ["Send the Form Again?"])
    }

    /// A form in a tab of its own failing while you are in another space:
    /// seen to there as here, its address forgotten, so put away it never
    /// comes back as a visit to it.
    func testAFormFailingInAnotherSpaceIsKnownAsOne() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        defer { Self.answerAgain() }
        var hanging = LocalPageServer.Page(type: "text/html", body: "")
        hanging.hangs = true
        let silent = try LocalPageServer(["/send": hanging])
        let port = silent.port
        defer { silent.stop() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let prefs = browser.prefs
        let before = (prefs.usesSpaces, browser.spaces)
        addTeardownBlock { @MainActor in
            prefs.usesSpaces = before.0
            browser.spaces = before.1
            Spaces.write(before.1, profile: browser.profileID)
        }
        prefs.usesSpaces = true
        browser.afterSpaceCreated = { _ in }
        browser.addSpace(named: "Elsewhere", sharesSignIns: true)
        let away = try XCTUnwrap(browser.spaces.last?.id)
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        let window = Self.window()
        defer { window.close() }
        window.contentView = tab.web
        tab.web.load(Self.posting(to: silent.url("/send")))
        try await until("the form is on its way") { silent.requests == ["/send"] }

        browser.switchSpace(to: away)
        try await until("its space is put aside") { browser.parkedTabs.contains { $0 === tab } }
        silent.stop()
        try await until("the form's address is forgotten") { tab.address == nil && !tab.loading }
        let back = try LocalPageServer(["/send": Self.page("Sent")], port: port)
        defer { back.stop() }
        tab.rest()
        XCTAssertFalse(tab.wake(), "nothing to come back to")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(back.heard, [], "its address isn't visited")
    }

    /// A tab whose form never arrived, put away and opened again, or kept
    /// for the next launch: never a plain visit to the form's address. From
    /// a page, back to that page; in a tab of its own, nowhere.
    func testAFailedFormPutAwayDoesNotComeBackAsAVisit() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        defer { Self.answerAgain() }
        let (browser, tab, here, port, window) = try await failedForm()
        defer { browser.closeAll(); window.close(); here.stop() }
        let back = try LocalPageServer(["/send": Self.page("Sent")], port: port)
        defer { back.stop() }

        tab.rest()
        XCTAssertTrue(tab.wake())
        window.contentView = tab.web
        try await until("its page comes back") { await self.title(tab.web) == "Form" }
        XCTAssertNil(tab.failure)

        browser.newTab()
        let own = try XCTUnwrap(browser.active)
        window.contentView = own.web
        back.stop()
        own.web.load(Self.posting(to: back.url("/send")))
        try await until("the form's address is forgotten") { own.address == nil && !own.loading }
        let again = try LocalPageServer(["/send": Self.page("Sent")], port: port)
        defer { again.stop() }
        let saved = { browser.allRows().values.flatMap(\.tabs).map(\.url) }
        XCTAssertFalse(saved().contains { $0.hasSuffix("/send") }, "nor kept for the next launch")
        own.rest()
        XCTAssertFalse(own.wake(), "nothing to come back to")
        own.reload()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(again.heard, [], "its address isn't visited")
        XCTAssertEqual(back.heard, [], "nor was it before")
    }

    /// A tab whose form, posted from a page of `here` with `typing` in its
    /// field, didn't go: the port it went to has nothing behind it.
    private func failedForm(typing: String = "filled") async throws -> (Browser, Eden.Tab, LocalPageServer, UInt16, NSWindow) {
        let port = try Self.freePort()
        let here = try LocalPageServer(["/": Self.form(posting: port)])
        let browser = Browser(record: WindowRecord())
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        let window = Self.window()
        window.contentView = tab.web
        tab.go(to: here.url("/"))
        try await until("the form loads") { await self.title(tab.web) == "Form" }
        _ = try await tab.web.evaluateJavaScript(
            "document.forms[0].q.value = '\(typing)'; document.forms[0].submit(); true")
        try await until("the form says it didn't go") { tab.failure != nil }
        return (browser, tab, here, port, window)
    }

    /// A form sent by hand, as a page's would be.
    private static func posting(to url: URL) -> URLRequest {
        var form = URLRequest(url: url)
        form.httpMethod = "POST"
        form.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        form.httpBody = Data("q=filled".utf8)
        return form
    }

    /// Questions answered as a test run answers them unless told otherwise.
    private static func answerAgain() {
        Dialogs.answerInTest = .cancel
        Dialogs.heldInTest = []
    }

    /// What a server was sent, its icon aside.
    private static func sent(_ server: LocalPageServer) -> [LocalPageServer.Heard] {
        server.heard.filter { $0.path != "/favicon.ico" }
    }

    /// A peek that failed said nothing and sat on its skeleton (#63). It
    /// says so, and Try again brings it.
    func testAPeekThatFailsSaysSoAndComesBackOnTryAgain() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let here = try LocalPageServer(["/": Self.page("Here")])
        defer { here.stop() }
        let port = try Self.freePort()
        let browser = Browser(record: WindowRecord())
        defer { browser.closePeek(); browser.closeAll() }
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        let window = Self.window()
        defer { window.close() }
        window.contentView = tab.web
        tab.go(to: here.url("/"))
        try await until("the page loads") { await self.title(tab.web) == "Here" }

        browser.peek(try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/")), from: tab)
        let peek = try XCTUnwrap(browser.peekTab)
        try await until("the peek says it didn't come") { peek.failure != nil }

        let back = try LocalPageServer(["/": Self.page("There")], port: port)
        defer { back.stop() }
        peek.reload()
        try await until("Try again brings the peek's page") { await self.title(peek.web) == "There" }
        XCTAssertNil(peek.failure)
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

    /// On screen as far as AppKit knows, so its page is one you can see
    /// (Browser.inSight), but far off every display, where no one sees it.
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
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
