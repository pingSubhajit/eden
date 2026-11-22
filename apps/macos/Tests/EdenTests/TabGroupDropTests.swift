import AppKit
import XCTest
@testable import Eden

@MainActor
final class TabGroupDropTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "tab-group-drop-\(getpid())", 1)
        super.setUp()
    }

    /// From a space as a new install has it, whatever the suites before
    /// left in this process's world (CleanWorld).
    override func setUp() async throws {
        try await super.setUp()
        CleanWorld.reset()
    }

    func testPositionalMovesAndSourceCleanup() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let grouped = browser.prefs.usesTabGroups
        let split = browser.prefs.splitView
        let place = browser.prefs.newTabPlace
        defer {
            browser.prefs.usesTabGroups = grouped
            browser.prefs.splitView = split
            browser.prefs.newTabPlace = place
        }
        browser.prefs.usesTabGroups = true
        // Each new tab after the last, so `tabs.last` is the one just made.
        browser.prefs.newTabPlace = .next
        // Whatever an earlier test left in this world's session, gone: the
        // row held their tabs too, and its order wasn't this test's.
        let left = browser.tabs
        browser.newTab()
        for tab in left { browser.close(tab) }
        for number in 0..<6 {
            if number > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(number).example/")!, title: "\(number)")
        }
        let tabs = browser.tabs
        let group = browser.addTabGroup(containing: tabs[0])
        for tab in tabs[1...2] { browser.move(tab, toGroup: group) }
        browser.move(tabs[3], toGroup: GroupDropTarget(group: group, member: tabs[0].id))
        browser.move(tabs[4], toGroup: GroupDropTarget(group: group, member: tabs[1].id))
        let source = browser.addTabGroup(containing: tabs[5])
        let active = browser.activeID
        browser.move(tabs[5], toGroup: GroupDropTarget(group: group, member: tabs[2].id, after: true))
        XCTAssertEqual(browser.tabs(in: group).map(\.id), [3, 0, 4, 1, 2, 5].map { tabs[$0].id })
        XCTAssertFalse(browser.tabGroups.contains { $0.id == source })
        XCTAssertEqual(browser.activeID, active)

        browser.move(tabs[3], toGroup: GroupDropTarget(group: group, member: tabs[5].id, after: true))
        browser.move(tabs[3], toGroup: GroupDropTarget(group: group, member: tabs[0].id))
        browser.move(tabs[4], toGroup: GroupDropTarget(group: group, member: tabs[1].id, after: true))
        let order = [3, 0, 1, 4, 2, 5].map { tabs[$0].id }
        XCTAssertEqual(browser.tabs.map(\.id), order)
        browser.move(tabs[4], toGroup: GroupDropTarget(group: group, member: tabs[4].id))
        browser.move(tabs[4], toGroup: GroupDropTarget(group: UUID()))
        browser.move(tabs[4], toGroup: GroupDropTarget(group: group, member: UUID()))
        XCTAssertEqual(browser.tabs.map(\.id), order)
        let foreign = Tab(configuration: Web.configuration())
        browser.move(foreign, toGroup: GroupDropTarget(group: group))
        tabs[4].pin = "pin"
        browser.move(tabs[4], toGroup: GroupDropTarget(group: group))
        tabs[4].pin = nil
        XCTAssertEqual(browser.tabs.map(\.id), order)
        browser.toggleTabGroup(group)
        browser.move(tabs[3], toGroup: GroupDropTarget(group: group))
        XCTAssertFalse(browser.tabGroups[0].collapsed)
        XCTAssertEqual(browser.tabs.last?.id, tabs[3].id)

        browser.prefs.splitView = true
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.move(tabs[0], toGroup: GroupDropTarget(group: group))
        XCTAssertEqual(Array(browser.tabs.suffix(2)).map(\.id), [tabs[0].id, tabs[1].id])
        browser.move(tabs[1], toGroup: GroupDropTarget(group: group, member: tabs[4].id), detaching: true)
        XCTAssertEqual(browser.tabs.first?.id, tabs[1].id)
        XCTAssertEqual(browser.tabs.last?.id, tabs[0].id)
        XCTAssertNil(browser.split(for: tabs[1]))
        // Read back from wherever this window keeps its rows: the session
        // files when it is the first window of its profile this run, as it
        // is when this test runs alone, else its own record. Read from the
        // record alone, the test failed whenever it ran first.
        browser.writeSession(now: true)
        let saved = browser.readRow(browser.spaceID)
        XCTAssertEqual(saved.tabs.count, tabs.count)
        var record = browser.record
        record.rows[browser.spaceID.uuidString] = saved
        let restored = Browser(record: record)
        defer { restored.closeAll() }
        XCTAssertEqual(restored.tabs.map { $0.address?.absoluteString }, saved.tabs.map { Optional($0.url) })
        XCTAssertEqual(restored.tabs.map(\.groupID), saved.tabs.map(\.groupID))
    }

    func testVisibleGeometry() {
        let group = TabGroup(id: UUID(), name: "Group", collapsed: false)
        let first = UUID(), last = UUID(), source = UUID()
        // Unequal lengths and a negative origin also exercise scrolled coordinates.
        let rect: (CGFloat, CGFloat) -> CGRect = { start, length in
            CGRect(x: 10, y: start, width: 80, height: length)
        }
        let point: (CGFloat) -> CGPoint = { CGPoint(x: 30, y: $0) }
        let frames = [
            group.id: GroupDropFrame(group: group.id, rect: rect(-40, 20)),
            first: GroupDropFrame(group: group.id, tab: first, rect: rect(-10, 30)),
            last: GroupDropFrame(group: group.id, tab: last, rect: rect(30, 80)),
            source: GroupDropFrame(group: group.id, tab: source, rect: rect(120, 30))
        ]
        for (position, target) in [
            (-30.0, GroupDropTarget(group: group.id)),
            (-5.0, GroupDropTarget(group: group.id, member: first)),
            (25.0, GroupDropTarget(group: group.id, member: last)),
            (100.0, GroupDropTarget(group: group.id, member: last, after: true))
        ] {
            XCTAssertEqual(GroupDropFrames.resolve(point(position), frames: frames, groups: [group],
                                                   excluding: source), target)
        }
        XCTAssertNil(GroupDropFrames.resolve(point(140), frames: frames, groups: [group], excluding: source))
        var collapsed = group
        collapsed.collapsed = true
        XCTAssertEqual(GroupDropFrames.resolve(point(40), frames: frames, groups: [collapsed], excluding: source),
                       GroupDropTarget(group: group.id))
    }

    /// A gap open in a group is part of it, and the group holding the tab
    /// keeps it a little past its edge.
    func testAGapIsPartOfItsGroupAndTheGroupHoldingATabKeepsIt() {
        let first = TabGroup(id: UUID(), name: "First", collapsed: false)
        let second = TabGroup(id: UUID(), name: "Second", collapsed: false)
        let a = UUID(), b = UUID(), source = UUID()
        let rect: (CGFloat, CGFloat) -> CGRect = { CGRect(x: 10, y: $0, width: 80, height: $1) }
        var frames = [
            first.id: GroupDropFrame(group: first.id, rect: rect(0, 22)),
            a: GroupDropFrame(group: first.id, tab: a, rect: rect(24, 28)),
            second.id: GroupDropFrame(group: second.id, rect: rect(56, 22)),
            b: GroupDropFrame(group: second.id, tab: b, rect: rect(80, 28))
        ]
        let at: (CGFloat) -> CGPoint = { CGPoint(x: 30, y: $0) }
        let groups = [first, second]
        // Below "b": nothing, until a gap opens there.
        XCTAssertNil(GroupDropFrames.resolve(at(120), frames: frames, groups: groups, excluding: source))
        frames[ColumnCarry.frameKey] = GroupDropFrame(group: second.id, rect: rect(110, 28))
        XCTAssertEqual(GroupDropFrames.resolve(at(120), frames: frames, groups: groups, excluding: source),
                       GroupDropTarget(group: second.id, member: b, after: true))
        // The top of a heading is the place before its group, not in it.
        XCTAssertNil(GroupDropFrames.resolve(at(58), frames: frames, groups: groups, excluding: source))
        XCTAssertEqual(GroupDropFrames.resolve(at(66), frames: frames, groups: groups, excluding: source),
                       GroupDropTarget(group: second.id))
        // Just past the first group's foot: the first keeps a tab it holds,
        // until the hand is clear of it.
        XCTAssertEqual(GroupDropFrames.resolve(at(58), frames: frames, groups: groups, excluding: source,
                                               holding: first.id),
                       GroupDropTarget(group: first.id, member: a, after: true))
        XCTAssertEqual(GroupDropFrames.resolve(at(70), frames: frames, groups: groups, excluding: source,
                                               holding: first.id),
                       GroupDropTarget(group: second.id))
    }

    // MARK: - groups among the tabs

    private func grouped() -> (Browser, [Eden.Tab], UUID, UUID) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.prefs.usesTabGroups = true
        browser.prefs.splitView = false
        browser.prefs.newTabPlace = .next
        // Whatever an earlier test left in this world's session, gone.
        let left = browser.tabs
        browser.newTab()
        for tab in left { browser.close(tab) }
        for number in 0..<6 {
            if number > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(number).example/")!, title: "\(number)")
        }
        let tabs = browser.tabs
        // 0 alone, then a group of 1 and 2, then 3, then a group of 4, then 5.
        let first = browser.addTabGroup(containing: tabs[1])
        browser.move(tabs[2], toGroup: first)
        let second = browser.addTabGroup(containing: tabs[4])
        return (browser, tabs, first, second)
    }

    private func order(_ browser: Browser) -> [String] {
        browser.sideItems.map { item in
            switch item {
            case .tab(let tab): return tab.title
            case .group(_, let members): return "[" + members.map(\.title).joined(separator: " ") + "]"
            }
        }
    }

    func testAGroupStandsWhereItWasMadeAmongTheTabs() {
        let (browser, _, first, second) = grouped()
        let usesGroups = browser.prefs.usesTabGroups
        defer { browser.prefs.usesTabGroups = usesGroups }
        XCTAssertEqual(order(browser), ["0", "[1 2]", "3", "[4]", "5"])
        XCTAssertEqual(browser.tabGroups.map(\.id), [first, second], "the groups' own list in the order they stand")
    }

    func testAGroupAndATabAreCarriedAlongTheRunAlike() {
        let (browser, tabs, first, second) = grouped()
        browser.moveItem(.group(first), to: 3)
        XCTAssertEqual(order(browser), ["0", "3", "[4]", "[1 2]", "5"])
        XCTAssertEqual(browser.tabGroups.map(\.id), [second, first])
        browser.moveItem(.tab(tabs[5].id), to: 0)
        XCTAssertEqual(order(browser), ["5", "0", "3", "[4]", "[1 2]"])
    }

    func testATabJoinsAGroupAtItsEndAndTheGroupStaysWhereItStands() {
        let (browser, tabs, first, _) = grouped()
        browser.move(tabs[5], toGroup: first)
        XCTAssertEqual(order(browser), ["0", "[1 2 5]", "3", "[4]"])
        browser.move(tabs[0], toGroup: first)
        XCTAssertEqual(order(browser), ["[1 2 5 0]", "3", "[4]"], "not the whole group up to where the tab was")
        // Taken out of the middle, it stands after the group.
        browser.move(tabs[2], toGroup: nil)
        XCTAssertEqual(order(browser), ["[1 5 0]", "2", "3", "[4]"])
    }

    func testATabCarriedOutOfItsGroupLandsBeforeATabOrAGroup() {
        let (browser, tabs, first, second) = grouped()
        browser.move(tabs[1], outOfGroupBefore: .group(second))
        XCTAssertEqual(order(browser), ["0", "[2]", "3", "1", "[4]", "5"])
        browser.move(tabs[2], outOfGroupBefore: .tab(tabs[0].id))
        XCTAssertEqual(order(browser), ["2", "0", "3", "1", "[4]", "5"])
        XCTAssertFalse(browser.tabGroups.contains { $0.id == first }, "a group left empty goes")
    }

    func testTabsPickedTogetherAreCarriedAlongTheRunTogether() {
        let (browser, tabs, first, _) = grouped()
        // "0" and "2" (out of its group) picked, "0" carried past "3".
        browser.select(tabs[0])
        browser.extendTabSelection(to: tabs[2], modifiers: .command)
        browser.moveItem(.tab(tabs[0].id), to: 2)
        XCTAssertEqual(order(browser), ["[1]", "3", "0", "2", "[4]", "5"], "as one block, in their order")
        XCTAssertNil(browser.group(of: tabs[2]), "out of its group, as the tab carried is in none")
        XCTAssertTrue(browser.tabGroups.contains { $0.id == first })
        browser.clearTabSelection()
    }

    /// The group passed has one of its own tabs picked: the rest of it
    /// stays, and the block lands beside it, either way, at the end too.
    func testPickedTabsPassAGroupOneOfThemCameFrom() {
        let (browser, tabs, _, second) = grouped()
        browser.select(tabs[0])
        browser.extendTabSelection(to: tabs[2], modifiers: .command)
        browser.moveItem(.tab(tabs[0].id), to: 1)
        XCTAssertEqual(order(browser), ["[1]", "0", "2", "3", "[4]", "5"], "down past it")
        browser.moveItem(.tab(tabs[0].id), to: 0)
        XCTAssertEqual(order(browser), ["0", "2", "[1]", "3", "[4]", "5"], "and back up past it")
        browser.clearTabSelection()

        // At the end of the run: "5" and "4", out of the last group, below it.
        browser.moveItem(.tab(tabs[5].id), to: 3)
        XCTAssertEqual(order(browser), ["0", "2", "[1]", "5", "3", "[4]"])
        browser.select(tabs[5])
        browser.extendTabSelection(to: tabs[4], modifiers: .command)
        browser.moveItem(.tab(tabs[5].id), to: 5)
        XCTAssertEqual(order(browser), ["0", "2", "[1]", "3", "5", "4"],
                       "past the last group, which goes empty; in the order they stood")
        XCTAssertFalse(browser.tabGroups.contains { $0.id == second })
        browser.clearTabSelection()
    }
}
