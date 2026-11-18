import XCTest

/// Eden for iPhone and iPad, driven as a person would: typing in the address
/// field, the tabs, a private tab, bookmarks, history and settings. Each test
/// starts the app in a test world of its own with nothing in it (EDEN_PROBE,
/// EDEN_FRESH), so nothing of anyone's browsing is read or written. Pages come
/// from UITests/Fixtures, which scripts/test.sh serves from the Mac, and a
/// step waits for a page's own words before going on — the address field
/// says where a tab is going before the page has arrived. Only the search
/// test needs a network.
final class EdenUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment = ["EDEN_PROBE": "ui-tests", "EDEN_FRESH": "1"]
        app.launch()
    }

    // MARK: - helpers

    /// Any element with `identifier`, whatever kind SwiftUI made of it: a
    /// list's row and a menu's item are cells, other controls buttons.
    private func all(_ identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    /// The menu item, or anything else, labelled `label`.
    private func labelled(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Types into the address field, over the address it starts with, and
    /// presses Go.
    private func go(_ text: String) {
        app.buttons["address"].tap()
        let field = app.textFields["address-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The field starts with the address in it: cleared with its own
        // button, as a person would, rather than typed after.
        let clear = app.buttons["Clear"]
        if clear.waitForExistence(timeout: 1) { clear.tap() }
        field.typeText(text + "\n")
    }

    /// The address of a page served for the tests (UITests/Fixtures); the
    /// test is skipped when nothing serves them.
    private func fixture(_ name: String) throws -> String {
        guard let base = ProcessInfo.processInfo.environment["EDEN_FIXTURES"] else {
            throw XCTSkip("Run through apps/ios/scripts/test.sh, which serves the pages the tests load")
        }
        return base + "/" + name
    }

    /// The page's own words are on screen: it arrived.
    private func expectPage(_ words: String, timeout: TimeInterval = 20) {
        XCTAssertTrue(app.webViews.staticTexts[words].waitForExistence(timeout: timeout), "\(words) on the page")
    }

    /// A served page, opened from the address field, and there.
    private func open(_ page: String, showing words: String) throws {
        go(try fixture(page))
        expectPage(words)
    }

    /// The address field at rest says `label`.
    private func expectAddress(_ label: String, timeout: TimeInterval = 20) {
        let pill = app.buttons["address"]
        let shown = NSPredicate(format: "label CONTAINS %@", label)
        expectation(for: shown, evaluatedWith: pill)
        waitForExpectations(timeout: timeout)
    }

    private func expectEnabled(_ element: XCUIElement, timeout: TimeInterval = 10) {
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func openMenu(_ item: String) {
        let menu = app.buttons["menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let entry = labelled(item)
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "\(item) in the menu")
        entry.tap()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - the tests

    func testAnAddressOpensItsPage() throws {
        try open("page-one.html", showing: "PAGE-ONE")
        expectAddress("localhost")
        shot("page")
        XCTAssertTrue(app.buttons["reload"].exists)
    }

    /// Words go to the search engine. Its results page is the network's: this
    /// waits for its links rather than for words it may change.
    func testWordsAreSearched() {
        go("eden browser")
        expectAddress("google.com")
        expectation(for: NSPredicate(format: "count > 0"), evaluatedWith: app.webViews.links)
        waitForExpectations(timeout: 30)
        XCTAssertFalse(all("failure").firstMatch.exists, "the results arrived")
    }

    func testBackAndForwardFollowThePages() throws {
        try open("page-one.html", showing: "PAGE-ONE")
        try open("page-two.html", showing: "PAGE-TWO")
        // WebKit says it can go back a moment after the page arrives.
        expectEnabled(app.buttons["back"])
        app.buttons["back"].tap()
        expectPage("PAGE-ONE")
        expectEnabled(app.buttons["forward"])
        app.buttons["forward"].tap()
        expectPage("PAGE-TWO")
    }

    /// iPhone's tabs: the overview of cards. iPad has its sidebar instead.
    func testTabsOpenSwitchAndClose() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad shows its tabs in the sidebar")
        try open("page-one.html", showing: "PAGE-ONE")
        XCTAssertEqual(app.buttons["tabs"].label, "Tabs")
        app.buttons["tabs"].tap()
        XCTAssertTrue(app.buttons["new-tab"].waitForExistence(timeout: 5))
        shot("tabs")
        app.buttons["new-tab"].tap()
        // A new tab: the field asks for an address, and there are two tabs.
        XCTAssertTrue(app.buttons["address"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["address"].label, "Search or enter address")
        app.buttons["tabs"].tap()
        XCTAssertTrue(app.buttons["tabs-done"].waitForExistence(timeout: 5))
        XCTAssertEqual(all("tab-card").count, 2)
        // Back to the first, by its card.
        all("tab-card").element(boundBy: 0).tap()
        expectPage("PAGE-ONE")
        // Closing it leaves the other.
        app.buttons["tabs"].tap()
        XCTAssertTrue(app.buttons["tabs-done"].waitForExistence(timeout: 5))
        all("close-tab").element(boundBy: 0).tap()
        XCTAssertEqual(all("tab-card").count, 1)
        app.buttons["tabs-done"].tap()
    }

    /// iPad's tabs: down the sidebar, opened with its + and picked there.
    func testThePadShowsItsTabsInTheSidebar() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPhone shows its tabs as cards")
        try open("page-one.html", showing: "PAGE-ONE")
        let rows = all("tab-row")
        XCTAssertEqual(rows.count, 1)
        app.buttons["new-tab"].firstMatch.tap()
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: rows)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.buttons["address"].label, "Search or enter address", "the new tab is in front")
        try open("page-two.html", showing: "PAGE-TWO")
        shot("pad")
        rows.element(boundBy: 0).tap()
        expectPage("PAGE-ONE")
    }

    func testAPrivateTabSaysWhatItKeeps() throws {
        openMenu("New Private Tab")
        XCTAssertTrue(all("private-note").firstMatch.waitForExistence(timeout: 5))
        shot("private")
        try open("page-one.html", showing: "PAGE-ONE")
        // It isn't in history.
        openMenu("History")
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        XCTAssertEqual(all("history-row").count, 0)
    }

    func testABookmarkIsKeptAndOpens() throws {
        try open("page-one.html", showing: "PAGE-ONE")
        openMenu("Add Bookmark")
        // From another page, the bookmark takes the tab back to the first.
        try open("page-two.html", showing: "PAGE-TWO")
        openMenu("Bookmarks")
        let row = all("bookmark-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        shot("bookmarks")
        row.tap()
        expectPage("PAGE-ONE")
        // Once the sheet has gone, the menu offers to remove it.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.navigationBars["Bookmarks"])
        waitForExpectations(timeout: 5)
        app.buttons["menu"].firstMatch.tap()
        XCTAssertTrue(labelled("Remove Bookmark").waitForExistence(timeout: 5))
    }

    func testHistoryKeepsPlacesAndForgetsThem() throws {
        try open("page-one.html", showing: "PAGE-ONE")
        openMenu("History")
        let row = all("history-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        shot("history")
        app.buttons["clear-history"].tap()
        let clear = labelled("Clear History")
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(labelled("No History").waitForExistence(timeout: 5))
    }

    func testTheFieldSuggestsWhereYouHaveBeen() throws {
        try open("page-one.html", showing: "PAGE-ONE")
        app.buttons["address"].tap()
        let field = app.textFields["address-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let clear = app.buttons["Clear"]
        if clear.waitForExistence(timeout: 1) { clear.tap() }
        field.typeText("page-o")
        XCTAssertTrue(all("suggestion").firstMatch.waitForExistence(timeout: 5))
        shot("suggestions")
    }

    /// The blocker hides an ad slot on a page, and turned off in Settings,
    /// the slot shows again once the page reloads.
    func testTheBlockerHidesAdsUntilTurnedOff() throws {
        // Served over http by scripts/test.sh: the blocker, WebKit's content
        // rules, doesn't apply to a data: page.
        go(try fixture("ad-slot.html"))
        let plain = app.webViews.staticTexts["PLAIN-WORDS"]
        XCTAssertTrue(plain.waitForExistence(timeout: 20), "the page arrived")
        XCTAssertFalse(app.webViews.staticTexts["ADVERT-WORDS"].exists, "the ad slot is hidden")
        shot("blocked")

        openMenu("Settings")
        let blocks = app.switches["blocks"]
        XCTAssertTrue(blocks.waitForExistence(timeout: 5))
        blocks.switches.firstMatch.exists ? blocks.switches.firstMatch.tap() : blocks.tap()
        XCTAssertEqual(blocks.value as? String, "0")
        app.buttons["Done"].tap()
        app.buttons["reload"].tap()
        XCTAssertTrue(app.webViews.staticTexts["ADVERT-WORDS"].waitForExistence(timeout: 20), "the ad slot shows")
    }

    /// A page can't send itself to another app; a link tapped in it can,
    /// once you say so.
    func testAnotherAppOpensOnlyFromATappedLinkAndAfterAsking() throws {
        go(try fixture("app-links.html"))
        XCTAssertTrue(app.webViews.staticTexts["APP-LINKS"].waitForExistence(timeout: 20))
        // The page's own redirect, a moment after it loads: no question.
        sleep(2)
        XCTAssertFalse(app.alerts.firstMatch.exists, "a page sending itself away asks nothing")
        app.webViews.links["TEXT-SOMEONE"].tap()
        let ask = app.alerts.firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "a tapped link asks first")
        XCTAssertTrue(ask.staticTexts["This page wants to open another app (sms)."].exists)
        shot("open-app")
        ask.buttons["Cancel"].tap()
        XCTAssertTrue(app.webViews.staticTexts["APP-LINKS"].exists, "and Cancel stays on the page")
    }

    func testSettingsOffersTheEngineBlockerAndHandoff() {
        openMenu("Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["blocks"].exists)
        XCTAssertTrue(app.switches["handoff"].exists)
        XCTAssertEqual(app.switches["blocks"].value as? String, "1", "blocking is on unless turned off")
        XCTAssertEqual(app.switches["handoff"].value as? String, "0", "Handoff is off unless turned on")
        shot("settings")
    }
}
