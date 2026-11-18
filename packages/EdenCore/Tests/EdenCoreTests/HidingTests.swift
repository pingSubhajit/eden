import WebKit
import XCTest
@testable import EdenCore

/// Hidden elements (Curtain, Veiling, VeilRelay): what is kept per site and
/// how, the stylesheet and commands that reach the page whatever they carry,
/// and the touch picker in a real web view — a tap offers, Bigger widens,
/// Hide hides, and a link tapped while picking goes nowhere.
@MainActor
final class HidingTests: XCTestCase {
    private var folder: URL!
    private var holding: [NSObject] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("hiding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        holding = []
        Disk.drain()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - what is kept

    func testHiddenThingsAreKeptPerSiteWithoutWww() throws {
        let file = folder.appendingPathComponent("hidden.json")
        let curtain = Curtain(file: file)
        let host = try XCTUnwrap(curtain.host(of: URL(string: "https://www.Example.com/page")))
        XCTAssertEqual(host, "example.com")
        curtain.hide("#banner", label: "Banner", note: "390×80 · top centre", on: host)
        curtain.hide("#banner", label: "Banner again", note: "", on: host)
        curtain.hide(".cookie", label: "Cookies", note: "", on: host)
        XCTAssertEqual(curtain.veils(on: host).map(\.selector), ["#banner", ".cookie"], "each once")
        XCTAssertEqual(curtain.css(on: host, without: ".cookie"), "#banner { display: none !important; }")
        Disk.drain()
        XCTAssertEqual(Curtain(file: file).veils(on: host).map(\.label), ["Banner", "Cookies"], "kept in hidden.json")
        XCTAssertEqual(curtain.undo(on: host)?.selector, ".cookie")
        curtain.restoreAll(on: host)
        XCTAssertTrue(curtain.veils(on: host).isEmpty)
    }

    func testAnUnreadableFileIsSetAsideNotWrittenOver() throws {
        let file = folder.appendingPathComponent("hidden.json")
        try Data("{not json".utf8).write(to: file)
        let curtain = Curtain(file: file)
        XCTAssertTrue(curtain.byHost.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "moved aside")
    }

    func testAMessageFromThePageIsReadForWhatItIs() {
        let choice = VeilMessage.Choice(selector: "#a", label: "A", note: "1×1")
        XCTAssertEqual(VeilMessage(["selector": "#a", "label": "A", "note": "1×1"]), .picked(choice))
        XCTAssertEqual(VeilMessage(["selector": "#a", "label": "A", "note": "1×1", "offered": true]), .offered(choice))
        XCTAssertEqual(VeilMessage(["off": true]), .ended)
        XCTAssertEqual(VeilMessage(["withdrawn": true]), .withdrawn)
        XCTAssertEqual(VeilMessage(["trouble": "no"]), .trouble("no"))
        XCTAssertNil(VeilMessage(["what": 1]))
        XCTAssertNil(VeilMessage("text"))
    }

    // MARK: - the page

    func testWhatReachesThePageIsWhatWasMeant() async throws {
        let (web, _) = try await page("<p id='x'>X</p>")
        let css = "div[title=\"`${x}`\\\\\"] { display: none !important; }\n#x { color: red; }"
        _ = try await web.evaluateJavaScript(Veiling.style(css), contentWorld: .page)
        let sheet = try await web.evaluateJavaScript("document.getElementById('office-veil').textContent") as? String
        XCTAssertEqual(sheet, css, "backticks, ${}, quotes, backslashes and lines, all as they were")
    }

    func testEachPagePutsOnItsOwnSitesStylesheetOnly() async throws {
        let script = Veiling.style(byHost: [
            "example.com": "#x { display: none !important; }",
            "other.org": "p { color: red; }",
            "empty.net": "",
        ])
        let sheet = "document.getElementById('office-veil').textContent"

        let (here, _) = try await page("<p id='x'>X</p>", at: URL(string: "https://www.example.com/a"))
        _ = try await here.evaluateJavaScript(script, contentWorld: .page)
        let mine = try await here.evaluateJavaScript(sheet) as? String
        XCTAssertEqual(mine, "#x { display: none !important; }", "www. or not, the page's own site")

        let (elsewhere, _) = try await page("<p>Y</p>", at: URL(string: "https://unknown.test/"))
        _ = try await elsewhere.evaluateJavaScript(script, contentWorld: .page)
        let none = try await elsewhere.evaluateJavaScript("document.getElementById('office-veil') === null") as? Bool
        XCTAssertEqual(none, true, "a site with nothing hidden gets no stylesheet")

        // A page showing, restyled: everything restored takes its rules away.
        _ = try await here.evaluateJavaScript(Veiling.style(byHost: [:]), contentWorld: .page)
        let cleared = try await here.evaluateJavaScript(sheet) as? String
        XCTAssertEqual(cleared, "")
    }

    func testATapOffersBiggerWidensHideHidesAndLinksStay() async throws {
        let (web, heard) = try await page("""
            <div id="card" style="padding:40px"><a id="link" href="https://example.com/away" style="display:block;height:60px">LINK</a></div>
            """)
        _ = try await web.evaluateJavaScript(Veiling.on(touch: true), contentWorld: .world(name: "Eden"))
        _ = try await web.evaluateJavaScript("""
            var r = document.getElementById('link').getBoundingClientRect();
            document.getElementById('link').dispatchEvent(new MouseEvent('click', {
              bubbles: true, cancelable: true, clientX: r.left + 5, clientY: r.top + 5 }));
            """, contentWorld: .page)
        try await settle()
        XCTAssertEqual(heard.said.last, .offered(.init(selector: "#link", label: "LINK", note: heard.lastNote)))
        XCTAssertEqual(web.url?.host(), nil, "the tapped link went nowhere")

        _ = try await web.evaluateJavaScript(Veiling.widen, contentWorld: .world(name: "Eden"))
        try await settle()
        guard case .offered(let wider) = heard.said.last else { return XCTFail("widened, offered again") }
        XCTAssertEqual(wider.selector, "#card")

        _ = try await web.evaluateJavaScript(Veiling.confirm, contentWorld: .world(name: "Eden"))
        try await settle()
        guard case .picked(let picked) = heard.said.last else { return XCTFail("confirmed, picked") }
        XCTAssertEqual(picked.selector, "#card")

        _ = try await web.evaluateJavaScript(Veiling.off(), contentWorld: .world(name: "Eden"))
        try await settle()
        XCTAssertEqual(heard.said.last, .ended)
    }

    func testWhatAPageSaysCarriesItsSessionAndAnOldOneCannotEndANewOne() async throws {
        let (web, heard) = try await page("<div id='a' style='height:80px'>A</div>")
        let eden = WKContentWorld.world(name: "Eden")
        _ = try await web.evaluateJavaScript(Veiling.on(touch: true, session: "one"), contentWorld: eden)
        _ = try await web.evaluateJavaScript(Veiling.on(touch: true, session: "two"), contentWorld: eden)
        _ = try await web.evaluateJavaScript(Veiling.off(session: "one"), contentWorld: eden)
        try await settle()
        XCTAssertTrue(heard.said.isEmpty, "begun again, nothing said; the old session's off ignored")
        try await tap("a", in: web)
        XCTAssertEqual(heard.sessions.last, "two")
        _ = try await web.evaluateJavaScript(Veiling.off(session: "two"), contentWorld: eden)
        try await settle()
        XCTAssertEqual(heard.said.last, .ended)
        XCTAssertEqual(heard.sessions.last, "two")
    }

    func testAFrameIsCoveredWhereverItGoesAndUncoveredWhenHidden() async throws {
        let (web, heard) = try await page("""
            <div id="spacer" style="height:10px"></div><iframe id="f" style="width:200px;height:100px;border:0"></iframe>
            """)
        let eden = WKContentWorld.world(name: "Eden")
        _ = try await web.evaluateJavaScript(Veiling.on(touch: true, session: "s"), contentWorld: eden)
        let covered = "(function(){var f=document.getElementById('f').getBoundingClientRect();" +
            "var e=document.elementFromPoint(f.left+5,f.top+5);return !!e && e!==document.getElementById('f');})()"
        var over = try await web.evaluateJavaScript(covered) as? Bool
        XCTAssertEqual(over, true, "the frame is under a cover")
        _ = try await web.evaluateJavaScript("document.getElementById('spacer').style.height='300px'")
        try await settle()
        over = try await web.evaluateJavaScript(covered) as? Bool
        XCTAssertEqual(over, true, "the cover followed the frame down the page")
        _ = try await web.evaluateJavaScript("document.getElementById('spacer').textContent = 'one\\ntwo\\nthree'; " +
                                             "document.getElementById('spacer').style.cssText = 'white-space:pre'")
        _ = try await web.evaluateJavaScript("document.getElementById('spacer').firstChild.data += '\\nfour\\nfive'")
        try await settle()
        over = try await web.evaluateJavaScript(covered) as? Bool
        XCTAssertEqual(over, true, "and again when only text above it changed")
        try await tap("f", in: web)
        guard case .offered(let offered) = heard.said.last else { return XCTFail("the frame offered") }
        XCTAssertEqual(offered.selector, "#f")
        _ = try await web.evaluateJavaScript(Veiling.style("#f { display: none !important; }"), contentWorld: eden)
        try await settle()
        let left = try await web.evaluateJavaScript(
            "Array.prototype.filter.call(document.documentElement.children, function (c) { return c.style.zIndex === '2147483645'; }).length") as? Int
        XCTAssertEqual(left, 0, "a hidden frame keeps no cover")
    }

    func testWhatLeavesThePageAfterBeingOfferedIsNeverHidden() async throws {
        let (web, heard) = try await page("<div><div id='banner' style='height:60px'>BANNER</div></div>")
        let eden = WKContentWorld.world(name: "Eden")
        _ = try await web.evaluateJavaScript(Veiling.on(touch: true, session: "s"), contentWorld: eden)
        try await tap("banner", in: web)
        guard case .offered(let offered) = heard.said.last else { return XCTFail("offered") }
        XCTAssertEqual(offered.selector, "#banner")
        _ = try await web.evaluateJavaScript("document.getElementById('banner').remove()")
        _ = try await web.evaluateJavaScript(Veiling.confirm, contentWorld: eden)
        try await settle()
        XCTAssertEqual(heard.said.last, .withdrawn, "not a rule for every div")
        XCTAssertFalse(heard.said.contains { if case .picked = $0 { true } else { false } })

        // Nor widened from: there is nothing left to widen.
        _ = try await web.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend', \"<div id='ad' style='height:60px'>AD</div>\")")
        try await tap("ad", in: web)
        _ = try await web.evaluateJavaScript("document.getElementById('ad').remove()")
        _ = try await web.evaluateJavaScript(Veiling.widen, contentWorld: eden)
        try await settle()
        XCTAssertEqual(heard.said.last, .withdrawn)
    }

    func testATapOnSomethingOverAFrameOffersThatThing() async throws {
        let (web, heard) = try await page("""
            <iframe id="video" style="width:300px;height:200px;border:0"></iframe>
            <div id="banner" style="position:absolute;left:0;top:0;width:300px;height:50px;z-index:10;background:#eee">BANNER</div>
            """)
        _ = try await web.evaluateJavaScript(Veiling.on(touch: true, session: "s"), contentWorld: .world(name: "Eden"))
        try await tap("banner", in: web)
        guard case .offered(let banner) = heard.said.last else { return XCTFail("offered") }
        XCTAssertEqual(banner.selector, "#banner", "what is on top, not the frame under it")
        _ = try await web.evaluateJavaScript("""
            var r = document.getElementById('video').getBoundingClientRect();
            var x = r.left + r.width / 2, y = r.bottom - 20;
            document.elementFromPoint(x, y).dispatchEvent(new MouseEvent('click', {
              bubbles: true, cancelable: true, clientX: x, clientY: y }));
            """, contentWorld: .page)
        try await settle()
        guard case .offered(let video) = heard.said.last else { return XCTFail("offered") }
        XCTAssertEqual(video.selector, "#video", "and the frame where nothing lies over it")
    }

    // MARK: - helpers

    /// What the relay heard, in order.
    private final class Heard {
        var said: [VeilMessage] = []
        var sessions: [String?] = []
        var lastNote: String {
            if case .offered(let choice)? = said.last { return choice.note }
            return ""
        }
    }

    private func page(_ body: String, at address: URL? = nil) async throws -> (WKWebView, Heard) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let relay = VeilRelay()
        let heard = Heard()
        relay.received = { said, origin in heard.said.append(said); heard.sessions.append(origin.session) }
        configuration.userContentController.add(relay, contentWorld: .world(name: "Eden"), name: VeilRelay.name)
        configuration.userContentController.addUserScript(WKUserScript(source: Veiling.picker, injectionTime: .atDocumentStart,
                                                                       forMainFrameOnly: true, in: .world(name: "Eden")))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        let loaded = Loaded()
        holding += [relay, loaded]
        web.navigationDelegate = loaded
        web.loadHTMLString("<!doctype html><meta name=viewport content='width=device-width'><body>\(body)</body>",
                           baseURL: address)
        try await loaded.wait()
        return (web, heard)
    }

    /// A click at the middle of the element `id`, as a tap ends.
    private func tap(_ id: String, in web: WKWebView) async throws {
        _ = try await web.evaluateJavaScript("""
            var r = document.getElementById('\(id)').getBoundingClientRect();
            var x = r.left + r.width / 2, y = r.top + r.height / 2;
            document.elementFromPoint(x, y).dispatchEvent(new MouseEvent('click', {
              bubbles: true, cancelable: true, clientX: x, clientY: y }));
            """, contentWorld: .page)
        try await settle()
    }

    /// Messages from the page arrive a turn later.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
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
