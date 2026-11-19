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
        allowLocalNetwork()
        XCTAssertTrue(app.webViews.staticTexts[words].waitForExistence(timeout: timeout), "\(words) on the page")
    }

    /// On a real device the pages come over the local network
    /// (scripts/test-device.sh), which Eden asks once to reach.
    private func allowLocalNetwork() {
        #if !targetEnvironment(simulator)
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        #endif
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

    /// Whether the tabs are in the overview, as on iPhone, rather than the
    /// sidebar: the app goes by the window's width, and so do the tests.
    private var overview: Bool {
        let tabs = app.buttons["tabs"]
        _ = tabs.waitForExistence(timeout: 2)
        return tabs.exists
    }

    /// A new tab in front, from the tab overview or the sidebar.
    private func newTab() {
        if !overview {
            app.buttons["new-tab"].firstMatch.tap()
        } else {
            app.buttons["tabs"].tap()
            XCTAssertTrue(app.buttons["new-tab"].waitForExistence(timeout: 5))
            app.buttons["new-tab"].tap()
        }
        XCTAssertTrue(app.buttons["address"].waitForExistence(timeout: 5))
    }

    /// The tab at `index` in front, as above.
    private func switchToTab(_ index: Int) {
        if !overview {
            let row = all("tab-row").element(boundBy: index)
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
        } else {
            app.buttons["tabs"].tap()
            XCTAssertTrue(app.buttons["tabs-done"].waitForExistence(timeout: 5))
            all("tab-card").element(boundBy: index).tap()
        }
    }

    /// The thing showing `words` hidden by touch: picked, offered, hidden.
    private func hideByTouch(_ words: String) {
        openMenu("Hide Elements…")
        XCTAssertTrue(all("hiding-bar").firstMatch.waitForExistence(timeout: 5))
        app.webViews.staticTexts[words].tap()
        XCTAssertTrue(all("hiding-offer").firstMatch.waitForExistence(timeout: 5), "the tap offers it")
        app.buttons["hide-confirm"].tap()
        expectGone(words)
        app.buttons["hide-done"].tap()
    }

    /// Everything hidden on the site in front, restored from its sheet.
    private func restoreAllHere() {
        openMenu("Hidden on This Site")
        let all = app.buttons["restore-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        app.buttons["Done"].firstMatch.tap()
    }

    private func expectGone(_ words: String, timeout: TimeInterval = 5) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.webViews.staticTexts[words])
        waitForExpectations(timeout: timeout)
    }

    /// A switch in Settings turned on.
    private func turnOn(_ identifier: String) {
        openMenu("Settings")
        let toggle = app.switches[identifier]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String != "1" { toggle.switches.firstMatch.tap() }
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        app.buttons["Done"].firstMatch.tap()
    }

    /// Where the space in front's pins and switcher are: the sidebar, or the
    /// tab overview, opened.
    private func showTabs() {
        guard overview else { return }
        app.buttons["tabs"].tap()
        XCTAssertTrue(app.buttons["tabs-done"].waitForExistence(timeout: 5))
    }

    private func hideTabs() {
        let done = app.buttons["tabs-done"]
        guard done.exists else { return }
        done.tap()
    }

    /// The space in front's pins, wherever they are shown.
    private var pinTiles: XCUIElementQuery {
        let shown = app.buttons["tabs-done"].exists ? "tabs-pin-" : "sidebar-pin-"
        return app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", shown))
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
        // On iPhone, forward shows only once there is somewhere to go.
        if overview { XCTAssertFalse(app.buttons["forward"].exists, "nowhere to go forward yet") }
        app.buttons["back"].tap()
        expectPage("PAGE-ONE")
        XCTAssertTrue(app.buttons["forward"].waitForExistence(timeout: 10))
        expectEnabled(app.buttons["forward"])
        shot("back and forward")
        app.buttons["forward"].tap()
        expectPage("PAGE-TWO")
    }

    /// iPhone's controls shrink to the site's name while a page is read on
    /// down, and come back in full for a tap on it, or a look back up.
    func testTheBarShrinksWhileReading() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad's bar stays at the top")
        try open("tall.html", showing: "TOP-TEXT")
        shot("bar in full")
        let page = app.webViews.firstMatch
        let tucked = app.buttons["address-tucked"]
        page.swipeUp()
        XCTAssertTrue(tucked.waitForExistence(timeout: 5), "shrunk while reading on")
        XCTAssertFalse(app.buttons["tabs"].exists)
        shot("bar shrunk")
        tucked.tap()
        XCTAssertTrue(app.buttons["tabs"].waitForExistence(timeout: 5), "back in full for a tap")
        page.swipeUp()
        XCTAssertTrue(tucked.waitForExistence(timeout: 5))
        page.swipeDown()
        XCTAssertTrue(app.buttons["address"].waitForExistence(timeout: 5), "back in full looking back up")
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

    func testReadingModeShowsTheArticleAloneUntilLeft() throws {
        try open("article.html", showing: "ARTICLE-START")
        expectPage("NAV-HOME")
        openMenu("Reading Mode")
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.webViews.staticTexts["NAV-HOME"])
        waitForExpectations(timeout: 10)
        expectPage("ARTICLE-START")
        shot("reading")
        openMenu("Leave Reading Mode")
        expectPage("NAV-HOME")
        // A page with nothing to read says so.
        try open("page-one.html", showing: "PAGE-ONE")
        openMenu("Reading Mode")
        let notice = app.descendants(matching: .any)["notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "Nothing to read on this page")
    }

    func testAThingHiddenByTouchStaysHiddenUntilRestored() throws {
        try open("hide.html", showing: "BANNER-TEXT")
        openMenu("Hide Elements…")
        XCTAssertTrue(app.descendants(matching: .any)["hiding-bar"].waitForExistence(timeout: 5))
        app.webViews.staticTexts["BANNER-TEXT"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["hiding-offer"].waitForExistence(timeout: 5), "the tap offers it")
        shot("offered")
        app.buttons["hide-confirm"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.webViews.staticTexts["BANNER-TEXT"])
        waitForExpectations(timeout: 5)
        app.buttons["hide-done"].tap()
        // Opened again, it is still hidden.
        try open("hide.html", showing: "CONTENT-TEXT")
        XCTAssertFalse(app.webViews.staticTexts["BANNER-TEXT"].exists)
        openMenu("Hidden on This Site")
        let row = all("hidden-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        labelled("Restore").tap()
        app.buttons["Done"].firstMatch.tap()
        expectPage("BANNER-TEXT")
    }

    /// A change in one tab reaches the others: a page open there at once, and
    /// one coming back with Back — which WebKit may bring back from its
    /// cache as it was, scripts and all.
    func testWhatIsHiddenOrRestoredReachesEveryTabOnTheSite() throws {
        try open("hide.html", showing: "BANNER-TEXT")
        hideByTouch("BANNER-TEXT")
        newTab()
        try open("hide.html", showing: "CONTENT-TEXT")
        XCTAssertFalse(app.webViews.staticTexts["BANNER-TEXT"].exists, "hidden in a new tab")
        restoreAllHere()
        expectPage("BANNER-TEXT", timeout: 5)

        // The first tab, still on the page: restored there too.
        switchToTab(0)
        expectPage("BANNER-TEXT", timeout: 5)

        // Hidden again there, and left for another page.
        hideByTouch("BANNER-TEXT")
        try open("page-one.html", showing: "PAGE-ONE")
        switchToTab(1)
        expectGone("BANNER-TEXT")
        restoreAllHere()
        expectPage("BANNER-TEXT", timeout: 5)

        // Back in the first tab, the page — from WebKit's cache, as it was
        // left, scripts and all — as what is hidden says now.
        switchToTab(0)
        expectEnabled(app.buttons["back"])
        app.buttons["back"].tap()
        expectPage("CONTENT-TEXT")
        expectPage("FROM-CACHE", timeout: 5)
        expectPage("BANNER-TEXT", timeout: 5)
    }

    /// Picking takes taps, never the page's scrolling: a page still scrolls
    /// under a finger while picking, and a tap down there offers what it hit.
    func testAPageStillScrollsWhilePickingByTouch() throws {
        try open("tall.html", showing: "TOP-TEXT")
        openMenu("Hide Elements…")
        XCTAssertTrue(all("hiding-bar").firstMatch.waitForExistence(timeout: 5))
        let bottom = app.webViews.staticTexts["BOTTOM-TEXT"]
        let page = app.webViews.firstMatch
        for _ in 0..<8 where !bottom.isHittable { page.swipeUp() }
        shot("scrolled while picking")
        XCTAssertTrue(bottom.isHittable, "scrolled to the bottom while picking")
        XCTAssertFalse(all("hiding-offer").firstMatch.exists, "a swipe offers nothing")
        bottom.tap()
        let offer = all("hiding-offer").firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 5), "the tap offers it")
        XCTAssertTrue(offer.label.contains("BOTTOM-TEXT"), offer.label)
        app.buttons["hide-cancel"].tap()
        app.buttons["hide-done"].tap()
    }

    /// Spaces turned on, one made, each with its own tabs, and deleted.
    func testEachSpaceKeepsItsOwnTabs() throws {
        turnOn("uses-spaces")
        try open("page-one.html", showing: "PAGE-ONE")
        showTabs()
        app.buttons["space-switcher"].tap()
        app.buttons["space-new"].tap()
        let name = app.textFields["space-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Work")
        app.buttons["space-save"].tap()
        XCTAssertTrue(app.buttons["space-switcher"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["space-switcher"].label, "Space: Work")
        shot("work")
        hideTabs()
        try open("page-two.html", showing: "PAGE-TWO")

        // Back in Personal: its tab, as it was left.
        showTabs()
        app.buttons["space-switcher"].tap()
        app.buttons["space-option-00000000-0000-0000-0000-000000000001"].tap()
        hideTabs()
        expectPage("PAGE-ONE")

        // Work deleted, with its tab.
        showTabs()
        app.buttons["space-switcher"].tap()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'space-option-'"))
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: rows)
        waitForExpectations(timeout: 5)
        rows.element(boundBy: 1).swipeLeft()
        labelled("Delete").tap()
        let confirm = app.buttons["space-delete-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: rows)
        waitForExpectations(timeout: 5)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertEqual(app.buttons["space-switcher"].label, "Space: Personal")
        hideTabs()
        expectPage("PAGE-ONE")
    }

    /// A page pinned, taken elsewhere and brought home, and unpinned.
    func testAPinGoesHomeAndUnpinsKeepingThePage() throws {
        try open("page-one.html", showing: "PAGE-ONE")
        openMenu("Pin Tab")
        showTabs()
        expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: pinTiles)
        waitForExpectations(timeout: 5)
        shot("pinned")
        hideTabs()
        try open("page-two.html", showing: "PAGE-TWO")
        openMenu("Pin")
        let home = labelled("Go Home")
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        expectPage("PAGE-ONE")
        // Closed, it rests: still a pin, its page let go.
        openMenu("Pin")
        let close = labelled("Close Pin")
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        showTabs()
        expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: pinTiles)
        waitForExpectations(timeout: 5)
        pinTiles.firstMatch.tap()
        hideTabs()
        expectPage("PAGE-ONE")
        openMenu("Pin")
        let unpin = labelled("Unpin")
        XCTAssertTrue(unpin.waitForExistence(timeout: 5))
        unpin.tap()
        expectPage("PAGE-ONE")
        showTabs()
        XCTAssertEqual(pinTiles.count, 0)
        hideTabs()
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
        // The switch says so a moment later on a busy iPad.
        expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: blocks)
        waitForExpectations(timeout: 5)
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
