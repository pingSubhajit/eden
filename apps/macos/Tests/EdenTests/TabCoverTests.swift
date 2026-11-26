import AppKit
import Combine
import EdenCore
import WebKit
import XCTest
@testable import Eden

/// A tab coming back shows its page as it was left until the page draws
/// (#66): at launch, the picture kept on disk at the page's size, which stays
/// for as long as the page is coming and goes once it draws, or once its load
/// ends without it. Nothing is shown: the window is far off every screen.
@MainActor
final class TabCoverTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["EDEN_PROBE"] == nil {
            setenv("EDEN_PROBE", "tab-cover-\(getpid())", 1)
        }
        super.setUp()
    }

    private var browser: Browser!
    private var window: NSWindow!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
    }

    override func tearDown() {
        browser.closeAll()
        window.close()
        browser = nil
        window = nil
        PagePictures.covers.forgetAll()
        PagePictures.shared.forgetAll()
    }

    func testATabBroughtBackShowsItsKeptPictureUntilItsPageDraws() async throws {
        let server = try LocalPageServer(["/": Self.page("Back")])
        defer { server.stop() }
        let tab = try await broughtBack(server.url("/"))

        XCTAssertTrue(tab.wake())
        attach(tab)
        try await until("the kept picture covers the page") { tab.cover != nil }
        XCTAssertTrue(tab.coverSoftens, "a page being built again softens as it takes its time")
        try await until("the page draws, and the picture comes off") { tab.painted && tab.cover == nil }

        // A page landing from the floating window is there, only settling.
        tab.cover(with: NSImage(size: NSSize(width: 10, height: 10)))
        XCTAssertFalse(tab.coverSoftens)
    }

    /// For as long as the page is coming, however long that is: it used to
    /// come off after four seconds, whatever was under it.
    func testThePictureStaysWhileThePageIsSlowAndGoesWhenItFails() async throws {
        var stalling = LocalPageServer.Page(type: "text/html", body: "")
        stalling.hangs = true
        let server = try LocalPageServer(["/": stalling])
        defer { server.stop() }
        let tab = try await broughtBack(server.url("/"))

        XCTAssertTrue(tab.wake())
        attach(tab)
        try await until("the kept picture covers the page") { tab.cover != nil }
        try await until("the page is asked for") { server.requests == ["/"] }
        // Past the four seconds it used to be taken down after.
        try await Task.sleep(for: .seconds(4.5))
        XCTAssertNotNil(tab.cover, "the page isn't here yet")

        server.stop()
        try await until("the page says it didn't come") { tab.failure != nil }
        try await until("the picture comes off") { tab.cover == nil }
    }

    /// Stopped before its picture is read from disk: the picture, read
    /// after, isn't put up over a view nothing will take it off.
    func testAPictureReadAfterStopIsNotPutUp() async throws {
        let server = try LocalPageServer(["/": Self.page("Back")])
        defer { server.stop() }
        let tab = try await broughtBack(server.url("/"))

        XCTAssertTrue(tab.wake())
        tab.stop()
        attach(tab)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(tab.cover)
    }

    /// One picture for both: at the page's size for the tab, small for its
    /// hover card.
    func testKeepingAPictureKeepsItAtItsSizeAndSmallForTheCard() async throws {
        let server = try LocalPageServer(["/": Self.page("Kept")])
        defer { server.stop() }
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        attach(tab)
        tab.go(to: server.url("/"))
        try await until("the page draws") { tab.painted && tab.built?.isLoading == false }

        // Said once both are on disk, as quitting waits on.
        var kept = false
        tab.keepPicture { kept = true }
        try await until("both are kept") { kept }
        let store = tab.store.identifier
        let url = server.url("/")
        XCTAssertTrue(PagePictures.covers.has(url, store: store))
        XCTAssertTrue(PagePictures.shared.has(url, store: store))
        let coverData = await PagePictures.covers.kept(for: url, store: store)
        let cardData = await PagePictures.shared.kept(for: url, store: store)
        let cover = try XCTUnwrap(coverData.flatMap(NSImage.init(data:)))
        let card = try XCTUnwrap(cardData.flatMap(NSImage.init(data:)))
        XCTAssertEqual(cover.size.width, 800, accuracy: 1, "the page's own width, in points")
        XCTAssertEqual(card.size.width, 260, accuracy: 1, "the hover card's")
    }

    /// A tab as the session brings it back at launch, with a picture kept
    /// on disk for its page.
    private func broughtBack(_ url: URL) async throws -> Tab {
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let picture = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        let covers = PagePictures.covers
        covers.keep(picture, for: url, store: tab.store.identifier, ticket: covers.ticket())
        await covers.settled()
        tab.restore(url: url, title: "Back")
        XCTAssertTrue(tab.asleep)
        return tab
    }

    /// The stage's part, done by hand: the view in the window at the window's size.
    private func attach(_ tab: Tab) {
        let page = tab.web
        // A window far off every screen counts as hidden to WebKit, which
        // then lays nothing out; the page is to see itself shown.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if page.responds(to: occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(page.method(for: occlusion), to: Setter.self)(page, occlusion, false)
        }
        page.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(page)
    }

    private static func page(_ title: String) -> LocalPageServer.Page {
        let words = String(repeating: "A page with something to look at. ", count: 200)
        return .init(type: "text/html; charset=utf-8",
                     body: "<!doctype html><title>\(title)</title><body style='margin:0'><p>\(words)</p>", uncached: true)
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
