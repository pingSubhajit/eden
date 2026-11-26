import AppKit
import EdenCore
import WebKit
import XCTest
@testable import Eden

/// A question a page asked from a tab behind, moved to another window
/// before it was answered (#65): it stayed in the window the tab left,
/// never shown and never answered, and the page waited on it for good. It
/// goes with the tab now.
@MainActor
final class MovedTabQuestionsTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "moved-tab-questions-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Dialogs.askedInTest = []
    }

    /// Move to Window puts the tab in front there, and its question with it.
    func testAConfirmWaitingInATabMovedToAnotherWindowIsAskedThere() async throws {
        let (browser, asking) = try await waiting()
        let destination = Browser(record: WindowRecord())
        defer { destination.closeAll(); browser.closeAll() }

        browser.moveToWindow(asking, destination)
        XCTAssertNil(browser.heldDialogs[asking.id], "nothing left behind for the tab")
        try await until("the page has its answer") { await self.title(asking.web) == "answered false" }
        XCTAssertEqual(Dialogs.askedInTest, ["asking.example"])
    }

    /// An extension's move leaves the tab behind the one in front there: the
    /// question waits for it, as it did where it came from.
    func testAMoveThatLeavesTheTabBehindKeepsTheQuestionForIt() async throws {
        let (browser, asking) = try await waiting()
        let destination = Browser(record: WindowRecord())
        defer { destination.closeAll(); browser.closeAll() }
        destination.newTab()

        XCTAssertTrue(browser.hand(asking, to: destination))
        XCTAssertNil(browser.heldDialogs[asking.id])
        XCTAssertEqual(destination.heldDialogs[asking.id]?.count, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(Dialogs.askedInTest, [], "not over the tab in front there")

        destination.select(asking)
        try await until("the page has its answer") { await self.title(asking.web) == "answered false" }
        XCTAssertEqual(Dialogs.askedInTest, ["asking.example"])
    }

    /// A camera question waiting in the tab is asked by the window it went
    /// to, over it there, not by the one it left, over that one's page.
    func testACameraQuestionIsAskedByTheWindowTheTabWentTo() async throws {
        let (browser, asking, frame) = try await behind()
        let destination = Browser(record: WindowRecord())
        defer { destination.closeAll(); browser.closeAll() }
        var replies: [WKPermissionDecision] = []
        browser.askedForCapture(asking.web, origin: frame.securityOrigin, frame: frame, type: .camera) { replies.append($0) }
        XCTAssertEqual(browser.heldDialogs[asking.id]?.count, 1)

        browser.moveToWindow(asking, destination)
        try await until("it is asked there") { destination.asking?.wants == "camera" }
        XCTAssertNil(browser.asking, "not over the page of the window it left")
        XCTAssertEqual(replies, [])
        destination.closeAll()
        XCTAssertEqual(replies, [.deny], "answered once, as its window goes")
    }

    /// Tabs moved one after another, as an extension making a window moves
    /// them: the first was in front there only for a moment, and its
    /// question waits for it, not shown over the tab after it.
    func testAQuestionWaitsForItsTabWhenAnotherComesInFrontAtOnce() async throws {
        let (browser, asking, frame) = try await behind()
        let destination = Browser(record: WindowRecord())
        defer { destination.closeAll(); browser.closeAll() }
        browser.newTab()
        let next = try XCTUnwrap(browser.active)
        next.restore(url: try XCTUnwrap(URL(string: "https://next.example/")), title: "Next")
        var replies: [WKPermissionDecision] = []
        browser.askedForCapture(asking.web, origin: frame.securityOrigin, frame: frame, type: .camera) { replies.append($0) }

        browser.moveToWindow(asking, destination)
        browser.moveToWindow(next, destination)
        XCTAssertEqual(destination.activeID, next.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(destination.asking, "not over the tab in front")
        XCTAssertEqual(destination.heldDialogs[asking.id]?.count, 1, "still waiting for its tab")

        destination.select(asking)
        try await until("asked over its own tab") { destination.asking?.wants == "camera" }
        destination.closeAll()
        XCTAssertEqual(replies, [.deny])
    }

    /// A tab moved into a space with sign-ins of its own reopens with them,
    /// its page let go: what that page asked is answered as dismissed, not
    /// shown over the new one.
    func testAQuestionWhosePageWasLetGoOnTheWayIsDismissed() async throws {
        let (browser, asking) = try await waiting()
        let prefs = browser.prefs
        let before = (prefs.usesSpaces, browser.spaces)
        addTeardownBlock { @MainActor in
            prefs.usesSpaces = before.0
            browser.spaces = before.1
            Spaces.write(before.1, profile: browser.profileID)
        }
        prefs.usesSpaces = true
        browser.afterSpaceCreated = { _ in }
        browser.addSpace(named: "Elsewhere", sharesSignIns: false)
        let away = try XCTUnwrap(browser.spaces.last?.id)
        let elsewhere = Browser(record: WindowRecord(space: away))
        defer { elsewhere.closeAll(); browser.closeAll() }
        XCTAssertEqual(elsewhere.spaceID, away)
        let page = try XCTUnwrap(asking.built)

        browser.moveToWindow(asking, elsewhere)
        XCTAssertFalse(asking.built === page, "the page was let go")
        XCTAssertNil(elsewhere.heldDialogs[asking.id])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(Dialogs.askedInTest, [], "nothing asked over the new page")
    }

    /// A question over one page of a pair: moved with its pair by an
    /// extension, it stays over the page; moved alone, out of its pair, it
    /// is answered as dismissed, as one leaving Split View is.
    func testAQuestionOverAPageOfAPairGoesWithThePairOrIsDismissed() throws {
        for keepsPair in [true, false] {
            let browser = Browser(record: WindowRecord())
            let destination = Browser(record: WindowRecord())
            defer { destination.closeAll(); browser.closeAll() }
            browser.newTab()
            let left = try XCTUnwrap(browser.active)
            left.restore(url: try XCTUnwrap(URL(string: "https://asking.example/")), title: "Left")
            browser.newTab()
            let right = try XCTUnwrap(browser.active)
            right.restore(url: try XCTUnwrap(URL(string: "https://other.example/")), title: "Right")
            browser.pair(right, with: left, onLeft: false)
            XCTAssertNotNil(browser.split(for: left))
            var answers: [Bool] = []
            browser.paneQuestions.append(PaneQuestion(tab: left.id, host: "asking.example", message: "Leave?",
                                                      kind: .confirm) { ok, _ in answers.append(ok) })

            if keepsPair { XCTAssertTrue(browser.hand(left, to: destination)) }
            else { browser.moveToWindow(left, destination) }
            XCTAssertTrue(browser.paneQuestions.isEmpty, "nothing left behind")
            if keepsPair {
                XCTAssertEqual(destination.paneQuestions.map(\.tab), [left.id], "over its page there")
                XCTAssertEqual(answers, [])
            } else {
                XCTAssertTrue(destination.paneQuestions.isEmpty)
                XCTAssertEqual(answers, [false], "answered as dismissed")
            }
        }
    }

    /// A window with the tab in front and, behind it, a tab whose page has
    /// asked confirm() and waits on it.
    private func waiting() async throws -> (Browser, Tab) {
        let browser = Browser(record: WindowRecord())
        let asking = Tab()
        browser.prepare(asking)
        browser.insert(asking, at: browser.tabs.count)
        browser.select(asking)
        asking.web.loadHTMLString("<title>loaded</title>", baseURL: URL(string: "https://asking.example/"))
        try await until("the page loads") { await self.title(asking.web) == "loaded" }
        browser.newTab()
        XCTAssertNotEqual(browser.activeID, asking.id)

        _ = try await asking.web.evaluateJavaScript(
            "setTimeout(() => { document.title = 'answered ' + confirm('Leave?') }, 0); true")
        try await until("the question waits for its tab") { browser.heldDialogs[asking.id]?.count == 1 }
        return (browser, asking)
    }

    /// A window whose tab behind has a page from asking.example loaded,
    /// and that page's frame, to ask with.
    private func behind() async throws -> (Browser, Tab, WKFrameInfo) {
        let browser = Browser(record: WindowRecord())
        let asking = Tab()
        browser.prepare(asking)
        browser.insert(asking, at: browser.tabs.count)
        browser.select(asking)
        let receiver = FrameReceiver()
        let controller = asking.web.configuration.userContentController
        controller.add(receiver, name: "movedFixture")
        defer { controller.removeScriptMessageHandler(forName: "movedFixture") }
        asking.web.loadHTMLString("<script>webkit.messageHandlers.movedFixture.postMessage('ready')</script>",
                                  baseURL: URL(string: "https://asking.example/"))
        try await until("the page loads") { receiver.frame != nil }
        browser.newTab()
        return (browser, asking, try XCTUnwrap(receiver.frame))
    }

    /// The page's title, or nil while it can't answer.
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

    private func until(_ what: String, timeout: TimeInterval = 10, _ check: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await check() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting: \(what)")
        throw CancellationError()
    }
}

@MainActor
private final class FrameReceiver: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        frame = message.frameInfo
    }
}
