import WebKit
import XCTest
@testable import EdenCore

/// Reading mode end to end in a real web view (ReadingMode): an article page
/// becomes its article, a page with nothing to read says so, and a page that
/// has gone by the time the answer comes is left alone.
@MainActor
final class ReadingModeTests: XCTestCase {
    private var holding: [Loaded] = []

    private static let article = """
        <html><head><title>A long read</title><style>body{color:red}</style></head><body>
        <nav><a href="/a">Home</a> <a href="/b">World</a> <a href="/c">Sport</a></nav>
        <article><h1>A long read</h1>
        \(String(repeating: "<p>Prose that goes on, sentence after sentence, the way an article does, with nothing in it but words about the thing it is about.</p>", count: 12))
        </article><footer><a href="/d">About</a></footer></body></html>
        """

    private func page(_ html: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        let loaded = Loaded()
        holding.append(loaded)
        web.navigationDelegate = loaded
        web.loadHTMLString(html, baseURL: nil)
        try await loaded.wait()
        return web
    }

    private func text(_ web: WKWebView, _ script: String) async throws -> String? {
        try await web.evaluateJavaScript(script) as? String
    }

    func testAnArticleBecomesItsArticleOnAPhoneWidePage() async throws {
        let web = try await page(Self.article)
        let outcome = await ReadingMode.enter(web, twins: true, look: .system, world: .world(name: "Eden")) { true }
        XCTAssertEqual(outcome, .read, "no twin to be had: the guess reads it")
        let reader = try await text(web, "document.getElementById('office-reader') ? 'yes' : null")
        let nav = try await text(web, "document.querySelector('nav') ? 'nav' : 'gone'")
        let look = try await text(web, "document.documentElement.getAttribute('data-office-look')")
        XCTAssertEqual(reader, "yes")
        XCTAssertEqual(nav, "gone")
        XCTAssertNil(look, "as the device is: no look of its own")
    }

    func testAPageWithNothingToReadSaysSo() async throws {
        let web = try await page("<html><body><nav><a href='/a'>Home</a></nav></body></html>")
        let outcome = await ReadingMode.enter(web, twins: false, look: .light, world: .world(name: "Eden")) { true }
        XCTAssertEqual(outcome, .nothing)
    }

    func testAPageGoneBeforeAskingIsLeftAlone() async throws {
        let web = try await page(Self.article)
        let outcome = await ReadingMode.enter(web, twins: false, look: .light, world: .world(name: "Eden")) { false }
        XCTAssertEqual(outcome, .gone)
        let nav = try await text(web, "document.querySelector('nav') ? 'nav' : 'gone'")
        XCTAssertEqual(nav, "nav")
    }

    func testAPageGoneWhileTheAnswerCameIsGoneNotRead() async throws {
        let web = try await page(Self.article)
        var asked = 0
        // Still there when asked, gone by the time the article is back.
        let outcome = await ReadingMode.enter(web, twins: true, look: .light, world: .world(name: "Eden")) {
            asked += 1
            return asked < 3
        }
        XCTAssertEqual(outcome, .gone, "nothing claimed for the page that came next")
    }

    /// A Markdown page, which is its own twin (Reader.twin), found at once.
    private func markdown() async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        let loaded = Loaded()
        holding.append(loaded)
        web.navigationDelegate = loaded
        let text = "# The guide\n\n" + String(repeating: "A paragraph of the guide, as its writer gave it.\n\n", count: 8)
        web.load(Data(text.utf8), mimeType: "text/markdown", characterEncodingName: "utf-8",
                 baseURL: try XCTUnwrap(URL(string: "https://docs.example/guide.md")))
        try await loaded.wait()
        return web
    }

    func testATwinForAPageGoneByTheTimeItCameIsNeverDrawn() async throws {
        let web = try await markdown()
        let outcome = await ReadingMode.enter(web, twins: true, look: .light, world: .world(name: "Eden")) { false }
        XCTAssertEqual(outcome, .gone)
        let reader = try await text(web, "document.getElementById('office-reader') ? 'drawn' : 'not'")
        XCTAssertEqual(reader, "not", "the page is left as it was")
    }

    func testATwinDrawnAsThePageWentIsGoneNotRead() async throws {
        let web = try await markdown()
        var asked = 0
        let outcome = await ReadingMode.enter(web, twins: true, look: .light, world: .world(name: "Eden")) {
            asked += 1
            return asked < 2
        }
        XCTAssertEqual(outcome, .gone, "drawn, but for a page that has gone: not claimed")
        XCTAssertEqual(asked, 2, "asked after the fetch and after the drawing, and no more")
    }

    func testATwinIsReadWhenThePageStays() async throws {
        let web = try await markdown()
        let outcome = await ReadingMode.enter(web, twins: true, look: .light, world: .world(name: "Eden")) { true }
        XCTAssertEqual(outcome, .read)
        let from = try await text(web, "document.querySelector('.office-from').textContent")
        XCTAssertEqual(from, "docs.example · markdown")
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var done = false

        func wait() async throws {
            if done { return }
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
