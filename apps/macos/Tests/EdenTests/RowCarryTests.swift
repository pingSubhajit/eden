import EdenCore
import AppKit
import SwiftUI
import XCTest
@testable import Eden

/// A tab carried down the column past a pair, which stands two lines tall:
/// the row stays under the hand and passes the pair at its middle. Hosted
/// as PinDragTests does, in a borderless window far off every screen.
@MainActor
final class RowCarryTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?
    /// How far down the run starts: at the column's top, with nothing kept
    /// above the line, so no line (#6); a group is among the tabs, under it.
    private var runTop: CGFloat = 0

    override class func setUp() {
        setenv("EDEN_PROBE", "row-carry-\(getpid())", 1)
        super.setUp()
    }

    /// From a space as a new install has it, whatever the suites before
    /// left in this process's world (CleanWorld).
    override func setUp() async throws {
        try await super.setUp()
        CleanWorld.reset()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("row-carry-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.subhajit.eden.beta.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.closeAll() }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(250))
        try await super.tearDown()
    }

    // MARK: - the places

    func testEvenPlacesMoveEachHalfStep() {
        let steps: [CGFloat] = [30, 30, 30, 30]
        XCTAssertEqual(Carried.leading(of: 2, in: steps), 60)
        XCTAssertEqual(Carried.slot(at: 30 + 14, carrying: 1, in: steps), 1)
        XCTAssertEqual(Carried.slot(at: 30 + 16, carrying: 1, in: steps), 2)
        XCTAssertEqual(Carried.slot(at: 30 - 16, carrying: 1, in: steps), 0)
        XCTAssertEqual(Carried.slot(at: 500, carrying: 1, in: steps), 3, "no further than the end")
        XCTAssertEqual(Carried.slot(at: -500, carrying: 1, in: steps), 0)
    }

    func testAPairIsPassedAtItsMiddle() {
        // one, a pair (two lines), four: four carried up.
        let steps: [CGFloat] = [30, 58, 30]
        XCTAssertEqual(Carried.slot(at: 88 - 28, carrying: 2, in: steps), 2, "not yet half the pair")
        XCTAssertEqual(Carried.slot(at: 88 - 30, carrying: 2, in: steps), 1)
        // Now above it: back down only past the same middle, so it can't
        // shuttle.
        XCTAssertEqual(Carried.slot(at: 88 - 30, carrying: 1, in: [30, 30, 58]), 1)
        XCTAssertEqual(Carried.slot(at: 88 - 28, carrying: 1, in: [30, 30, 58]), 2)
        // A pair carried down past one tab: the tab's half.
        XCTAssertEqual(Carried.slot(at: 30 + 16, carrying: 1, in: steps), 2)
    }

    /// What is carried down the column is kept in sight: never drawn past
    /// the end of the scrolling column, or above its top, where it was cut
    /// off; too long to fit, its top stays in sight.
    func testWhatIsCarriedIsKeptInSight() {
        // A row 28 long starting at 170, in sight 0–200.
        XCTAssertEqual(Carried.kept(0, top: 170, length: 28, within: 0...200), 0)
        XCTAssertEqual(Carried.kept(2, top: 170, length: 28, within: 0...200), 2, "just fits")
        XCTAssertEqual(Carried.kept(50, top: 170, length: 28, within: 0...200), 2, "past the end: held at it")
        XCTAssertEqual(Carried.kept(-500, top: 170, length: 28, within: 0...200), -170, "above the top: held at it")
        // Scrolled: in sight 300–500 of a longer column.
        XCTAssertEqual(Carried.kept(-100, top: 350, length: 28, within: 300...500), -50)
        XCTAssertEqual(Carried.kept(400, top: 350, length: 28, within: 300...500), 122)
        // A group taller than what is in sight: its top stays there.
        XCTAssertEqual(Carried.kept(90, top: 10, length: 300, within: 0...200), -10)
    }

    // MARK: - the real gesture

    /// "four" carried up past the pair and let go just over "one": it
    /// lands between "one" and the pair. With one step for every row it
    /// counted the pair as one line, ran a line ahead of the hand, and
    /// landed above "one".
    func testRowCarriedPastAPairLandsWhereItWasLetGo() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.pair(t[2], with: t[1], onLeft: false)
        browser.select(t[4])
        let window = makeWindow(browser)
        try await ready(browser)
        // one 0–28, the pair 30–86, four 88–116, five 118–146.
        let grab: CGFloat = 102
        try await send(.leftMouseDown, at: point(y: grab, in: window), in: window)
        for y in stride(from: grab - 2, through: grab - 60, by: -2) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        try await send(.leftMouseUp, at: point(y: grab - 60, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.tabs.map(\.id), [t[0], t[3], t[1], t[2], t[4]].map(\.id))
        XCTAssertNotNil(browser.split(for: t[1]), "the pair stays a pair")
    }

    // MARK: - with tab groups: the rows part where it would land

    /// "one", "two" and "three" in a group at the top, "four" and "five"
    /// in none below it. The group: its heading 3–25, its tabs 27–55,
    /// 57–85 and 87–115, its foot at 118; the loose tabs from 120, 30 apart.
    private func makeGrouped() -> (Browser, UUID, [Eden.Tab]) {
        let browser = makeBrowser()
        browser.prefs.usesTabGroups = true
        let t = browser.tabs
        let group = browser.addTabGroup(containing: t[0])
        for tab in t[1...2] { browser.move(tab, toGroup: group) }
        // Named: a new group's heading is its name being typed.
        browser.editingGroupID = nil
        browser.select(t[4])
        return (browser, group, t)
    }

    private func carry(from start: CGFloat, to end: CGFloat, in window: NSWindow,
                       letGo: Bool = true) async throws {
        try await send(.leftMouseDown, at: point(y: start, in: window), in: window)
        let step: CGFloat = end < start ? -2 : 2
        for y in stride(from: start + step, through: end, by: step) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        if letGo { try await send(.leftMouseUp, at: point(y: end, in: window), in: window) }
    }

    /// A muted tab's speaker, as Dia's, just after its icon: a click
    /// unmutes it, and doesn't go to the tab.
    func testTheSpeakerBesideTheIconMutesWithoutGoingToTheTab() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.select(t[4])
        t[1].toggleMute()
        let window = makeWindow(browser)
        try await ready(browser)
        // "two", 30–58: its icon, then the speaker's square.
        let x = 10 + Metrics.rowInset + browser.prefs.sideMark + Metrics.rowSpacing + RowCross.size / 2
        let at = NSPoint(x: x, y: window.frame.height - Metrics.strip - 44)
        try await send(.leftMouseDown, at: at, in: window)
        try await send(.leftMouseUp, at: at, in: window)
        try await settle()
        XCTAssertFalse(t[1].muted, "unmuted")
        XCTAssertEqual(browser.activeID, t[4].id, "still on the tab it was on")
    }

    func testAGroupIsCarriedByItsHeadingAmongTheTabs() async throws {
        let (browser, group, t) = makeGrouped()
        let window = makeWindow(browser)
        try await ready(browser)
        // The group's heading (3–25) down past "four" and "five", 30 each.
        try await carry(from: 14, to: 66, in: window, letGo: false)
        XCTAssertEqual(browser.sideItems.map(\.id), [.tab(t[3].id), .tab(t[4].id), .group(group)],
                       "the tabs made way before it was let go")
        try await send(.leftMouseUp, at: point(y: 66, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.sideItems.map(\.id), [.tab(t[3].id), .tab(t[4].id), .group(group)])
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[0], t[1], t[2]].map(\.id), "its tabs with it, in order")
        XCTAssertFalse(browser.tabGroups.first?.collapsed ?? true, "carried, not folded by the press")
    }

    func testATabCarriedAlongItsGroupMovesAsItGoes() async throws {
        let (browser, group, t) = makeGrouped()
        let window = makeWindow(browser)
        try await ready(browser)
        try await carry(from: 41, to: 101, in: window, letGo: false)
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[1], t[2], t[0]].map(\.id),
                       "the others made way before it was let go")
        try await send(.leftMouseUp, at: point(y: 101, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[1], t[2], t[0]].map(\.id), "and it stays where it was shown")
    }

    func testATabCarriedIntoAGroupLandsInTheGapItOpened() async throws {
        let (browser, group, t) = makeGrouped()
        let window = makeWindow(browser)
        try await ready(browser)
        // "five" up over "four", into the group, between "one" and "two".
        try await carry(from: 164, to: 60, in: window)
        try await settle()
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[0], t[4], t[1], t[2]].map(\.id))
        XCTAssertEqual(browser.tabs(in: nil).map(\.id), [t[3].id])
    }

    func testATabCarriedOutOfItsGroupLandsAmongTheLooseTabs() async throws {
        let (browser, group, t) = makeGrouped()
        let window = makeWindow(browser)
        try await ready(browser)
        // "two" down past "three", out of the group, below everything.
        try await carry(from: 71, to: 260, in: window)
        try await settle()
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[0], t[2]].map(\.id))
        XCTAssertEqual(browser.tabs(in: nil).map(\.id), [t[3], t[4], t[1]].map(\.id))
    }

    func testAFoldedGroupSpringsOpenUnderARestingTabAndFoldsAgainWhenLeft() async throws {
        let (browser, group, _) = makeGrouped()
        browser.toggleTabGroup(group)
        let window = makeWindow(browser)
        try await ready(browser)
        // Folded: its heading 3–25, its foot at 28; "four" 30–58, "five" 60–88.
        try await carry(from: 74, to: 14, in: window, letGo: false)
        XCTAssertEqual(browser.tabGroups.first?.collapsed, true, "not at once")
        try await Task.sleep(for: .milliseconds(Int(ColumnCarry.spring * 1000) + 300))
        XCTAssertEqual(browser.tabGroups.first?.collapsed, false, "open after resting on it")
        for y in stride(from: CGFloat(16), through: 300, by: 4) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        try await settle()
        XCTAssertEqual(browser.tabGroups.first?.collapsed, true, "folded again once the tab went elsewhere")
        try await send(.leftMouseUp, at: point(y: 300, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.tabs(in: group).count, 3)
    }

    // MARK: - what the carry does before it is let go, for #6's one carry
    //
    // The carry below the line, pinned down before it was rewritten as one
    // carry for the whole column (#6), and kept since: where the rows part
    // while the tab is still held (SideBar.shownGap, the carry and the
    // place the rows open at), what moves along its own run as it goes,
    // and where it lands. The group of
    // makeGrouped at the top: its heading 3–25, one 27–55, two 57–85,
    // three 87–115, its foot at 118; four 120–148, five 150–178.

    /// A tab in no group carried up over a group: its own run (the tabs in
    /// none) doesn't move, the group's rows part where it would land, and
    /// the gap follows the hand from tab to tab until it is let go there.
    func testTheGroupsRowsPartLiveForATabCarriedIntoIt() async throws {
        let (browser, group, t) = makeGrouped()
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // "five" up past "four": along its own run, it moves as it goes.
        try await carry(from: 164, to: 128, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(browser.tabs(in: nil).map(\.id), [t[4], t[3]].map(\.id), "four made way, while held")
        XCTAssertNil(SideBar.shownGap, "no gap along its own run")
        // On up over "three", then "two": the group parts before each.
        for y in stride(from: CGFloat(126), through: 100, by: -2) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.place, ColumnPlace(area: .open, group: group, index: 2), "over three's upper half: before three")
        XCTAssertEqual(SideBar.shownGap?.carried, .tab(t[4].id))
        XCTAssertEqual(SideBar.shownGap?.whole, true)
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[0], t[1], t[2]].map(\.id), "nothing moved into it yet")
        for y in stride(from: CGFloat(98), through: 66, by: -2) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.place, ColumnPlace(area: .open, group: group, index: 1), "on up: before two")
        try await send(.leftMouseUp, at: point(y: 66, in: window), in: window)
        try await settle()
        XCTAssertNil(SideBar.shownGap, "closed once let go")
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[0], t[4], t[1], t[2]].map(\.id), "where the gap was")
        XCTAssertEqual(browser.tabs(in: nil).map(\.id), [t[3].id])
    }

    /// A tab of a group carried down out of it: the tabs in no group part
    /// for it before the one it is over, and it lands there; carried back
    /// over its own group before it is let go, the gap closes and it stays.
    func testTheLooseTabsPartLiveForATabCarriedOutOfItsGroup() async throws {
        let (browser, group, t) = makeGrouped()
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // "one" down past "two" and "three": along its own group it moves as
        // it goes, no gap.
        try await carry(from: 41, to: 101, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[1], t[2], t[0]].map(\.id))
        XCTAssertNil(SideBar.shownGap)
        // On down, out of the group, over "four": the tabs in none part.
        for y in stride(from: CGFloat(103), through: 150, by: 2) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.place, ColumnPlace(area: .open, index: 2), "a gap among the tabs in no group, before five")
        XCTAssertEqual(browser.group(of: t[0]), group, "still in its group while held")
        // Back up over its group: the gap there closes, and it moves along
        // its own group again.
        for y in stride(from: CGFloat(148), through: 70, by: -2) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        try await settle()
        XCTAssertNil(SideBar.shownGap, "back over its own group: no gap")
        try await send(.leftMouseUp, at: point(y: 70, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.group(of: t[0]), group, "stays in its group")
        XCTAssertEqual(browser.tabs(in: nil).map(\.id), [t[3], t[4]].map(\.id))
    }

    /// A tab in no group carried down past a group: over the group's rows it
    /// opens a gap in the group, and past the group's foot it is back in
    /// its own run, the group making way for it as a tab would.
    func testATabCarriedPastAGroupOpensAGapOnlyWhileOverIt() async throws {
        let (browser, group, t) = makeGrouped()
        // "four" first, the group under it, then "five".
        browser.moveItem(.tab(t[3].id), to: 0)
        XCTAssertEqual(browser.sideItems.map(\.id), [.tab(t[3].id), .group(group), .tab(t[4].id)])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // four 0–28; the group from 30: its heading 33–55, one 57–85, two
        // 87–115, three 117–145, its foot at 148; five 150–178.
        try await carry(from: 14, to: 100, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.place?.area, .open)
        XCTAssertEqual(SideBar.shownGap?.group, group, "over the group's rows: a gap in it")
        XCTAssertEqual(browser.sideItems.first?.id, .tab(t[3].id), "its own place kept in the row while held")
        for y in stride(from: CGFloat(102), through: 200, by: 2) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        try await settle()
        try await send(.leftMouseUp, at: point(y: 200, in: window), in: window)
        try await settle()
        XCTAssertNil(SideBar.shownGap)
        XCTAssertNil(browser.group(of: t[3]), "in no group")
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[0], t[1], t[2]].map(\.id))
        XCTAssertEqual(browser.sideItems.map(\.id), [.group(group), .tab(t[4].id), .tab(t[3].id)],
                       "past the group and five: last")
    }

    /// A pair in no group carried up into a group: the gap is the pair's
    /// two lines, and the pair lands whole, still a pair, in the group.
    func testAPairCarriedIntoAGroupOpensAGapOfTwoLines() async throws {
        let (browser, group, t) = makeGrouped()
        browser.pair(t[4], with: t[3], onLeft: false)
        browser.select(t[0])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // The pair 120–176, its first line four's.
        try await carry(from: 134, to: 60, in: window, letGo: false)
        try await settle()
        let gap = try XCTUnwrap(SideBar.shownGap, "a gap in the group")
        XCTAssertEqual(gap.place, ColumnPlace(area: .open, group: group, index: 1))
        XCTAssertEqual(gap.whole, true, "the pair whole")
        XCTAssertEqual(gap.height, 2 * 28, accuracy: 0.5, "the pair's two lines")
        try await send(.leftMouseUp, at: point(y: 60, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[0], t[3], t[4], t[1], t[2]].map(\.id))
        XCTAssertNotNil(browser.split(for: t[3]), "still a pair")
        XCTAssertTrue(browser.tabs(in: nil).isEmpty)
    }

    /// A group carried along the run by its heading, down past one tab and
    /// back up: the tabs make way as it goes, no gap opens anywhere, its
    /// tabs stay its own, and it is left open.
    func testAGroupCarriedDownAndBackMovesAsItGoes() async throws {
        let (browser, group, t) = makeGrouped()
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        try await carry(from: 14, to: 50, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(browser.sideItems.map(\.id), [.tab(t[3].id), .group(group), .tab(t[4].id)], "past four, while held")
        XCTAssertNil(SideBar.shownGap, "a group opens no gap")
        for y in stride(from: CGFloat(48), through: 4, by: -2) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        try await settle()
        XCTAssertEqual(browser.sideItems.map(\.id), [.group(group), .tab(t[3].id), .tab(t[4].id)], "back up, while held")
        try await send(.leftMouseUp, at: point(y: 4, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.sideItems.map(\.id), [.group(group), .tab(t[3].id), .tab(t[4].id)])
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[0], t[1], t[2]].map(\.id))
        XCTAssertEqual(browser.tabGroups.first?.collapsed, false)
        XCTAssertNil(SideBar.shownGap)
    }

    // MARK: - one carry for the whole column (#6)
    //
    // Above the line the rows part as they do under it: a tab carried up
    // over the kept area, into a kept group, a group carried across the
    // line and back, a square carried into the rows and a row onto the
    // squares, and what won't go there holding still with nothing parted.

    /// Pins and kept groups are the space's, in every window: put away
    /// after the test, or the next one's column starts lower.
    private func keepsClean(_ browser: Browser) {
        addTeardownBlock { @MainActor in
            Pins.setGroups(browser.spaceID, [], from: nil)
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
        }
    }

    /// "four" carried up over the line: the kept rows part for it where it
    /// would land, before it is let go, and it is pinned there.
    func testTheKeptRowsPartLiveForATabCarriedAboveTheLine() async throws {
        let browser = makeBrowser()
        keepsClean(browser)
        let t = browser.tabs
        browser.pin(t[0], listed: true)
        browser.pin(t[1], listed: true)
        browser.select(t[4])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // Above the line: one 0–28, two 30–58; the line 60–78; under it
        // three 80–108, four 110–138, five 140–168.
        try await carry(from: 124, to: 40, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.place, ColumnPlace(area: .kept, index: 1), "the kept rows part before two")
        XCTAssertEqual(SideBar.shownGap?.carried, .tab(t[3].id))
        XCTAssertEqual(SideBar.shownGap?.height ?? 0, 28, accuracy: 0.5)
        XCTAssertNil(t[3].pin, "not pinned while held")
        try await send(.leftMouseUp, at: point(y: 40, in: window), in: window)
        try await settle()
        XCTAssertNil(SideBar.shownGap)
        XCTAssertEqual(browser.listedPins.map(\.id), [t[0], t[3], t[1]].map(\.id), "where the gap was")
        XCTAssertTrue(t[3].listed)
    }

    /// "five" carried up into a kept group: its rows part for it as an open
    /// group's do, and it lands in the group, pinned, where they parted.
    func testAKeptGroupsRowsPartLiveForATabCarriedIntoIt() async throws {
        let browser = makeBrowser()
        keepsClean(browser)
        let t = browser.tabs
        browser.pin(t[0], listed: true)
        browser.pin(t[1], listed: true)
        let work = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: t[0], rename: false))
        XCTAssertTrue(browser.move(t[1], to: ColumnPlace(area: .kept, group: work)))
        browser.select(t[4])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // Work: its heading 3–25, one 27–55, two 57–85, its foot at 88; the
        // line 90–108; three 110–138, four 140–168, five 170–198.
        try await carry(from: 184, to: 60, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.place, ColumnPlace(area: .kept, group: work, index: 1), "before two, in Work")
        XCTAssertNil(t[4].pin)
        try await send(.leftMouseUp, at: point(y: 60, in: window), in: window)
        try await settle()
        XCTAssertNil(SideBar.shownGap)
        XCTAssertEqual(browser.members(ofGroup: work).map(\.id), [t[0], t[4], t[1]].map(\.id))
        XCTAssertTrue(t[4].listed)
        XCTAssertEqual(t[4].keptGroupID, work)
    }

    /// A tab group carried up by its heading over the line: the kept area
    /// parts for the whole group, its place under the line closing, and let
    /// go it is a kept group there; carried back down, the open area parts
    /// for it, and it is an open group again.
    func testAGroupCarriedAboveTheLineAndBackPartsTheRowsBothWays() async throws {
        let browser = makeBrowser()
        keepsClean(browser)
        browser.prefs.usesTabGroups = true
        let t = browser.tabs
        browser.pin(t[0], listed: true)
        let group = browser.addTabGroup(containing: t[2])
        browser.move(t[3], toGroup: group)
        browser.editingGroupID = nil
        browser.select(t[4])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // one 0–28; the line 30–48; two 50–78; the group 80–168, its
        // heading 83–105; five 170–198.
        try await carry(from: 94, to: 10, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.place, ColumnPlace(area: .kept, index: 0), "above one")
        XCTAssertEqual(SideBar.shownGap?.carried, .group(group))
        XCTAssertEqual(SideBar.shownGap?.height ?? 0, 88, accuracy: 0.5, "the whole group's room")
        XCTAssertEqual(browser.area(ofGroup: group), .open, "still open while held")
        try await send(.leftMouseUp, at: point(y: 10, in: window), in: window)
        try await settle()
        XCTAssertNil(SideBar.shownGap)
        XCTAssertEqual(browser.area(ofGroup: group), .kept)
        XCTAssertEqual(browser.keptItems().map(\.id), [.group(group), .tab(t[0].id)])
        XCTAssertEqual([t[2], t[3]].map { $0.pin != nil && $0.listed }, [true, true])

        // The group 0–88, its heading 3–25; one 90–118; the line 120–138;
        // two 140–168, five 170–198.
        try await carry(from: 14, to: 160, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.place, ColumnPlace(area: .open, index: 1), "between two and five")
        XCTAssertEqual(browser.area(ofGroup: group), .kept, "still kept while held")
        try await send(.leftMouseUp, at: point(y: 160, in: window), in: window)
        try await settle()
        XCTAssertNil(SideBar.shownGap)
        XCTAssertEqual(browser.area(ofGroup: group), .open)
        XCTAssertEqual(browser.sideItems.map(\.id), [.tab(t[1].id), .group(group), .tab(t[4].id)])
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [t[2], t[3]].map(\.id))
        XCTAssertEqual([t[2], t[3]].map(\.pin), [nil, nil])
    }

    /// A square carried down into the rows: they part for it above the
    /// line, and it is a pinned row there; that row carried back up onto
    /// the grid is a square again.
    func testASquareCarriedIntoTheRowsAndBack() async throws {
        let browser = makeBrowser()
        keepsClean(browser)
        let t = browser.tabs
        browser.pin(t[0])
        browser.pin(t[1], listed: true)
        browser.select(t[4])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // The grid, 34 and 10 under it; then two 0–28, the line 30–48.
        let room = browser.prefs.sideWidth - 20
        func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: window.frame.height - Metrics.strip - y) }
        try await send(.leftMouseDown, at: at(10 + room / 6, 17), in: window)
        for y in stride(from: CGFloat(19), through: 44 + 50, by: 2) {
            try await send(.leftMouseDragged, at: at(10 + room / 6 + (y - 17) / 2, y), in: window)
        }
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.place, ColumnPlace(area: .kept), "after two, above the line")
        XCTAssertEqual(SideBar.shownGap?.carried, .tab(t[0].id))
        try await send(.leftMouseUp, at: at(10 + room / 6 + 38, 44 + 50), in: window)
        try await settle()
        XCTAssertNil(SideBar.shownGap)
        XCTAssertTrue(t[0].listed, "a row")
        XCTAssertEqual(browser.listedPins.map(\.id), [t[1], t[0]].map(\.id))
        XCTAssertTrue(browser.squarePins.isEmpty)

        // No grid now: two 0–28, one 30–58. One carried up off the rows,
        // where the first square is made, and back down onto the grid that
        // opened for it.
        try await send(.leftMouseDown, at: at(70, 44), in: window)
        for y in stride(from: CGFloat(42), through: -12, by: -2) {
            try await send(.leftMouseDragged, at: at(70, y), in: window)
        }
        for y in stride(from: CGFloat(-10), through: 10, by: 2) {
            try await send(.leftMouseDragged, at: at(70, y), in: window)
        }
        try await send(.leftMouseUp, at: at(70, 10), in: window)
        try await settle()
        XCTAssertFalse(t[0].listed, "a square again")
        XCTAssertEqual(browser.squarePins.map(\.id), [t[0].id])
        XCTAssertEqual(browser.listedPins.map(\.id), [t[1].id])
    }

    /// A square every space shows carried down into the rows: they part at
    /// the head of the kept area for it, and it is a row every space shows
    /// there; carried back onto the grid, a square every space shows again.
    func testASharedSquareCarriedIntoTheRowsAndBackStaysShared() async throws {
        let browser = makeBrowser()
        keepsClean(browser)
        let prefs = browser.prefs
        let shared = (prefs.usesSpaces, prefs.sharesPins)
        defer { (prefs.usesSpaces, prefs.sharesPins) = shared }
        prefs.usesSpaces = true
        prefs.sharesPins = true
        let t = browser.tabs
        browser.pin(t[0])
        browser.shareEverywhere(t[0])
        browser.pin(t[1], listed: true)
        browser.select(t[4])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // The grid, 34 and 10 under it; then two 0–28, the line 30–48.
        let room = browser.prefs.sideWidth - 20
        func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: window.frame.height - Metrics.strip - y) }
        try await send(.leftMouseDown, at: at(10 + room / 6, 17), in: window)
        for y in stride(from: CGFloat(19), through: 44 + 20, by: 2) {
            try await send(.leftMouseDragged, at: at(10 + room / 6 + (y - 17) / 2, y), in: window)
        }
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.place, ColumnPlace(area: .kept, index: 0), "at the head, over two")
        try await send(.leftMouseUp, at: at(10 + room / 6 + 23, 44 + 20), in: window)
        try await settle()
        XCTAssertTrue(t[0].listed, "a row")
        XCTAssertTrue(t[0].everywhere, "still every space's")
        XCTAssertEqual(browser.listedPins.map(\.id), [t[0], t[1]].map(\.id))

        // No grid now: one 0–28, two 30–58. One carried up onto the grid
        // that opens for it: in front first, its page made, so the press
        // that picks it up doesn't start it loading under the hand.
        browser.select(t[0])
        try await ready(browser)
        try await send(.leftMouseDown, at: at(70, 14), in: window)
        for y in stride(from: CGFloat(12), through: -12, by: -2) { try await send(.leftMouseDragged, at: at(70, y), in: window) }
        for y in stride(from: CGFloat(-10), through: 10, by: 2) { try await send(.leftMouseDragged, at: at(70, y), in: window) }
        try await send(.leftMouseUp, at: at(70, 10), in: window)
        try await settle()
        XCTAssertFalse(t[0].listed, "a square again")
        XCTAssertTrue(t[0].everywhere)
        XCTAssertEqual(browser.squarePins.map(\.id), [t[0].id])
        browser.keepHere(t[0])
    }

    /// A tab carried onto another device's folded group: the group shows
    /// its pages and the gap at their end, the line and the tabs under it
    /// drawn where the layout has them, and let go anywhere over the pages
    /// drawn it is opened on that device, kept here where it was.
    func testATabCarriedOntoAFoldedDevicesGroupGoesToTheDevice() async throws {
        let browser = makeBrowser()
        let wasOn = Sync.shared.on
        // Its page is a real address, which the session keeps, unlike the
        // blank ones the other tests use: none left for the next to start
        // with, nor the pretended phone.
        addTeardownBlock { @MainActor in
            browser.closeAll()
            Sync.shared.pretend([], on: wasOn)
            CleanWorld.reset()
        }
        let pages = ["https://a.phone.invalid/", "https://b.phone.invalid/", "https://c.phone.invalid/"]
        Sync.shared.pretend([DeviceTabs(device: "phone", name: "Phone", kind: .iphone,
                                        tabs: pages.map { DeviceTabs.Page(url: $0, title: "", space: nil) }, at: 0)], on: true)
        let t = browser.tabs
        t[4].restore(url: URL(string: "https://five.invalid/")!, title: "five")
        browser.select(t[4])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // The phone's group, folded, 0–28; the line 30–48; one 50–78 … five
        // 170–198. Five carried up onto the phone's heading.
        try await carry(from: 184, to: 14, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.device, "phone")
        // Its three pages and the gap shown: the line and the tabs under it
        // where they are laid out, 120 further down.
        XCTAssertEqual(SideBar.lineLaid, 150)
        XCTAssertEqual(SideBar.lineDrawn, 150, "drawn where it is laid out")
        // Down over its pages, as drawn: still the device's.
        for y in stride(from: CGFloat(16), through: 120, by: 2) {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
        }
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.device, "phone", "over its pages")
        try await send(.leftMouseUp, at: point(y: 120, in: window), in: window)
        try await settle()
        XCTAssertNil(t[4].pin, "not pinned here")
        XCTAssertEqual(browser.tabs(in: nil).map(\.id), t.map(\.id), "kept here where it was")
        let phone = Sync.shared.devicesWithTabs.first { $0.device == "phone" }
        XCTAssertTrue(phone?.tabs.contains { $0.url == "https://five.invalid/" } == true, "opened there")
        XCTAssertEqual(SideBar.lineDrawn, SideBar.lineLaid, "and the line where it is laid out once let go")
    }

    /// As the owner has it: two devices with pages, the phone folded and
    /// the pad open, at the top; pinned rows under them; the line, New tab
    /// at the top, then the tabs. A tab carried up to the phone's heading,
    /// and another onto the pad's pages, goes to that device.
    func testATabCarriedUpPastTheKeptRowsOntoADeviceGoesToIt() async throws {
        let browser = makeBrowser()
        keepsClean(browser)
        let wasOn = Sync.shared.on
        addTeardownBlock { @MainActor in
            browser.closeAll()
            Sync.shared.pretend([], on: wasOn)
            CleanWorld.reset()
        }
        func pages(_ host: String, _ count: Int) -> [DeviceTabs.Page] {
            (0..<count).map { DeviceTabs.Page(url: "https://\(host).invalid/\($0)", title: "Page \($0)", space: nil) }
        }
        Sync.shared.pretend([DeviceTabs(device: "phone", name: "iPhone", kind: .iphone, tabs: pages("phone", 3), at: 0),
                             DeviceTabs(device: "pad", name: "iPad", kind: .ipad, tabs: pages("pad", 2), at: 0)], on: true)
        let t = browser.tabs
        browser.pin(t[0], listed: true)
        browser.pin(t[1], listed: true)
        browser.prefs.newTabPlace = .top
        t[3].restore(url: URL(string: "https://four.invalid/")!, title: "four")
        t[4].restore(url: URL(string: "https://five.invalid/")!, title: "five")
        browser.select(t[4])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // The phone 0–28 and the pad 30–58, folded; one 60–88, two 90–118;
        // the line 120–138; New tab 140–168; three 170–198, four 200–228,
        // five 230–258. Five carried up past it all onto the phone's heading.
        try await carry(from: 244, to: 14, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.device, "phone")
        try await send(.leftMouseUp, at: point(y: 14, in: window), in: window)
        try await settle()
        XCTAssertTrue(Sync.shared.devicesWithTabs.first { $0.device == "phone" }?.tabs.contains { $0.url == "https://five.invalid/" } == true,
                      "opened on the phone")
    }

    /// One of your tabs carried onto a device's group that already has its
    /// page open: the device won't take it, so nothing parts and it holds
    /// still; let go, it stays where it was, unpinned. It used to fall
    /// through to the kept area under the devices and be pinned.
    func testATabADeviceHasOpenAlreadyHoldsStillOverIt() async throws {
        let browser = makeBrowser()
        keepsClean(browser)
        let wasOn = Sync.shared.on
        addTeardownBlock { @MainActor in
            browser.closeAll()
            Sync.shared.pretend([], on: wasOn)
            CleanWorld.reset()
        }
        Sync.shared.pretend([DeviceTabs(device: "phone", name: "iPhone", kind: .iphone,
                                        tabs: [DeviceTabs.Page(url: "https://five.invalid/", title: "five", space: nil),
                                               DeviceTabs.Page(url: "https://other.invalid/", title: "other", space: nil)], at: 0)],
                            on: true)
        let t = browser.tabs
        t[4].restore(url: try XCTUnwrap(URL(string: "https://five.invalid/")), title: "five")
        browser.select(t[4])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // The phone's group, folded, 0–28; the line 30–48; one 50–78 … five
        // 170–198. Five carried up onto the phone's heading.
        try await carry(from: 184, to: 14, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(CarryGuard.count, 1, "carried")
        XCTAssertNil(SideBar.shownGap, "nothing parts: not the phone, not the kept area")
        try await send(.leftMouseUp, at: point(y: 14, in: window), in: window)
        try await settle()
        XCTAssertNil(t[4].pin, "not pinned")
        XCTAssertTrue(browser.listedPins.isEmpty)
    }

    /// A square gone on from its home, carried onto another device's
    /// group: a pin never goes to a device, so it goes to the head of the
    /// kept area under the group, a pinned row there, and the device is
    /// asked nothing.
    func testASquareOverADevicesGroupGoesToTheKeptAreaNotTheDevice() async throws {
        let browser = makeBrowser()
        keepsClean(browser)
        let wasOn = Sync.shared.on
        addTeardownBlock { @MainActor in Sync.shared.pretend([], on: wasOn) }
        Sync.shared.pretend([DeviceTabs(device: "phone", name: "Phone", kind: .iphone,
                                        tabs: [DeviceTabs.Page(url: "https://a.phone.invalid/", title: "", space: nil)], at: 0)],
                            on: true)
        let t = browser.tabs
        browser.pin(t[0])
        // Wandered: a page the devices could be shown.
        t[0].restore(url: try XCTUnwrap(URL(string: "https://wandered.invalid/")), title: "wandered")
        XCTAssertNotNil(Sync.page(of: t[0], in: browser.spaceID))
        browser.select(t[4])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // The grid, 34 and 10 under it; then the phone's group 0–28, the
        // line 30–48.
        let room = browser.prefs.sideWidth - 20
        func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: window.frame.height - Metrics.strip - y) }
        try await send(.leftMouseDown, at: at(10 + room / 6, 17), in: window)
        for y in stride(from: CGFloat(19), through: 44 + 14, by: 2) {
            try await send(.leftMouseDragged, at: at(10 + room / 6 + (y - 17) / 2, y), in: window)
        }
        try await settle()
        XCTAssertNil(SideBar.shownGap?.device, "not the device")
        XCTAssertEqual(SideBar.shownGap?.place, ColumnPlace(area: .kept), "the kept area under it")
        try await send(.leftMouseUp, at: at(10 + room / 6 + 20, 44 + 14), in: window)
        try await settle()
        XCTAssertTrue(t[0].listed, "a pinned row")
        let phone = Sync.shared.devicesWithTabs.first { $0.device == "phone" }
        XCTAssertFalse(phone?.tabs.contains { $0.url == "https://wandered.invalid/" } == true, "nothing sent")
    }

    /// New tabs at the top: one 0–28, two 30–58 above the line 60–78, New
    /// tab 80–108, then three 110–138, four 140–168, five 170–198.
    private func newTabOnTopWithTwoRows() -> (Browser, [Eden.Tab]) {
        let browser = makeBrowser()
        keepsClean(browser)
        let t = browser.tabs
        browser.pin(t[0], listed: true)
        browser.pin(t[1], listed: true)
        browser.prefs.newTabPlace = .top
        browser.select(t[4])
        return (browser, t)
    }

    /// A pinned row carried down onto the New Tab row: the head of your
    /// tabs, the gap straight under New tab, and it lands first among them.
    func testAKeptRowCarriedOverNewTabLandsAtTheHeadOfYourTabs() async throws {
        let (browser, t) = newTabOnTopWithTwoRows()
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        try await carry(from: 44, to: 94, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.place, ColumnPlace(area: .open, index: 0), "the head of your tabs")
        try await send(.leftMouseUp, at: point(y: 94, in: window), in: window)
        try await settle()
        XCTAssertNil(t[1].pin, "unpinned")
        XCTAssertEqual(browser.tabs.filter { $0.pin == nil }.first?.id, t[1].id, "first of your tabs")
        XCTAssertEqual(browser.listedPins.map(\.id), [t[0].id])
    }

    /// One of your tabs carried up onto the New Tab row: along its own run
    /// to the head of it, nothing parted, and it lands first.
    func testATabCarriedOverNewTabLandsAtTheHead() async throws {
        let (browser, t) = newTabOnTopWithTwoRows()
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        try await carry(from: 154, to: 94, in: window, letGo: false)
        try await settle()
        XCTAssertNil(SideBar.shownGap, "nothing parts: it is along its own run")
        XCTAssertEqual(browser.tabs.filter { $0.pin == nil }.first?.id, t[3].id, "already first while held")
        try await send(.leftMouseUp, at: point(y: 94, in: window), in: window)
        try await settle()
        XCTAssertNil(t[3].pin)
        XCTAssertEqual(browser.tabs.filter { $0.pin == nil }.map(\.id), [t[3], t[2], t[4]].map(\.id))
    }

    /// What can't go above the line holds still with nothing parted: a
    /// private tab, which can't be pinned.
    func testAPrivateTabCarriedAboveTheLineOpensNothing() async throws {
        let browser = makeBrowser()
        keepsClean(browser)
        let t = browser.tabs
        browser.pin(t[0], listed: true)
        browser.select(t[4])
        browser.newShyTab()
        let shy = try XCTUnwrap(browser.tabs.first(where: \.shy))
        shy.restore(url: URL(string: "about:blank#shy")!, title: "shy")
        browser.select(t[4])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // one 0–28; the line 30–48; two 50–78 … five 140–168, the private
        // tab 170–198.
        try await carry(from: 184, to: 10, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(CarryGuard.count, 1, "carried")
        XCTAssertEqual(browser.sideItems.first?.id, .tab(shy.id), "along its own run it moved as it went")
        XCTAssertNil(SideBar.shownGap, "nothing parts above the line for it")
        try await send(.leftMouseUp, at: point(y: 10, in: window), in: window)
        try await settle()
        XCTAssertNil(shy.pin, "not pinned")
        XCTAssertEqual(browser.listedPins.map(\.id), [t[0].id])
    }

    /// A group holds tabs only: a tab group carried up over a kept group's
    /// rows parts the kept area after that group, never inside it, and let
    /// go it is a kept group of its own there.
    func testAGroupCarriedOverAKeptGroupGoesBesideItNeverInIt() async throws {
        let browser = makeBrowser()
        keepsClean(browser)
        browser.prefs.usesTabGroups = true
        let t = browser.tabs
        browser.pin(t[0], listed: true)
        let work = try XCTUnwrap(browser.newKeptGroup(named: "Work", holding: t[0], rename: false))
        let group = browser.addTabGroup(containing: t[2])
        browser.move(t[3], toGroup: group)
        browser.editingGroupID = nil
        browser.select(t[4])
        let window = makeWindow(browser)
        try await ready(browser)
        SideBar.shownGap = nil
        // Work 0–58, one 27–55 in it; the line 60–78; two 80–108; the group
        // 110–198, its heading 113–135; five 200–228.
        try await carry(from: 124, to: 40, in: window, letGo: false)
        try await settle()
        XCTAssertEqual(SideBar.shownGap?.place, ColumnPlace(area: .kept), "after Work, at the top level")
        XCTAssertNil(SideBar.shownGap?.group, "never in Work")
        try await send(.leftMouseUp, at: point(y: 40, in: window), in: window)
        try await settle()
        XCTAssertEqual(browser.keptGroups.map(\.id), [work, group])
        XCTAssertEqual(browser.members(ofGroup: work).map(\.id), [t[0].id])
        XCTAssertEqual(browser.members(ofGroup: group).map(\.id), [t[2], t[3]].map(\.id))
    }

    /// The column mid-carry, with a red line where the hand is, for looking
    /// at by eye: only when ROW_CARRY_SHOTS names a folder. "five" is
    /// carried up past "four", the pair and "one", and back down.
    func testLooks() async throws {
        guard let folder = ProcessInfo.processInfo.environment["ROW_CARRY_SHOTS"] else { return }
        let browser = makeBrowser()
        let t = browser.tabs
        browser.pair(t[2], with: t[1], onLeft: false)
        browser.select(t[0])
        let window = makeWindow(browser)
        try await ready(browser)
        // five's middle: 132.
        let path = Array(stride(from: CGFloat(132), through: 10, by: -2)) + Array(stride(from: CGFloat(12), through: 132, by: 2))
        try await send(.leftMouseDown, at: point(y: path[0], in: window), in: window)
        for (n, y) in path.enumerated() {
            try await send(.leftMouseDragged, at: point(y: y, in: window), in: window)
            try await Task.sleep(for: .milliseconds(20))
            guard n % 3 == 0, let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.systemRed.setFill()
            NSRect(x: 0, y: view.bounds.height - Metrics.strip - y - 0.5, width: 8, height: 1).fill()
            NSRect(x: view.bounds.width - 8, y: view.bounds.height - Metrics.strip - y - 0.5, width: 8, height: 1).fill()
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: String(format: "%@/%03d.png", folder, n)))
        }
        try await send(.leftMouseUp, at: point(y: path.last!, in: window), in: window)
        try await settle()
    }


    /// Carried down off the row across the top, the tab goes with the hand
    /// in a window of its own, and comes back to its row on the way back.
    /// ROW_CARRY_SHOTS: the last tab carried past the run's end, and the tab
    /// off the row, for looking at by eye.
    func testATabCarriedOffTheTopRowIsLifted() async throws {
        let browser = makeBrowser()
        browser.prefs.sidebar = false
        browser.select(browser.tabs[4])
        let shots = ProcessInfo.processInfo.environment["ROW_CARRY_SHOTS"]
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: Metrics.strip),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabBar(browser: browser))
        window.orderFrontRegardless()
        windows.append(window)
        try await settle()
        let inside = NSPoint(x: window.frame.midX, y: window.frame.midY)
        TabDrag.testPointer = inside
        defer { TabDrag.testPointer = nil }
        let y = Metrics.strip / 2
        // The last of five, each about 150 wide after the lights.
        let grab: CGFloat = 800
        try await send(.leftMouseDown, at: NSPoint(x: grab, y: y), in: window)
        for x in stride(from: grab + 3, through: grab + 90, by: 3) {
            try await send(.leftMouseDragged, at: NSPoint(x: x, y: y), in: window)
        }
        XCTAssertFalse(TabLift.shared.carrying, "still on the row")
        try shoot(window.contentView, shots, "past-the-end")
        try await send(.leftMouseDragged, at: NSPoint(x: grab + 90, y: -40), in: window)
        XCTAssertTrue(TabLift.shared.carrying, "off the row")
        XCTAssertTrue(floating, "on screen")
        let before = try XCTUnwrap(TabLift.shared.content?.window).frame.origin
        TabDrag.testPointer = NSPoint(x: inside.x + 30, y: inside.y - 20)
        try await send(.leftMouseDragged, at: NSPoint(x: grab + 92, y: -40), in: window)
        let after = try XCTUnwrap(TabLift.shared.content?.window).frame.origin
        XCTAssertEqual(after.x - before.x, 30, "with the pointer")
        XCTAssertEqual(after.y - before.y, -20, "with the pointer")
        TabDrag.testPointer = inside
        try await settle()
        try shoot(TabLift.shared.content, shots, "lifted")
        try await send(.leftMouseDragged, at: NSPoint(x: grab + 90, y: y), in: window)
        XCTAssertFalse(TabLift.shared.carrying, "back on the row")
        try await send(.leftMouseDragged, at: NSPoint(x: grab + 90, y: -40), in: window)
        try await send(.leftMouseUp, at: NSPoint(x: grab + 90, y: -40), in: window)
        try await settle()
        XCTAssertFalse(TabLift.shared.carrying, "put down with the button")
        XCTAssertFalse(floating, "off the screen")
    }

    /// The row carried off can go while the button is down, and its drag
    /// never ends. Told only through that row, the floating tab stayed over
    /// every window after the button came up. (Checked after the release: a
    /// row leaves by its transition, and a hidden window draws no frames.)
    func testTheFloatingTabGoesWhenItsTabCloses() async throws {
        let browser = makeBrowser()
        let window = try await liftOffTheTopRow(browser)
        let held = try XCTUnwrap(browser.tabs.first { $0.id == TabLift.shared.shown })
        browser.closeTab(held)
        try await settle()
        try await send(.leftMouseUp, at: NSPoint(x: 400, y: -40), in: window)
        try await settle()
        XCTAssertFalse(floating, "gone with its tab")
    }

    func testTheFloatingTabGoesWhenItsRowBecomesAPairsRightHalf() async throws {
        let browser = makeBrowser()
        let window = try await liftOffTheTopRow(browser)
        let held = try XCTUnwrap(browser.tabs.first { $0.id == TabLift.shared.shown })
        let other = try XCTUnwrap(browser.tabs.first { $0.id != held.id })
        browser.pair(held, with: other, onLeft: false)
        try await settle()
        try await send(.leftMouseUp, at: NSPoint(x: 400, y: -40), in: window)
        try await settle()
        XCTAssertFalse(floating, "gone with its row")
    }

    /// A pair is one row, and either half can be picked up: the floating tab
    /// names the half a drop would take.
    func testTheFloatingTabNamesThePairsHalfUnderTheHand() async throws {
        let browser = makeBrowser()
        let t = browser.tabs
        browser.pair(t[2], with: t[1], onLeft: false)
        browser.select(t[4])
        let window = makeWindow(browser)
        browser.window = window
        try await settle()
        // The pair 30–86: its second half from 58.
        let y: CGFloat = 72
        TabDrag.testPointer = NSPoint(x: window.frame.minX + 70, y: window.frame.minY + point(y: y, in: window).y)
        defer { TabDrag.testPointer = nil }
        try await send(.leftMouseDown, at: point(y: y, in: window), in: window)
        for x in stride(from: CGFloat(73), through: browser.prefs.columnWidth + 30, by: 3) {
            try await send(.leftMouseDragged, at: NSPoint(x: x, y: point(y: y, in: window).y), in: window)
        }
        XCTAssertEqual(TabLift.shared.shown, t[2].id)
        try await send(.leftMouseUp, at: NSPoint(x: browser.prefs.columnWidth + 30, y: point(y: y, in: window).y), in: window)
        try await settle()
    }

    /// Out of the window's side, still level with the row: letting go there
    /// takes the tab away, so it has to show.
    func testLeavingTheWindowLevelWithTheRowLifts() async throws {
        let browser = makeBrowser()
        let window = try makeTopRow(browser)
        browser.window = window
        try await settle()
        let inside = NSPoint(x: window.frame.midX, y: window.frame.midY)
        TabDrag.testPointer = inside
        defer { TabDrag.testPointer = nil }
        let y = Metrics.strip / 2
        try await send(.leftMouseDown, at: NSPoint(x: 800, y: y), in: window)
        try await send(.leftMouseDragged, at: NSPoint(x: 808, y: y), in: window)
        XCTAssertFalse(TabLift.shared.carrying, "still in the window")
        TabDrag.testPointer = NSPoint(x: window.frame.maxX + 100, y: inside.y)
        try await send(.leftMouseDragged, at: NSPoint(x: 816, y: y), in: window)
        XCTAssertTrue(TabLift.shared.carrying, "past its side")
        TabDrag.testPointer = inside
        try await send(.leftMouseUp, at: NSPoint(x: 816, y: y), in: window)
        try await settle()
    }

    /// A pin can't leave its window (Browser.dragOut), so nothing says it could.
    func testAPinCarriedOffTheRowDoesNotLift() async throws {
        let browser = makeBrowser()
        let pinned = browser.tabs[0]
        browser.pin(pinned)
        // A pin is every window's: left in, the next test's rows start lower.
        defer { browser.unpin(pinned) }
        let window = try makeTopRow(browser)
        try await settle()
        TabDrag.testPointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
        defer { TabDrag.testPointer = nil }
        let x = Metrics.lights + (browser.prefs.usesSpaces ? SpaceDot.width + Metrics.tabGap : 0) + Metrics.pinWidth / 2
        try await send(.leftMouseDown, at: NSPoint(x: x, y: Metrics.strip / 2), in: window)
        for y in stride(from: Metrics.strip / 2 - 6, through: -40, by: -6) {
            try await send(.leftMouseDragged, at: NSPoint(x: x, y: y), in: window)
        }
        XCTAssertEqual(CarryGuard.count, 1, "carried")
        XCTAssertFalse(TabLift.shared.carrying)
        try await send(.leftMouseUp, at: NSPoint(x: x, y: -40), in: window)
        try await settle()
    }

    /// The rows are set in from the column's edges, and measured from there:
    /// the same few points past either edge lift the tab.
    func testTheColumnLiftsAtItsOwnEdges() async throws {
        let browser = makeBrowser()
        browser.select(browser.tabs[0])
        let window = makeWindow(browser)
        try await ready(browser)
        TabDrag.testPointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
        defer { TabDrag.testPointer = nil }
        let width = browser.prefs.columnWidth
        let y = point(y: 14, in: window).y
        try await send(.leftMouseDown, at: NSPoint(x: 70, y: y), in: window)
        try await send(.leftMouseDragged, at: NSPoint(x: 60, y: y), in: window)
        try await send(.leftMouseDragged, at: NSPoint(x: -1, y: y), in: window)
        XCTAssertFalse(TabLift.shared.carrying, "just past the left edge")
        try await send(.leftMouseDragged, at: NSPoint(x: -10, y: y), in: window)
        XCTAssertTrue(TabLift.shared.carrying, "well past the left edge")
        try await send(.leftMouseDragged, at: NSPoint(x: width + 1, y: y), in: window)
        XCTAssertFalse(TabLift.shared.carrying, "just past the right edge")
        try await send(.leftMouseDragged, at: NSPoint(x: width + 10, y: y), in: window)
        XCTAssertTrue(TabLift.shared.carrying, "well past the right edge")
        try await send(.leftMouseUp, at: NSPoint(x: width + 10, y: y), in: window)
        try await settle()
    }

    private var floating: Bool { TabLift.shared.content?.window?.isVisible == true }

    private func makeTopRow(_ browser: Browser) throws -> NSWindow {
        browser.prefs.sidebar = false
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: Metrics.strip),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabBar(browser: browser))
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    /// A tab of the row across the top, carried down off it and still held.
    private func liftOffTheTopRow(_ browser: Browser) async throws -> NSWindow {
        let window = try makeTopRow(browser)
        try await settle()
        TabDrag.testPointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
        addTeardownBlock { @MainActor in TabDrag.testPointer = nil }
        try await send(.leftMouseDown, at: NSPoint(x: 400, y: Metrics.strip / 2), in: window)
        for y in stride(from: Metrics.strip / 2 - 6, through: -40, by: -6) {
            try await send(.leftMouseDragged, at: NSPoint(x: 400, y: y), in: window)
        }
        XCTAssertTrue(floating, "lifted")
        return window
    }

    /// With Tabs Give on, a tab across the top has a press of its own under
    /// the drag. Holding on however far the hand went, it kept the mouse and
    /// the drag never began.
    func testATabCarriedAlongTheTopWhenTabsGive() async throws {
        let browser = makeBrowser()
        let wasGiving = browser.prefs.tabsGive
        defer { browser.prefs.tabsGive = wasGiving }
        browser.prefs.tabsGive = true
        browser.prefs.sidebar = false
        let order = browser.tabs.map(\.id)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: Metrics.strip),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabBar(browser: browser))
        window.orderFrontRegardless()
        windows.append(window)
        try await settle()
        TabDrag.testPointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
        defer { TabDrag.testPointer = nil }
        let y = Metrics.strip / 2
        let grab: CGFloat = 350
        try await send(.leftMouseDown, at: NSPoint(x: grab, y: y), in: window)
        for x in stride(from: grab + 3, through: grab + 240, by: 3) {
            try await send(.leftMouseDragged, at: NSPoint(x: x, y: y), in: window)
        }
        XCTAssertEqual(CarryGuard.count, 1, "carried")
        try await send(.leftMouseUp, at: NSPoint(x: grab + 240, y: y), in: window)
        try await settle()
        XCTAssertNotEqual(browser.tabs.map(\.id), order, "moved")
    }

    private func shoot(_ view: NSView?, _ folder: String?, _ name: String) throws {
        guard let view, let folder, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
    }

    // MARK: - helpers

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.roomyTabs, prefs.newTabPlace)
        restorePreferences = {
            (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.roomyTabs, prefs.newTabPlace) = previous
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.sidebar = true
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = true
        browser.prefs.roomyTabs = false
        // Each new tab after the last, so they stand in the order made.
        browser.prefs.newTabPlace = .next
        for word in ["one", "two", "three", "four", "five"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs))
        window.orderFrontRegardless()
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }

    /// A point down the rows, from their top, in the window's terms.
    private func point(y: CGFloat, in window: NSWindow) -> NSPoint {
        NSPoint(x: 70, y: window.frame.height - Metrics.strip - runTop - y)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    /// Settled, and no page loading: the tab in front starts loading its
    /// page once its window is up, and its row changing under the hand as
    /// the load starts or ends (the ring) calls SwiftUI's drag off (see
    /// CarryGuard). How soon that comes depends on how warm WebKit is, so
    /// a carry started too early was put down mid-way in some runs: the
    /// folded group's spring failed only after another suite had warmed it.
    private func ready(_ browser: Browser) async throws {
        try await settle()
        let deadline = Date().addingTimeInterval(5)
        while browser.tabs.contains(where: \.loading), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await settle()
    }

    /// Through the app, as a real event comes (as IconColumnTests sends
    /// them): taken off its queue, so NSApp.currentEvent is this event while
    /// it is delivered. Sent straight to the window, the current event was
    /// whatever last came through the app: after PinStuckTests in one run,
    /// a release of a window gone, and the folded group's spring carry was
    /// put down mid-way, or its group never sprang open.
    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        NSApp.postEvent(event, atStart: true)
        let queued = try XCTUnwrap(NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true))
        NSApp.sendEvent(queued)
        try await Task.sleep(for: .milliseconds(30))
    }
}
