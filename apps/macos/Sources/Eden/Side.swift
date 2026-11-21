import EdenCore
import SwiftUI

/// The column's and the side panel's widths while an edge of theirs is held,
/// for the page beside them: it follows the pointer from here, and the
/// settings are written once, when the edge is let go. Each window has its
/// own, so only the window being pulled moves until then.
final class HeldEdges: ObservableObject {
    @Published var side: CGFloat?
    @Published var panel: CGFloat?
}

/// The tabs, down either side instead of across the top.
///
/// The same pieces as the strip — the grey on the tab you picked, there at
/// once, the pinned squares, the cross that appears under the pointer — laid out the
/// other way. The traffic lights keep their corner; the column starts under
/// them and the page takes the whole height beside it.
struct SideBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// On the window's ground, beside the page's card (see CardEdge): the
    /// ground's colour and no edge of its own, the card's edge being the line.
    var onFrame = false
    /// The greys for that ground, handed down to every row, pin and door.
    private var greys: Greys { onFrame ? .frame : .white }


    @State private var landing = false
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    /// The width while the edge is held. The setting is written once, when
    /// it is let go: written on every step, each one was a write to the
    /// settings and a change heard by every window and all that is in it.
    @State private var live: CGFloat?
    /// The width while the edge is held, nil once it is let go, for the page
    /// beside the column to follow (see HeldEdges).
    var onDrag: (CGFloat?) -> Void = { _ in }
    @State private var onEdge = false

    /// A tab carried over the squares, and the place opened among them for
    /// it (see PinDrop).
    @State private var crossing: PinDrop.Crossing?
    /// Where the grid and the rows are, for taking a point from one to the
    /// other.
    @State private var frames = ColumnFrames()
    /// Whether this space's rows fit under the pins without scrolling: set
    /// only when the answer changes, from the room under the pins and what
    /// the rows add up to, which are kept where changing them draws nothing.
    @State private var fits = true
    @State private var room = Room()
    /// Which of your other devices' groups are open (DeviceGroups): folded
    /// until opened, and as left while the window is open.
    @State private var elsewhereOpened: Set<String> = []
    /// The group a tab is being carried out of, or the group being carried,
    /// drawn over the others so it passes above them.
    @State private var carryingGroup: UUID?
    /// A row or a group is in hand: the New Tab row, which takes nothing
    /// carried, neither lights nor answers under it (newTab).
    @State private var lifting = false
    /// Where a tab, a pair or a group carried out of its own run would land
    /// if let go now (ColumnCarry): the rows there part for it, above the
    /// line or under it, and letting go puts it there.
    @State private var carry: ColumnCarry?
    /// A folded group a carried tab has rested on, and which it opened to
    /// be placed in: folded again if the tab goes elsewhere.
    @State private var sprung: UUID?
    /// The folded group a carried tab is resting on, before it opens.
    @State private var springing: (group: UUID, work: DispatchWorkItem)?
    @State private var gapFrame = RowGapFrame()
    /// A tab or a group just let go into a gap, settling from the hand into
    /// its place.
    @State private var settling: RowLanding?
    /// Whether another device has tabs open: the foot has a door for them
    /// with icons only (SideFoot.doors). Only that, not sync's every change.
    @ObservedObject private var elsewherePresence = Sync.shared.presence
    private final class Room {
        var height: CGFloat = .infinity
        var needed: CGFloat = 0
        /// The rows' own height, as last laid out.
        var drawn: CGFloat = 0
    }

    /// A tab's line: taller with roomier tabs turned on.
    private var rowHeight: CGFloat { prefs.sideRow }
    /// The column's width: the setting, or where the edge is while it is held.
    private var width: CGFloat { live ?? prefs.columnWidth }
    static let gap: CGFloat = 2
    private static let pinGap: CGFloat = 4

    private var onRight: Bool { prefs.sidePosition == .right }
    /// Icons only (SideIcons.swift): tiles for rows, a fixed width, the
    /// lights and the three doors stacked at the top.
    private var icons: Bool { prefs.iconColumn }
    /// With icons only, the band the stacked lights take: gone in full
    /// screen, with them.
    private var lightsBand: CGFloat { browser.fullScreen ? 8 : Metrics.iconLights }
    /// What sits above the pins: the lights' band, and with icons only the
    /// three doors under it.
    private var top: CGFloat { icons ? lightsBand + Metrics.helmDoors + 8 : Metrics.strip }
    private var innerEdge: Alignment { onRight ? .leading : .trailing }

    /// The window's buttons' corner: gone in full screen, where macOS takes
    /// them away, and back, forward and reload move up to the edge (idea 184).
    private var lights: CGFloat {
        browser.fullScreen ? 0 : max(0, min(Metrics.sideLights, width - 20 - Metrics.helmDoors))
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Not under the card for a new space: it isn't made of views that
            // would take the click first.
            DragStrip(reserved: 0, below: browser.makingSpace ? .greatestFiniteMagnitude : rowsEnd, onDoubleClick: browser.newTab)

            // The band the lights sit in is this mode's title bar: the window
            // is dragged by it and a double-click fills the screen with it,
            // everywhere but over the three doors, which take their own
            // clicks. The lights are the title bar's own and answer first.
            if icons {
                DragStrip()
                    .frame(height: lightsBand)
            } else {
                HStack(spacing: 0) {
                    DragStrip()
                        .frame(width: 10 + lights)
                    Color.clear
                        .frame(width: Metrics.helm)
                        .allowsHitTesting(false)
                    DragStrip()
                }
                .frame(height: Metrics.strip)
            }

            VStack(alignment: .leading, spacing: 0) {
                // The traffic lights' corner, with back, forward and reload
                // sitting right of them — the same three doors as the top
                // bar, moved beside the lights since there's no far end of a
                // row to put them at in this mode.
                if icons {
                    // The lights stacked in their band (Lights, vertical),
                    // the three doors one above the other under them.
                    Color.clear.frame(height: lightsBand)
                    Helm(browser: browser, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)
                } else {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: lights)
                        Helm(browser: browser)
                        Spacer(minLength: 0)
                    }
                    .frame(height: Metrics.strip)
                }

                // The spaces side by side, as pages: two fingers sideways move
                // the one on screen and the next one together, the next one
                // coming in as this one goes, with nothing between them.
                pages

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            // Clear of the foot, which sits over the sidebar's bottom edge,
            // and of what plays in another tab, over the foot.
            .padding(.bottom, footHeight + (browser.player == nil ? 0 : rowHeight + SideBar.playerGap))

            VStack(spacing: 0) {
                Spacer()
                if let tab = browser.player {
                    PlayerRow(browser: browser, prefs: prefs, tab: tab)
                        .padding(.horizontal, 10)
                        .padding(.bottom, SideBar.playerGap)
                        .transition(.opacity)
                }
                foot
            }
        }
        .environment(\.greys, greys)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // ⌘S to icons only while the edge is held takes the edge away, and
        // its gesture ends without onEnded: let go of the held width too.
        .onChange(of: icons) { _, now in
            guard now, live != nil else { return }
            live = nil
            grabbed = nil
            onDrag(nil)
        }
        // Gone while the edge is held (hidden, or the pane changed), the
        // gesture never ends: let go of the held width, or the page stays
        // laid out at it until the next pull.
        .onDisappear {
            guard live != nil else { return }
            live = nil
            grabbed = nil
            onDrag(nil)
        }
        // Rows on their way to or from another space stay in the column.
        .clipped()
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        .background {
            ZStack {
                landing ? greys.hover : onFrame ? Palette.frame : Palette.ground
                if prefs.splitView {
                    SplitDropZone(browser: browser, tab: nil, kind: .strip)
                }
            }
        }
        .overlay(alignment: innerEdge) {
            if !onFrame { Rectangle().fill(Palette.hairline).frame(width: 1) }
        }
        // A fixed width with icons only: nothing to pull.
        .overlay(alignment: innerEdge) { if !icons { edge } }
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .animation(Motion.quick, value: landing)
        .animation(Motion.quick, value: browser.player?.id)
        .animation(Motion.glide, value: browser.activeID)
        .animation(Motion.glide, value: browser.editingTab)
        .animation(Motion.settle, value: browser.tabs.map(\.id))
        // Your other devices' pages come and go the same way: the whole
        // column settles round them, not only their group.
        .animation(Motion.settle, value: elsewherePresence.counts)
        .animation(Motion.settle, value: browser.pinnedCount)
        // The last square made the first row changes nothing in the row's
        // order; only how many of each there are.
        .animation(Motion.settle, value: browser.listedPins.count)
    }

    /// The column's edge: pull it to make the column wider or narrower,
    /// double-click it to put it back. The whole edge takes the pointer; on
    /// it, a small pill shows in the middle (see Grip) so the edge says it
    /// can be taken before it is. Edge to edge, the pill sits on the page's
    /// hairline; as cards, in the gap before the page.
    private var edge: some View {
        EdgeGrip(lit: onEdge || grabbed != nil)
            .offset(x: onFrame ? 0 : onRight ? -4 : 4)
            .frame(width: 9)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { over in
                onEdge = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { grabbed = prefs.columnWidth }
                        let delta = onRight ? -value.translation.width : value.translation.width
                        let wanted = (grabbed ?? prefs.columnWidth) + delta
                        live = min(Metrics.sideMax, max(Metrics.sideMin, wanted))
                        onDrag(live)
                    }
                    .onEnded { _ in
                        if let live { prefs.sideWidth = live }
                        live = nil
                        grabbed = nil
                        onDrag(nil)
                    }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { prefs.sideWidth = Metrics.side }
            })
            .animation(Motion.quick, value: onEdge)
    }

    // MARK: - the spaces, as pages

    /// Where the space on screen sits among them: one past the last while
    /// the card for a new one is up.
    private var spaceAt: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    private var pages: some View {
        let width = self.width
        let swipe = browser.spaceSwipeSide
        let offset = browser.spaceSwipeOffset
        let at = spaceAt
        return ZStack(alignment: .topLeading) {
            page(at)
                .modifier(SwipeShift(offset: offset, across: true))
            // Only while the fingers are bringing one in: the one they are
            // bringing, a page's width away.
            if swipe > 0, at > 0 {
                page(at - 1)
                    .modifier(SwipeShift(offset: offset, by: -width, across: true))
            }
            if swipe < 0, browser.drawsPage(after: at) {
                page(at + 1)
                    .modifier(SwipeShift(offset: offset, by: width, across: true))
            }
        }
        // The pages are the column's whole width, each with its own margin.
        .padding(.horizontal, -10)
        // The room there is, and never more: another space's rows, drawn
        // whole while they pass, run on past the foot rather than making the
        // column taller than the window. With no minimum, a long space coming
        // in made it so, and the column, centred, lost its top and its foot
        // until the swipe was done (#1024).
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    /// One space's page: the rows on screen, another space's rows as they
    /// were left, or past the last the card for a new one.
    @ViewBuilder
    private func page(_ index: Int) -> some View {
        Group {
            if index == browser.spaces.count {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    NewSpaceCard(browser: browser)
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            } else if browser.spaces[index].id == browser.spaceID {
                VStack(alignment: .leading, spacing: 0) {
                    if !browser.squarePins.isEmpty || ghostSquare != nil {
                        pinned
                            .padding(.bottom, 10)
                            // A square carried down over the rows passes
                            // over them, not under.
                            .zIndex(carriedPin ? 1 : 0)
                    }
                    // A row too long for the window scrolls between the pins
                    // and the foot, rather than running under the lights at one
                    // end and the foot at the other. While it fits it stays a
                    // plain stack, and the space under it is still the
                    // window's to be dragged by. Inside the page: the swipe
                    // between spaces moves the page, scroll and all.
                    //
                    // One or the other, from the room measured beside what
                    // the rows add up to, rather than both kept for
                    // ViewThatFits to choose between: the one it didn't show
                    // was built again on every change of layout in the one it
                    // did, every row of it each time the pointer crossed a
                    // row (Bench "hoversweep": 22 rows a crossing, not 2).
                    let needed = rowsHeight
                    ScrollViewReader { proxy in
                        // Without scroll indicators: the tab column stays quiet
                        // and distraction-free, matching other vertical-tab browsers.
                        // The wheel and the trackpad still scroll smoothly.
                        ScrollView(.vertical, showsIndicators: false) {
                            rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                room.drawn = $0
                                refit()
                            }
                        }
                        // While the rows fit: still, and only as tall as they
                        // are, the room under them the window's to be dragged
                        // by. The same scroll view either way, so rows that
                        // grow past the room (a group opened) are moved, not
                        // built again, and keep their animation and place.
                        .scrollDisabled(fits)
                        .fixedSize(horizontal: false, vertical: fits)
                        // The tab you go to is the tab you see — ⌘1–⌘9,
                        // ⇧⌘], a link opening beside the one on screen.
                        // A turn of the run loop later, once the rows are laid
                        // out: the tab that makes them run past the room is
                        // there to be scrolled to only after they do.
                        .onChange(of: browser.activeID) { _, id in
                            guard let id else { return }
                            let representative = browser.activeSplit?.left ?? id
                            DispatchQueue.main.async {
                                guard !fits else { return }
                                // Without the glide on a test run: a hidden
                                // probe's window draws no frames, and the
                                // scroll stopped where its first one left it.
                                withAnimation(Store.testing ? nil : Motion.glide) { proxy.scrollTo(representative) }
                            }
                        }
                        // A turn of the run loop later, as the row across
                        // the top does it (TabBar.reveal): the folded
                        // column comes out mid-animation, and asked at
                        // once, before the rows had their height, the
                        // scroll could be dropped and the tab you were on
                        // left out of sight.
                        .onAppear {
                            guard let id = browser.activeID else { return }
                            DispatchQueue.main.async {
                                proxy.scrollTo(browser.activeSplit?.left ?? id, anchor: .center)
                            }
                        }
                    }
                    // The whole room under the pins, and never more, to be
                    // measured: a minimum of nothing, so a plain stack taller
                    // than the room runs on past its foot rather than making
                    // the room as tall as itself. With no minimum, the room
                    // measured was whatever the rows asked for once they ran
                    // past the window, so a sum a few points short (two for
                    // every folded group) kept the plain stack for good; and
                    // the column, as tall as its rows, stood centred over the
                    // window where nothing holds it at the top — folded away
                    // and out over the page — its top out of reach, with
                    // nothing to scroll it back by (idea 443). A window
                    // changing size, or a tab opened or closed, builds
                    // nothing until the rows stop fitting or start: what the
                    // rows add up to decides at once, what they measure a
                    // frame later, the larger of the two winning.
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        room.height = $0
                        refit()
                    }
                    .onChange(of: needed, initial: true) { _, needed in
                        room.needed = needed
                        refit()
                    }
                }
                // The grid and the rows measured in one space, for a tab
                // carried from one to the other (see PinDrop).
                .coordinateSpace(name: "column")
                .animation(Motion.settle, value: crossing)
            } else {
                preview(browser.parked[browser.spaces[index].id] ?? Parked(tabs: [], active: nil),
                        space: browser.spaces[index].id)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, alignment: .topLeading)
    }

    private func refit() {
        let now = max(room.needed, room.drawn) <= room.height
        if Store.testing { SideBar.measured = ["room": room.height, "needed": room.needed, "drawn": room.drawn, "fits": now ? 1 : 0] }
        if fits != now { fits = now }
    }

    /// What the column last measured, for the bench (`columnscroll`). Test runs only.
    @MainActor static var measured: [String: CGFloat] = [:]
    /// The kept area's lines as last drawn with kept groups, for the bench
    /// (`pinfolder`): kind, depth, title, folded. Test runs only.
    @MainActor static var drawnPinLines: [[Any]] = []
    /// The carry under way, where the rows part for it, as last drawn: for
    /// the tests that pin down how a carry looks before it is let go
    /// (RowCarryTests). Test runs only.
    @MainActor static var shownGap: ColumnCarry?
    /// Where the line was laid out (ColumnLayout) and where it was drawn,
    /// in the rows' space, for the tests that hold the two together.
    /// Test runs only.
    @MainActor static var lineLaid: CGFloat?
    @MainActor static var lineDrawn: CGFloat?

    /// Another space's rows, laid out and drawn by the same code as this
    /// one's (ColumnLayout, `column`) so the two read as one column while
    /// they pass — and nothing to press until it is the one on screen.
    private func preview(_ row: Parked, space: UUID) -> some View {
        let pins = row.tabs.filter { $0.pin != nil && !($0.listed && prefs.showsPinRows) }
        let cells = pinCells(pins.count)
        return VStack(alignment: .leading, spacing: 0) {
            if !pins.isEmpty {
                VStack(spacing: 0) {
                    PinGrid(cells: cells) {
                        ForEach(Array(pins.enumerated()), id: \.element.id) { index, tab in
                            PinSquare(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active, width: cells[index].width, height: cells[index].height,
                                      interactive: false)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            column(parkedLayout(row, space: space),
                   drawn: Drawn(tabs: row.tabs, splits: row.splits, active: row.active, live: false), space: space)
        }
        .allowsHitTesting(false)
    }

    /// Another space's column under its squares, laid out as it was left:
    /// its rows in their kept groups, its tabs and its groups, each folded
    /// group showing only the tab in front, if it is one of its own.
    private func parkedLayout(_ row: Parked, space: UUID) -> ColumnLayout<Tab> {
        let rows = prefs.showsPinRows
        let listed = rows ? row.tabs.filter { $0.pin != nil && $0.listed } : []
        let groups = rows ? Pins.groups(space) : []
        let kept = Browser.keptItems(listed, groups: groups).map { item -> SideItem in
            guard case .group(let group, let members) = item, group.collapsed else { return item }
            return .group(group, members.filter { $0.id == row.active })
        }
        let open = row.drawnItems(groupsOn: prefs.usesTabGroups, splitView: prefs.splitView).map { item -> SideItem in
            switch item {
            case .tab(let tab): .tab(tab)
            case .group(let drawn): .group(drawn.group, drawn.tabs)
            }
        }
        let devices = devices(in: space)
        let squares = row.tabs.filter { $0.pin != nil && !($0.listed && rows) }.count
        let shape = ColumnLayout<Tab>.Shape(
            kept: kept,
            keptHead: Self.head(of: kept),
            open: open,
            devices: devices.map { device in
                (device.device, browser.pages(device.tabs, in: space).count, elsewhereOpened.contains(device.device))
            },
            line: showsLine(kept: squares + listed.count + groups.count + devices.count),
            newTabOnTop: newTabOnTop)
        let splits = row.splits
        return ColumnLayout(shape, metrics: metrics, width: width - 20, id: \.id, lines: { lines(of: $0, splits: splits) })
    }

    /// Where the rows stop and the window's own drag area starts. Added up
    /// from what was drawn rather than measured: a measurement would arrive a
    /// frame late, and for one frame the whole column would drag the window.
    private var rowsEnd: CGFloat {
        let pins = browser.squarePins.count
        let pinBlock = pins == 0 ? 0 : (pinCells(pins).map(\.maxY).max() ?? 0) + 10
        return top + pinBlock + rowsHeight
    }

    /// The column under the squares as laid out at rest, the New Tab row
    /// with it, and a few points to spare: what decides whether it scrolls.
    /// At rest, so a gap opened mid-carry never turns the scroll on or off
    /// under the hand.
    private var rowsHeight: CGFloat {
        layout(carrying: nil).height + 8
    }

    @ViewBuilder
    private func rowItem(
        _ tab: Tab,
        tabs: [Tab],
        splits: [TabSplit],
        activeID: Tab.ID?,
        interactive: Bool,
        close: @escaping () -> Void
    ) -> some View {
        let pair = prefs.splitView ? splits.first(where: { $0.left == tab.id }) : nil
        let pages = pair.map { pair in pair.tabs.compactMap { id in tabs.first { $0.id == id } } } ?? []
        if icons {
            if let pair, pages.count >= 2 {
                IconPair(browser: browser, prefs: prefs, pages: pages,
                         live: activeID.map { pair.contains($0) } ?? false,
                         focusedID: activeID, interactive: interactive)
            } else {
                IconTile(browser: browser, prefs: prefs, tab: tab, live: tab.id == activeID, close: close, interactive: interactive)
            }
        } else if let pair, pages.count >= 2 {
            SplitTabItem(browser: browser, prefs: prefs, pages: pages,
                         width: nil, height: rowHeight,
                         live: activeID.map { pair.contains($0) } ?? false,
                         focusedID: activeID,
                         interactive: interactive)
                .frame(maxWidth: .infinity)
        } else {
            SideRow(browser: browser, prefs: prefs, tab: tab,
                    live: tab.id == activeID, close: close,
                    interactive: interactive)
        }
    }

    /// How many lines a tab stands as: a pair two, or as many as it holds
    /// (see SplitTabItem), anything else one.
    private func lines(of tab: Tab, splits: [TabSplit]) -> Int {
        guard prefs.splitView, let pair = splits.first(where: { $0.left == tab.id }), pair.left != pair.right else { return 1 }
        return pair.tabs.count
    }

    // MARK: - the pinned squares

    private var pinnedTabs: [Tab] { browser.squarePins }
    private var looseTabs: [Tab] {
        browser.displayedTabs.filter { $0.pin == nil && (!prefs.usesTabGroups || browser.group(of: $0) == nil) }
    }

    /// The one line between what is kept and what comes and goes (#6), with
    /// the pinned rows on: under the pins, square or row, their folders and
    /// your other devices' groups, over the New Tab row when new tabs go to
    /// the top and over your tabs and groups, Clear on it for the tabs in no
    /// group under it. Whenever something is kept above it, whatever is
    /// under it, so it doesn't come and go as the last tab closes; and no
    /// line until the first pin or device (idea 444).
    private func showsLine(kept: Int) -> Bool {
        prefs.showsPinRows && kept > 0
    }

    /// What stands above the line in this space: its pins, square or row,
    /// the folders the rows are kept in, and your other devices' groups.
    /// Not your own groups: they are among your tabs, under it.
    private var keptCount: Int {
        browser.squarePins.count + browser.listedPins.count + devicesHere.count
            + (prefs.showsPinRows ? browser.keptGroups.count : 0)
    }

    private var devicesHere: [DeviceTabs] { devices(in: browser.spaceID) }

    /// Your other devices with tabs open in a space, a group each under its
    /// pins (DeviceGroups); none with icons only, whose foot has a door to
    /// them instead. The column is drawn again whenever how many tabs they
    /// have in each space changes (ElsewherePresence); the groups watch the
    /// rest, their titles, themselves.
    private func devices(in space: UUID) -> [DeviceTabs] {
        guard !icons, elsewherePresence.hasTabs else { return [] }
        return Sync.shared.devicesWithTabs.filter { !browser.pages($0.tabs, in: space).isEmpty }
    }

    /// How many squares go in each row: at most four — fewer only when the
    /// column is too narrow for four of the classic width — and as even as
    /// they go, the fuller rows first. Five are three and two, seven four
    /// and three, nine three, three and three, ten four, three and three.
    /// Up to three stay the one row of three places they always were, with
    /// a place or two empty rather than a lonely button the column's width.
    static func pinRows(_ count: Int, most: Int) -> [Int] {
        guard count > 0 else { return [] }
        let most = max(1, most)
        let rows = (count + most - 1) / most
        let base = count / rows
        let extra = count % rows
        return (0..<rows).map { $0 < extra ? base + 1 : base }
    }

    /// Where each square goes, in the order of the row. Each row splits the
    /// column's width between its own squares — the row fills edge to edge,
    /// not each cell on its own — and every row is as tall as the narrowest
    /// cell allows, never taller than the classic square: past that a cell
    /// turns into a wide, short button rather than a bigger icon.
    private func pinCells(_ count: Int) -> [CGRect] {
        let room = width - 20
        let gap = SideBar.pinGap
        let fits = Int((room + gap) / (prefs.pinSquare + gap))
        let rows = SideBar.pinRows(count, most: min(4, max(1, fits)))
        // A row of fewer than three keeps three places.
        let slots = rows.map { rows.count == 1 ? max($0, min(3, fits)) : $0 }
        let widths = slots.map { max(20, (room - CGFloat($0 - 1) * gap) / CGFloat($0)) }
        let height = min(prefs.pinSquare, widths.min() ?? prefs.pinSquare)
        var cells: [CGRect] = []
        for (row, n) in rows.enumerated() {
            for col in 0..<n {
                cells.append(CGRect(x: CGFloat(col) * (widths[row] + gap),
                                    y: CGFloat(row) * (height + gap),
                                    width: widths[row], height: height))
            }
        }
        return cells
    }

    /// The grid itself: fixed-size cells, left-aligned, so a half-empty last
    /// row holds its ground rather than stretching to fill it.
    private var pinned: some View {
        let tabs = pinnedTabs
        // A tab carried over the grid: one cell more, and the one it
        // would take left open for it.
        let ghost = ghostSquare
        let all = pinCells(tabs.count + (ghost == nil ? 0 : 1))
        let cells = ghost.map { open in all.indices.filter { $0 != open }.map { all[$0] } } ?? all
        let placed = cells + (ghost.map { [all[$0]] } ?? [])
        // Measured in the grid's own space, not the square's: a square that
        // has just been moved to a new cell would otherwise report the drag
        // from where it now is, the target would jump back, and the square
        // would shuttle between two cells for as long as the finger stayed.
        return VStack(spacing: 0) { PinGrid(cells: placed) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                PinSquare(
                    browser: browser,
                    prefs: prefs,
                    tab: tab,
                    live: tab.id == browser.liveID,
                    width: cells[index].width,
                    height: cells[index].height
                )
                // The hand's travel is the square's own, as a row's is
                // (Carried): a move redraws the one square being carried,
                // not the column (idea 31).
                .modifier(PinCarried(index: index, cells: cells,
                                     cross: { squareOverRows(tab, $0) },
                                     land: { squareLand(tab, $0) }) { browser.move(tab, to: $0) })
            }
            if let ghost, let tab = crossingTab {
                PinGhost(tab: tab, width: all[ghost].width, height: all[ghost].height)
            }
        } }
        .coordinateSpace(name: "pins")
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.grid = $0 }
    }

    // MARK: - the column under the squares

    /// What a row is drawn from: the space on screen's tabs, pressed and
    /// carried, or another space's passing in a swipe, drawn alike.
    private struct Drawn {
        let tabs: [Tab]
        let splits: [TabSplit]
        let active: Tab.ID?
        /// The space on screen's: pressed, carried and dropped on.
        let live: Bool
    }

    /// How tall the column's lines are drawn now.
    private var metrics: ColumnMetrics {
        ColumnMetrics(row: rowHeight, heading: icons ? GroupHeading.compactHeight : GroupLook.heading(row: rowHeight),
                      gap: SideBar.gap, inset: GroupLook.inset, line: KeepLine.height)
    }

    /// The space on screen's column under the squares, laid out
    /// (ColumnLayout): what is drawn, and where every drop reads. With
    /// `carry`, the gap open for what is carried and its own place closed.
    private func layout(carrying carry: ColumnCarry?) -> ColumnLayout<Tab> {
        let kept = prefs.showsPinRows ? browser.keptItems().map(shown) : []
        let open = runItems.map(shown)
        let shape = ColumnLayout<Tab>.Shape(
            kept: kept,
            keptHead: Self.head(of: kept),
            open: open,
            devices: devicesHere.map { device in
                (device.device, browser.pages(device.tabs, in: browser.spaceID).count, elsewhereOpened.contains(device.device))
            },
            line: showsLine(kept: keptCount),
            newTabOnTop: newTabOnTop)
        let splits = browser.splits
        return ColumnLayout(shape, metrics: metrics, width: width - 20, carry: carry, id: \.id,
                            lines: { lines(of: $0, splits: splits) })
    }

    /// An item with what it shows: a folded group only the tab in front, if
    /// it is one of its own, in either area.
    private func shown(_ item: SideItem) -> SideItem {
        guard case .group(let group, _) = item else { return item }
        return .group(group, browser.visibleTabs(in: group))
    }

    /// How many of the kept area's first items are rows every space shows.
    private static func head(of kept: [SideItem]) -> Int {
        kept.prefix { item in
            if case .tab(let tab) = item { return tab.everywhere }
            return false
        }.count
    }

    /// The column under the squares, which scrolls as one: laid out once
    /// and drawn from that, the gap a carry opened and all.
    private var rows: some View {
        let laid = layout(carrying: carry)
        if Store.testing {
            if browser.drawsKeptGroups { SideBar.drawnPinLines = laid.keptLines.map(\.described) }
            SideBar.lineLaid = laid.line?.minY
        }
        return column(laid, drawn: Drawn(tabs: browser.tabs, splits: browser.splits, active: browser.liveID, live: true),
                      space: browser.spaceID)
            // Every line measured in one space, the whole column's, for a
            // tab or a group carried from one to another.
            .coordinateSpace(name: "rows")
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("column")) }) { [frames] in frames.rows = $0 }
            .onChange(of: carry) { _, now in if Store.testing { SideBar.shownGap = now } }
    }

    /// The column under the squares as laid out: your other devices'
    /// groups; the kept area; the one line under all that is kept (#6) —
    /// Clear on it closes the tabs in no group under it, and keeps the
    /// groups among them, as it keeps the pins above — and the New Tab row
    /// where new tabs come in, at the top of your tabs and groups or under
    /// them all. Both areas drawn by the same code, a group above the line
    /// as one under it.
    private func column(_ laid: ColumnLayout<Tab>, drawn: Drawn, space: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Your other devices' tabs first, under the squares: groups of
            // the browser's own, above what you keep, as Dia's Pull Requests
            // has (Elsewhere.swift).
            if !laid.devices.isEmpty {
                VStack(spacing: SideBar.gap) {
                    DeviceGroups(browser: browser, prefs: prefs, space: space, opened: $elsewhereOpened,
                                 gap: drawn.live ? carry.flatMap { carry in carry.device.map { ($0, carry.height) } } : nil,
                                 gapFrame: gapFrame)
                }
                .padding(.bottom, SideBar.gap)
            }
            VStack(spacing: SideBar.gap) {
                pieces(laid.kept, in: laid, drawn: drawn)
            }
            .padding(.bottom, laid.kept.pieces.isEmpty ? 0 : SideBar.gap)
            VStack(spacing: SideBar.gap) {
                if laid.line != nil {
                    KeepLine(clears: drawn.live && !looseTabs.isEmpty) { if drawn.live { browser.clearTabs() } }
                        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("rows")).minY }) { top in
                            if Store.testing, drawn.live { SideBar.lineDrawn = top }
                        }
                }
                if newTabOnTop { newTab }
                if !laid.open.pieces.isEmpty {
                    VStack(spacing: SideBar.gap) {
                        pieces(laid.open, in: laid, drawn: drawn)
                    }
                }
            }
            if !newTabOnTop { newTab.padding(.top, SideBar.gap) }
        }
    }

    /// An area's tabs in no group and its groups, and the gap open among
    /// them, as laid out: in either area, a tab carried along them by hand
    /// as one is, a group by its heading.
    private func pieces(_ area: ColumnLayout<Tab>.Area, in laid: ColumnLayout<Tab>, drawn: Drawn) -> some View {
        let steps = laid.steps(in: area.area)
        let places = Self.places(area.pieces)
        return ForEach(area.pieces) { piece in
            switch piece {
            case .gap(let rect):
                RowGapSlot(height: rect.height, frame: gapFrame)
            case .row(let row):
                tabRow(row, run: ColumnRun(area: area.area), index: places[piece.id] ?? 0, steps: steps, drawn: drawn)
            case .group(let held):
                groupView(held, in: area.area, index: places[piece.id] ?? 0, steps: steps, laid: laid, drawn: drawn)
            }
        }
    }

    /// Where each piece stands among those carried along a run, the gap
    /// left out (Carried's index).
    private static func places(_ pieces: [ColumnLayout<Tab>.Piece]) -> [ColumnLayout<Tab>.Slot: Int] {
        var out: [ColumnLayout<Tab>.Slot: Int] = [:]
        var index = 0
        for piece in pieces {
            if case .gap = piece { continue }
            out[piece.id] = index
            index += 1
        }
        return out
    }

    /// A tab's row, at the top of an area or in a group, above the line or
    /// under it: carried along its own run, the others making way, or out
    /// of it, the run it is over parting for it (`carrying`). Only a tab
    /// under the line is a pair's or can leave the window (TabDrag, TabLift):
    /// a pin is one page, and stays.
    @ViewBuilder
    private func tabRow(_ row: ColumnLayout<Tab>.Row, run: ColumnRun, index: Int, steps: [CGFloat], drawn: Drawn) -> some View {
        let tab = row.member
        let item = rowItem(tab, tabs: drawn.tabs, splits: drawn.splits, activeID: drawn.active,
                           interactive: drawn.live, close: { browser.closeTab(tab) })
        if drawn.live {
            let open = run.area == .open
            item
                .modifier(RowGapSource(away: row.away, landing: settling?.tab == tab.id ? settling?.offset ?? 0 : 0))
                .modifier(Carried(index: index, steps: steps, vertical: true, space: "rows",
                                  groupDestination: open ? { source, point in openGroup(for: source, at: point) } : nil,
                                  outside: { browser.dragOut(tab) },
                                  browser: open ? browser : nil, tab: tab,
                                  cross: { overSquares(tab, $0) },
                                  land: { landOnSquares(tab, $0) }, faded: crossing?.tab == tab.id,
                                  holding: { held in
                                      carryingGroup = held ? run.group : nil
                                      lifting = held
                                      if !held { putDown() }
                                  },
                                  gap: { carrying(.tab(tab.id), row: tab, at: $0) },
                                  placed: { placed($0) }, keptInView: true) { shift(tab, along: run, to: $0) })
        } else {
            item
        }
    }

    /// A group, in either area: its heading and its tabs on its surface,
    /// carried by its heading along its area as a tab is, the others making
    /// way, and across the line, where the other area parts for it.
    @ViewBuilder
    private func groupView(_ held: ColumnLayout<Tab>.Group, in area: ColumnArea, index: Int, steps: [CGFloat],
                           laid: ColumnLayout<Tab>, drawn: Drawn) -> some View {
        let group = held.group
        let run = ColumnRun(area: area, group: group.id)
        let rowSteps = laid.steps(of: held)
        let places = Self.places(held.rows)
        let members = held.members
        // Lit while a tab carried over it would join it, which shows where
        // it would go even folded.
        let lit = drawn.live && carry?.place.map { ColumnRun(area: $0.area, group: $0.group) == run } == true
        let surface = SideGroup(colour: group.colour, folded: members.isEmpty, lit: lit, showsRows: held.showsRows,
                                indent: icons ? 0 : GroupLook.indent) {
            GroupHeading(browser: browser, group: group, compact: icons, carriedByHand: true, interactive: drawn.live)
        } rows: {
            VStack(spacing: SideBar.gap) {
                ForEach(held.rows) { piece in
                    switch piece {
                    case .gap(let rect):
                        RowGapSlot(height: rect.height, frame: gapFrame)
                    case .row(let row):
                        tabRow(row, run: run, index: places[piece.id] ?? 0, steps: rowSteps, drawn: drawn)
                    case .group:
                        EmptyView()
                    }
                }
            }
            // With icons only, the group's tiles held by a thin bracket in
            // the margin, rather than set in under a name.
            .overlay(alignment: .leading) {
                if icons && !members.isEmpty { IconGroupBracket(folded: group.collapsed).offset(x: -6) }
            }
        }
        if drawn.live {
            surface
                .modifier(RowGapSource(away: held.away, landing: settling?.tab == group.id ? settling?.offset ?? 0 : 0))
                .modifier(Carried(index: index, steps: steps, vertical: true, space: "rows",
                                  holding: { now in
                                      carryingGroup = now ? group.id : nil
                                      lifting = now
                                      if !now { putDown() }
                                  },
                                  gap: { carrying(.group(group.id), row: nil, at: $0) },
                                  placed: { placed($0, group: group.id) }, keptInView: true) { shift(group: group.id, in: area, to: $0) })
                // Over the others while it, or one of its tabs, is carried.
                .zIndex(carryingGroup == group.id ? 1 : 0)
        } else {
            surface
        }
    }

    /// The run under the pins: with groups on, the tabs in no group and the
    /// groups as they stand (Browser.sideItems); else every tab.
    private var runItems: [SideItem] {
        prefs.usesTabGroups ? browser.sideItems : looseTabs.map(SideItem.tab)
    }

    // MARK: - carried along the column

    /// A tab carried along its own run, moved as it goes, the others making
    /// way (Carried): in its group, or at the top of its area.
    private func shift(_ tab: Tab, along run: ColumnRun, to index: Int) {
        switch run.area {
        case .open:
            if let group = run.group {
                browser.move(tab, within: group, to: index)
            } else if prefs.usesTabGroups {
                browser.moveItem(.tab(tab.id), to: index)
            } else {
                browser.moveDisplayedTab(tab, to: index + browser.pinnedCount)
            }
        case .kept:
            browser.move(tab, to: ColumnPlace(area: .kept, group: run.group, index: index))
        }
    }

    /// A group carried along its own area, moved as it goes.
    private func shift(group id: UUID, in area: ColumnArea, to index: Int) {
        switch area {
        case .open: browser.moveItem(.group(id), to: index)
        case .kept: browser.move(group: id, to: ColumnPlace(area: .kept, index: index))
        }
    }

    /// The run something carried is along: a tab's area and its group in
    /// it, a group's area; none for a square, whose run is the grid's.
    private func run(of carried: SideItemID) -> ColumnRun? {
        switch carried {
        case .tab(let id):
            guard let tab = browser.tabs.first(where: { $0.id == id }), let area = browser.area(of: tab) else { return nil }
            switch area {
            case .kept: return ColumnRun(area: .kept, group: browser.keptGroup(of: tab))
            case .open: return ColumnRun(area: .open, group: prefs.usesTabGroups ? browser.group(of: tab) : nil)
            }
        case .group(let id):
            return browser.area(ofGroup: id).map { ColumnRun(area: $0) }
        }
    }

    /// The one carry (ColumnCarry). Something carried along its own run —
    /// its group, or the top of its area — moves as it goes, the others
    /// making way (Carried). Carried over another, that run parts for it
    /// where it would land, its own place closing behind it: above the
    /// line or under it, in a group in either, at the top of either, or on
    /// another device. Over one that won't take it, nothing opens and it
    /// holds still. As Arc's and Safari's columns show it, so where it will
    /// go is always in sight. `row`: the tab's row, nil for a group.
    private func carrying(_ carried: SideItemID, row tab: Tab?, at point: CGPoint?) -> CarryGap {
        guard let point, point.x >= -PinDrop.sideSlack, point.x <= width - 20 + PinDrop.sideSlack else {
            showCarry(nil)
            return .none
        }
        let laid = layout(carrying: carry)
        // The page picked up — a pair's half, either one — is what another
        // device is sent, and what it may have open already.
        let source = tab.map { TabDrag.shared.source(of: $0) ?? $0 }
        // A pair's half shown leaving it is carried on its own, one page;
        // the pair whole, its lines.
        let half = tab.map { tab in
            PairSeparation.shared.leaving.map { browser.split(for: tab)?.contains($0) == true } ?? false
        } ?? false
        var target: ColumnCarry.Target?
        var refused = false
        if let source, let device = device(for: source, at: point, in: laid) {
            target = .device(device)
        } else if let source, source.pin == nil, laid.device(at: point.y, holding: nil) != nil {
            // One of your tabs over a device's group that won't take it —
            // that device has its page open already, or it is a page the
            // devices aren't shown: nothing parts, and it holds still, as
            // it did before the kept area was under the devices. Falling
            // through to the head of the kept area, letting go there pinned
            // a tab that was being sent.
            refused = true
        } else {
            let unit = half ? source : tab
            let heading = unit.map { $0.pin != nil && $0.everywhere } ?? false
            let aim = laid.aim(for: carried, from: run(of: carried), at: point, holding: carry?.place, heading: heading) { place in
                switch carried {
                case .tab: unit.map { browser.takes($0, at: place, detaching: half) } ?? false
                case .group(let id): browser.takes(group: id, at: place)
                }
            }
            switch aim {
            case .along: break
            case .refused: refused = true
            case .place(let place): target = .place(place)
            }
        }
        let next = target.map { ColumnCarry(carried: carried, target: $0, height: height(of: carried, half: half, in: laid), whole: !half) }
        showCarry(next)
        guard let next else { return refused ? .held : .none }
        return next.moves ? .away : .copy
    }

    /// The room what is carried needs: a tab's line, a pair's lines, or a
    /// half's one; a group as tall as it was drawn when it left.
    private func height(of carried: SideItemID, half: Bool, in laid: ColumnLayout<Tab>) -> CGFloat {
        switch carried {
        case .tab(let id):
            guard !half, let tab = browser.tabs.first(where: { $0.id == id }) else { return rowHeight }
            return CGFloat(lines(of: tab, splits: browser.splits)) * rowHeight
        case .group(let id):
            if let carry, carry.carried == carried { return carry.height }
            for area in [ColumnArea.kept, .open] {
                for case .group(let held) in laid[area].pieces where held.group.id == id { return held.frame.height }
            }
            return rowHeight
        }
    }

    /// The other device whose group the hand is over, to open the tab there
    /// too: one the other devices can be shown (Sync.page(of:in:)) and that
    /// device hasn't open already. Kept a little past its edge, as a group
    /// keeps a tab (GroupDropFrames.resolve).
    ///
    /// Only one of your tabs, never a pin, square or row: a pin is on every
    /// device already, and one gone on from its home would send the page it
    /// wandered to while it stayed the pin here. Over a device's group a pin
    /// goes where anything else it won't take does, to the head of the kept
    /// area under it (ColumnLayout.area(at:)).
    private func device(for tab: Tab, at point: CGPoint, in laid: ColumnLayout<Tab>) -> String? {
        guard tab.pin == nil, Sync.shared.on, let page = Sync.page(of: tab, in: browser.spaceID),
              let url = URL(string: page.url),
              let over = laid.device(at: point.y, holding: carry?.device),
              let device = Sync.shared.devicesWithTabs.first(where: { $0.device == over })
        else { return nil }
        let identity = History.identity(for: url)
        guard !device.tabs.contains(where: { URL(string: $0.url).map(History.identity(for:)) == identity }) else { return nil }
        return over
    }

    /// The open group a tab under the line is over, for a pair's half let
    /// go there with Split View on (Carried, TabDrag): none for what a group
    /// can't take.
    private func openGroup(for tab: Tab, at point: CGPoint) -> GroupDropTarget? {
        guard prefs.usesTabGroups, tab.pin == nil, !tab.shy, !tab.bench else { return nil }
        let laid = layout(carrying: carry)
        guard laid.area(at: point.y) == .open else { return nil }
        return GroupDropFrames.resolve(CGPoint(x: laid.width / 2, y: point.y), frames: laid.dropFrames(in: .open),
                                       groups: laid.groups(in: .open), excluding: tab.id, vertical: true,
                                       holding: carry?.group ?? browser.group(of: tab))
    }

    /// The gap moved, on the column's settle, the rows between parting and
    /// closing; a tap of the trackpad when it opens in another run.
    private func showCarry(_ next: ColumnCarry?) {
        guard next != carry else { return }
        if let next, next.run != carry?.run {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        withAnimation(Motion.settle) { carry = next }
        spring(toward: next)
    }

    /// Resting on a folded group, in either area, it opens after a moment,
    /// as Finder's folders spring open, so the tab can be placed among its
    /// tabs; one opened so and then left folds again.
    private func spring(toward next: ColumnCarry?) {
        let over = next?.group.flatMap { id in browser.columnGroup(id)?.collapsed == true ? id : nil }
        if let sprung, next?.group != sprung { foldAgain() }
        guard over != springing?.group else { return }
        springing?.work.cancel()
        springing = nil
        guard let over else { return }
        let work = DispatchWorkItem {
            guard springing?.group == over, browser.columnGroup(over)?.collapsed == true else { return }
            springing = nil
            sprung = over
            withAnimation(GroupLook.fold) { browser.toggleTabGroup(over) }
        }
        springing = (over, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + ColumnCarry.spring, execute: work)
    }

    /// The group opened for the carry, folded again: the tab went elsewhere.
    private func foldAgain() {
        guard let id = sprung else { return }
        sprung = nil
        if browser.columnGroup(id)?.collapsed == false {
            withAnimation(GroupLook.fold) { browser.toggleTabGroup(id) }
        }
    }

    /// A tab let go with a gap open for it: it goes there, where it was
    /// shown it would, by the column's move (Browser.move(_:to:)) — pinned
    /// above the line, unpinned under it, a pair whole or the half shown
    /// leaving it. Onto another device, the page picked up is opened there,
    /// and kept here, sliding home as it comes into that device's list.
    private func placed(_ drop: CarriedDrop) -> Bool {
        guard let carry, let row = drop.row, carry.carried == .tab(row.id) else { return false }
        // Into the group it opened: it stays open.
        if carry.group == sprung { sprung = nil }
        let source = drop.source ?? row
        switch carry.target {
        case .device(let device):
            withAnimation(Motion.settle) {
                Sync.shared.askToOpen(source, in: browser.spaceID, on: device)
                self.carry = nil
            }
        case .place(let place):
            let detaching = drop.detaching || !carry.whole
            let moving = detaching ? source : row
            land(moving.id, drawn: drop.drawn) { browser.move(moving, to: place, detaching: detaching) }
        }
        return true
    }

    /// A group let go with a gap open for it in the other area: a kept group
    /// there, or an open one (Browser.move(group:to:)).
    private func placed(_ drop: CarriedDrop, group id: UUID) -> Bool {
        guard let carry, carry.carried == .group(id), let place = carry.place else { return false }
        land(id, drawn: drop.drawn) { browser.move(group: id, to: place) }
        return true
    }

    /// Into the gap: what was carried goes at once — on the column's settle
    /// it slid back to its old place as it faded, a second one beside the
    /// first — and is drawn anew in the gap, which is just its size,
    /// starting under the hand (`drawn`, its leading edge in the rows'
    /// space) and settling into it.
    private func land(_ id: UUID, drawn: CGFloat?, move: () -> Void) {
        var offset: CGFloat = 0
        if let drawn, let top = gapFrame.top { offset = drawn - top }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            move()
            carry = nil
            settling = RowLanding(tab: id, offset: offset)
        }
        DispatchQueue.main.async {
            withAnimation(Motion.settle) { settling = nil }
        }
    }

    /// Put down, let go or called off: no gap, no group left open that it
    /// opened.
    private func putDown() {
        springing?.work.cancel()
        springing = nil
        if carry != nil { withAnimation(Motion.settle) { carry = nil } }
        foldAgain()
    }

    // MARK: - carried between the squares and the rows

    /// The space a carried thing's point is measured in.
    private enum From { case pins, rows }

    /// The place open in the grid, while a tab is carried over it.
    private var ghostSquare: Int? { crossing?.slot }

    /// The tab being carried over the grid, while it is.
    private var crossingTab: Tab? {
        crossing.flatMap { crossing in browser.tabs.first { $0.id == crossing.tab } }
    }

    /// A square being carried out over the rows.
    private var carriedPin: Bool {
        guard case .tab(let id)? = carry?.carried, let tab = browser.tabs.first(where: { $0.id == id }) else { return false }
        return tab.pin != nil && !(tab.listed && prefs.showsPinRows)
    }

    private func columnPoint(_ point: CGPoint, from: From) -> CGPoint {
        let origin: CGPoint
        switch from {
        case .pins: origin = frames.grid?.origin ?? .zero
        case .rows: origin = frames.rows.origin
        }
        return CGPoint(x: point.x + origin.x, y: point.y + origin.y)
    }

    /// Where among the squares `tab` would land with the hand at `point`
    /// (the column's space): nil off the grid, or for what it won't take —
    /// a pair, a private tab, a square already there.
    private func squareSlot(for tab: Tab, at point: CGPoint) -> Int? {
        let squares = browser.squarePins.filter { $0.id != tab.id }
        let gridShown = !squares.isEmpty || ghostSquare != nil
        guard PinDrop.zone(point, width: width - 20, gridBottom: gridShown ? frames.grid?.maxY : nil) == .squares else { return nil }
        let takes = tab.pin == nil ? browser.pinsByDrag(tab) : (prefs.showsPinRows && tab.listed)
        guard takes else { return nil }
        let origin = gridShown ? frames.grid?.origin ?? .zero : .zero
        let slot = PinDrop.gridSlot(CGPoint(x: point.x - origin.x, y: point.y - origin.y),
                                    cells: pinCells(squares.count + 1))
        return browser.pinSlot(tab, listed: false, proposed: slot)
    }

    /// A row carried over the squares: the grid opens a place where it
    /// would land, and says so once, by touch, as it starts to. True while
    /// it does; the rows then let go of it.
    private func overSquares(_ tab: Tab, _ point: CGPoint) -> Bool {
        let now = squareSlot(for: tab, at: columnPoint(point, from: .rows)).map { PinDrop.Crossing(tab: tab.id, slot: $0) }
        if now != crossing {
            if crossing == nil, now != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            withAnimation(Motion.settle) { crossing = now }
        }
        return now != nil
    }

    /// A row let go (nil: called off): over the grid, a square where it was
    /// shown it would land (Browser.square). True when the grid took it.
    private func landOnSquares(_ tab: Tab, _ point: CGPoint?) -> Bool {
        let shown = crossing?.tab == tab.id ? crossing?.slot : nil
        guard point != nil, let shown else {
            if crossing != nil { withAnimation(Motion.settle) { crossing = nil } }
            return false
        }
        withAnimation(Motion.settle) {
            crossing = nil
            browser.square(tab, at: shown)
        }
        return true
    }

    /// A square carried out over the rows: they part for it where it would
    /// land, as for any tab carried there (`carrying`). True while the hand
    /// is past the grid, and the grid then holds still.
    private func squareOverRows(_ tab: Tab, _ point: CGPoint) -> Bool {
        let at = columnPoint(point, from: .pins)
        let gridBottom = browser.squarePins.isEmpty ? nil : frames.grid?.maxY
        guard PinDrop.zone(at, width: width - 20, gridBottom: gridBottom) == .rows else {
            _ = carrying(.tab(tab.id), row: tab, at: nil)
            return false
        }
        _ = carrying(.tab(tab.id), row: tab, at: CGPoint(x: at.x - frames.rows.minX, y: at.y - frames.rows.minY))
        return true
    }

    /// A square let go (nil: called off): over the rows, where they parted
    /// for it — a row above the line, a tab under it. True when they took it.
    private func squareLand(_ tab: Tab, _ point: CGPoint?) -> Bool {
        guard point != nil, let carry, carry.carried == .tab(tab.id) else {
            putDown()
            return false
        }
        if carry.group == sprung { sprung = nil }
        withAnimation(Motion.settle) {
            switch carry.target {
            case .device(let device): Sync.shared.askToOpen(tab, in: browser.spaceID, on: device)
            case .place(let place): browser.move(tab, to: place)
            }
            self.carry = nil
        }
        putDown()
        return true
    }

    /// The New Tab row where new tabs go: at the top of yours, under the
    /// line, with new tabs going to the top (Settings › Tabs); else under
    /// them all.
    private var newTabOnTop: Bool { prefs.newTabPlace == .top }

    /// The foot's door and its margin beneath; with icons only, its doors
    /// one above the other.
    private var footHeight: CGFloat {
        icons ? CGFloat(SideFoot.doors(prefs, browser.fetches, hanging: browser.downloadsHanging)) * 28 + 8 : 26 + 10
    }
    /// Between what plays in another tab and the foot's doors.
    private static let playerGap: CGFloat = 4

    /// The New Tab row: under the line at the top of your tabs, or under
    /// them all (newTabOnTop). Never somewhere to put what is carried, from either area: the hand
    /// over it is over the head of your tabs, or their foot with it under
    /// them all (ColumnLayout.topLevel), and while a row, a group or a
    /// square is carried it doesn't light, as a place to drop would, nor
    /// answer the pointer at all.
    @ViewBuilder
    private var newTab: some View {
        let carried = lifting || carry != nil || crossing != nil
        Group {
            if icons {
                Quiet(icon: "plus", title: "", height: rowHeight, size: prefs.sideTitle, centred: true,
                      lit: browser.launching) { browser.launch() }
                    .help("New Tab   ⌘T")
            } else {
                Quiet(icon: "plus", title: "New tab", height: rowHeight, size: prefs.sideTitle,
                      lit: browser.launching) { browser.launch() }
            }
        }
        .allowsHitTesting(!carried)
    }

    /// One small door at the bottom: the settings.
    private var foot: some View {
        SideFoot(browser: browser, prefs: prefs, fetches: browser.fetches, vertical: icons, width: width)
    }

}

/// The row at the bottom of the column. Never wider than the column: wider,
/// the column took its width, and centred in its own frame it slid half the
/// overflow off each side (#535). The space's door, the puzzle and
/// downloads stay put; the pinned extensions that don't fit give way, from
/// the last, and are still in the puzzle's list.
private struct SideFoot: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var fetches: Fetches
    /// The column of icons: one above the other, centred, no pinned
    /// extensions (their list is still the puzzle's).
    var vertical = false
    /// The column's width, as it is drawn.
    let width: CGFloat

    var body: some View {
        if vertical {
            VStack(spacing: 2) {
                FetchDoor(browser: browser, fetches: fetches, arrowEdge: prefs.sidePosition == .right ? .leading : .trailing)
                ExtensionSlot(browser: browser, edge: prefs.sidePosition == .right ? .leading : .trailing, room: 0)
                ElsewhereDoor(browser: browser, arrowEdge: prefs.sidePosition == .right ? .leading : .trailing)
                if prefs.usesSpaces { SpaceDot(browser: browser) }
                if Profiles.shared.several { ProfileBadge(browser: browser) }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
        } else {
            HStack(spacing: 2) {
                if Profiles.shared.several { ProfileBadge(browser: browser) }
                if prefs.usesSpaces { SpaceDot(browser: browser) }
                ExtensionSlot(browser: browser, edge: .trailing, room: room)
                // Only while a download is running, and a moment after.
                FetchDoor(browser: browser, fetches: fetches, arrowEdge: prefs.sidePosition == .right ? .leading : .trailing)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    /// How many doors the foot has, stacked: what the rows stop short of.
    @MainActor static func doors(_ prefs: Preferences, _ fetches: Fetches, hanging: Bool = false) -> Int {
        var kept = 1  // the puzzle
        if prefs.usesSpaces { kept += 1 }
        if Profiles.shared.several { kept += 1 }
        if FetchDoor.shows(fetches, prefs, hanging: hanging) { kept += 1 }
        if Sync.shared.presence.hasTabs { kept += 1 }
        return kept
    }

    /// How many pinned extensions fit beside the doors that stay. Every door
    /// is 26 points, with 2 between them.
    private var room: Int {
        let door: CGFloat = 26 + 2
        var kept = 1  // the puzzle
        if prefs.usesSpaces { kept += 1 }
        if Profiles.shared.several { kept += 1 }
        if FetchDoor.shows(fetches, prefs, hanging: browser.downloadsHanging) { kept += 1 }
        let free = width - 2 * 10 + 2 - CGFloat(kept) * door
        return max(0, Int((free / door).rounded(.down)))
    }
}

/// The pinned squares' grid, every cell laid out at once. A lazy grid makes
/// its cells only once the column is on screen, where the column's slide
/// can't take them along: folded with ⌘S and brought back, the squares stood
/// in place while the column came in beneath them. A dozen squares need no
/// laziness.
private struct PinGrid: Layout {
    /// Each square's place, worked out by the column (see pinCells).
    let cells: [CGRect]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: cells.map(\.maxX).max() ?? 0, height: cells.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() where cells.indices.contains(index) {
            let cell = cells[index]
            subview.place(
                at: CGPoint(x: bounds.minX + cell.minX, y: bounds.minY + cell.minY),
                proposal: ProposedViewSize(width: cell.width, height: cell.height)
            )
        }
    }
}

/// A pinned tab as a cell in the block at the top of the column — as wide as
/// its row asks for, but never taller than the classic square, so a row with
/// room to spare turns into a wide, short button rather than a bigger icon.
private struct PinSquare: View, Equatable {
    @Environment(\.greys) private var greys
    @Environment(\.tabShortcutNumbers) private var shortcutNumbers
    let browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    var width: CGFloat = 34
    var height: CGFloat = 34
    /// Its letter being changed.
    private let lettering: Bool
    private let selected: Bool
    /// Picked with ⌘ or ⇧ along with others: its press leaves the pick be.
    private let pickedAmongOthers: Bool
    /// The peek opened from it, while it is up.
    private let peek: Tab?
    /// Pressed and pointed at: not in another space's column passing by.
    private let interactive: Bool

    init(browser: Browser, prefs: Preferences, tab: Tab, live: Bool,
         width: CGFloat = 34, height: CGFloat = 34, interactive: Bool = true) {
        self.browser = browser
        self.prefs = prefs
        self.tab = tab
        self.live = live
        self.width = width
        self.height = height
        self.interactive = interactive
        lettering = browser.editingPin == tab.id
        selected = browser.selectedTabIDs.contains(tab.id)
        pickedAmongOthers = browser.isPickedAmongOthers(tab)
        peek = browser.peekFrom == tab.id ? browser.peekTab : nil
    }

    static func == (a: PinSquare, b: PinSquare) -> Bool {
        a.browser === b.browser && a.prefs === b.prefs && a.tab === b.tab && a.live == b.live && a.width == b.width && a.height == b.height
            && a.interactive == b.interactive && a.lettering == b.lettering && a.selected == b.selected
            && a.pickedAmongOthers == b.pickedAmongOthers && a.peek === b.peek
    }

    @State private var hovering = false
    @State private var selectedOnPress = false

    /// The colour its glow takes while it is in front: its site icon's own.
    private var accent: Color? {
        guard prefs.glyph == .icons, let icon = tab.icon, let colour = IconAccent.of(icon) else { return nil }
        return Color(nsColor: colour)
    }

    /// Everything drawn inside scales off the shorter edge — the one that
    /// stays put — so the glyph sits at its usual size, centred, rather than
    /// stretching to chase the width.
    private var scale: CGFloat { min(width, height) }

    var body: some View {
        Group {
            if lettering {
                PinField(browser: browser, tab: tab)
            } else if let number = shortcutNumbers[tab.id] {
                TabShortcutNumber(number: number)
            } else if tab.loading {
                // Its page on the way, as a row's ring says.
                Ring(size: scale * 11 / 34)
            } else if prefs.glyph == .icons, let icon = tab.icon {
                // At rest or not, a pin looks the same: it is always there.
                Mark(icon: icon, letter: tab.pin ?? "", size: scale * 16 / 34)
            } else {
                Text(tab.pin ?? "")
                    .font(.system(size: scale * 12 / 34, weight: .medium))
                    .foregroundStyle(live ? Palette.ink : Palette.muted)
            }
        }
        .frame(width: scale * 16 / 34, height: scale * 16 / 34)
        .frame(width: width, height: height)
        .background {
            Group {
                if live {
                    // Darker than the resting squares' grey by as much as a live
                    // row is darker than the white it sits on (Drice: the live
                    // pin barely showed among the others); with a site icon
                    // of some colour, lit in it too (PinGlow).
                    RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                        .fill(greys.pinLive)
                        .overlay { if let accent { PinGlow(colour: accent, radius: scale * 9 / 34) } }
                } else {
                    RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                        .fill(selected ? greys.wash :
                              hovering ? greys.hover : greys.tile)
                }
            }
            // Lit at once when it comes to the front, as a row is.
            .animation(nil, value: live)
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            // The peek opened from it, while it is up.
            if let page = peek {
                PeekBadge(page: page, size: scale * 16 / 34)
                    .offset(x: scale * 4 / 34, y: -scale * 4 / 34)
            }
        }
        .animation(Motion.quick, value: peek?.id)
        .contentShape(RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous))
        .modifier(TabPress(enabled: !lettering && !pickedAmongOthers, active: live, selected: $selectedOnPress) {
            browser.clearTabSelection()
            browser.select(tab)
        })
        .modifier(OneClick(double: live) {
            guard !selectedOnPress, TabClick.flags.intersection([.command, .shift, .option]).isEmpty else { return }
            browser.clearTabSelection()
            if live { browser.goHome(tab) } else { browser.select(tab) }
        })
        .modifier(ModifiedTabClick { browser.extendTabSelection(to: tab, modifiers: $0) })
        .modifier(OptionClick { if !lettering { browser.optionClick(tab) } })
        // Put down, like ⌘W: close() is what knows a pin isn't removed.
        .overlay { MiddleClick { browser.close(tab) } }
        .onHover { hovering = $0 }
        // Its title, which a square has no room for, and more: the card
        // takes the tooltip's place.
        .tabHoverCard(tab, in: browser, enabled: interactive && !lettering)
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
        .animation(nil, value: hovering)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// The pinned tab in front, lit in its site icon's colour, as Dia's is: a
/// wash of it, a soft glow in from the edge, and the edge itself.
private struct PinGlow: View {
    let colour: Color
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(colour.opacity(0.16))
            shape.strokeBorder(colour.opacity(0.55), lineWidth: 5)
                .blur(radius: 4)
                .clipShape(shape)
            shape.strokeBorder(colour.opacity(0.9), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// One tab, as a line in the column.
///
/// It doesn't watch the Browser. The little of it a row shows is read as the
/// column makes the row, and a row is drawn again only when that, its tab or
/// the settings change (==): watching the whole Browser, every row was drawn
/// again for anything that changed in the window. The Browser is kept for
/// what a click on the row does.
private struct SideRow: View, Equatable {
    @Environment(\.greys) private var greys
    @Environment(\.tabShortcutNumbers) private var shortcutNumbers
    let browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let close: () -> Void
    var interactive = true
    /// Its address being typed in the row.
    private let editing: Bool
    /// Picked with ⌘ or ⇧.
    private let selected: Bool
    /// Picked along with others: its press leaves the pick be.
    private let pickedAmongOthers: Bool
    /// The peek opened from it, while it is up.
    private let peek: Tab?
    /// Bumped when what was typed in a tab can't be gone to (see Shake).
    private let refusals: Int
    /// Its cross is a minus: closing it puts its page away (Browser.putsAway).
    private let putsAway: Bool
    /// In a group, in either area — a kept group, or an open one with
    /// groups on: a page put away or put down from it stays a row there.
    private let grouped: Bool

    init(browser: Browser, prefs: Preferences, tab: Tab, live: Bool,
         close: @escaping () -> Void, interactive: Bool = true) {
        self.browser = browser
        self.prefs = prefs
        self.tab = tab
        self.live = live
        self.close = close
        self.interactive = interactive
        editing = browser.editingTab == tab.id
        selected = browser.selectedTabIDs.contains(tab.id)
        pickedAmongOthers = browser.isPickedAmongOthers(tab)
        peek = browser.peekFrom == tab.id ? browser.peekTab : nil
        refusals = browser.refusals
        putsAway = browser.putsAway(tab)
        grouped = browser.area(of: tab) == .kept
            ? browser.keptGroup(of: tab) != nil
            : prefs.usesTabGroups && browser.group(of: tab) != nil
    }

    /// The close action is left out: it closes the same tab every time.
    static func == (a: SideRow, b: SideRow) -> Bool {
        a.browser === b.browser && a.prefs === b.prefs && a.tab === b.tab && a.live == b.live && a.interactive == b.interactive && a.editing == b.editing
            && a.selected == b.selected && a.pickedAmongOthers == b.pickedAmongOthers
            && a.peek === b.peek && a.refusals == b.refusals && a.putsAway == b.putsAway
            && a.grouped == b.grouped
    }

    @State private var hovering = false
    @State private var selectedOnPress = false
    @State private var shake: CGFloat = 0
    @State private var pressed = false
    /// The pointer on the home's icon of a pin away from it (HomeDoor).
    @State private var homeHovering = false

    /// The ring, which stays for as long as the page loads and so keeps a
    /// place of its own at the end of the row. The cross is only there under
    /// the pointer, and takes none.
    private var status: Bool { !editing && tab.loading }
    /// The speaker, just after the icon (Speaker), while the page plays or
    /// is muted.
    private var speaker: Bool { !editing && !tab.loading && (tab.noisy || tab.muted) }
    /// A pinned row with a peek opened from it: the peek's icon at its end,
    /// as on a square's corner.
    private var peeking: Bool { !editing && tab.pin != nil && peek != nil }
    /// What the page warns of, on the row you're on: a glyph before its
    /// title (TabTitle).
    private var warning: AtRest? { live ? AtRest.warning(tab.restAddress) : nil }
    /// A pin already put down has nothing left to put down (#1050): its
    /// cross is a × that takes the pin out for good (Browser.deletePin).
    private var deletes: Bool { tab.pin != nil && tab.asleep }
    /// A pin gone on from its page (Tab.wandered): its home's icon at the
    /// start, which takes it back there, then a slash and the page it is on.
    private var away: Bool { !editing && tab.wandered }
    /// How far the speaker sits from the row's start: after the icon, and
    /// after the slash too while the pin is away.
    private var speakerInset: CGFloat {
        if away { return Metrics.rowInset + prefs.sideMark + Self.slashPlace + Metrics.rowSpacing }
        return Metrics.rowInset + (tab.isBlank ? 0 : prefs.sideMark + Metrics.rowSpacing)
    }
    /// The slash's width, and its place after the icon, the space before it
    /// included: fixed, so the speaker laid over the row knows where to sit.
    private static let slashWidth: CGFloat = 4
    private static let slashPlace: CGFloat = 11
    /// A grouped tab holding no page, above the line or under it — put away
    /// or put down with its minus (Browser.putAway, Browser.close), put to
    /// sleep, or not opened since launch: the row stays, dimmed, so the
    /// minus is seen to have done something, the same in both areas.
    /// Read from the tab here, not when the column made the row: the column
    /// isn't drawn again when one of its tabs lets its page go.
    private var putAway: Bool { grouped && tab.asleep && !live }

    var body: some View {
        let _ = Bench.count("row")
        HStack(spacing: Metrics.rowSpacing) {
            HStack(spacing: Metrics.rowSpacing) {
                if editing {
                    TabAddressField(browser: browser)
                        .frame(height: 16)
                } else {
                    // The site's icon, or with Letters its letter: beside the
                    // title either way, as Settings says (#919). Away, the
                    // home's, then the slash.
                    if !tab.isBlank {
                        HStack(spacing: 0) {
                            mark
                            if tab.pin != nil { slash }
                        }
                    }
                    // The speaker's place: it is laid over it below, outside
                    // the row's press, so muting a tab doesn't also go to it.
                    if speaker { Color.clear.frame(width: RowCross.size, height: RowCross.size) }
                    if tab.bench {
                        // A script's tab, not yours.
                        Image(systemName: "flask")
                            .font(.system(size: 9))
                            .foregroundStyle(colour.opacity(0.7))
                    }
                    if tab.shy {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(colour.opacity(0.7))
                    }
                    if tab.recording {
                        // An extension recording from this page (RecordingIndicator).
                        Image(systemName: "record.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(colour.opacity(0.8))
                            .help("Recording")
                    }
                    // A window the page asked for was refused (BlockedPopups).
                    PopupSign(browser: browser, tab: tab, colour: colour)
                    // The page is translated (Translate.swift).
                    TranslateSign(tab: tab, colour: colour)
                    TabTitle(label: away ? tab.pageLabel : tab.label, warning: warning, size: prefs.sideTitle, colour: colour)
                        // A new title arriving as the slash comes or goes
                        // takes its place at once: it moves with the slash,
                        // and is never laid over the old one as they fade.
                        .contentTransition(.identity)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, Metrics.rowInset)
            .padding(.trailing, status || peeking ? 0 : Metrics.rowInset)
            .frame(height: prefs.sideRow)
            .contentShape(Rectangle())
            .modifier(TabPress(enabled: interactive && !editing && !pickedAmongOthers, active: live, selected: $selectedOnPress, pressing: $pressed) {
                browser.clearTabSelection()
                browser.select(tab)
            })
            .overlay(alignment: .leading) {
                if speaker {
                    Speaker(tab: tab)
                        .padding(.leading, speakerInset)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .leading) {
                // Over the icon, outside the row's press, so going home
                // doesn't also go to the row.
                if away && interactive {
                    HomeDoor(size: prefs.sideMark, hovering: $homeHovering) {
                        // A plain click only: with ⌘, ⇧ or ⌥ the click is the
                        // row's, which picks or splits as anywhere else on it.
                        guard TabClick.flags.intersection([.command, .shift, .option, .control]).isEmpty else { return }
                        browser.clearTabSelection()
                        if !live { browser.select(tab) }
                        browser.goHome(tab)
                    }
                    .padding(.leading, Metrics.rowInset - HomeDoor.margin)
                }
            }

            if peeking, let page = peek {
                // Under the pointer the cross takes its place, unless the
                // ring or the speaker already holds the end of the row.
                PeekBadge(page: page, size: 16)
                    .opacity(hovering && !status ? 0 : 1)
            }

            if interactive, !editing, let number = shortcutNumbers[tab.id] {
                TabShortcutNumber(number: number)
                    .padding(.trailing, status ? 0 : 28)
            }

            if status {
                Ring()
                    .transition(.opacity)
                    .frame(width: 15, height: 15)
                    // The cross takes this place while the pointer is here.
                    .opacity(hovering ? 0 : 1)
            }
        }
        .padding(.trailing, status || peeking ? 7 : 0)
        .frame(height: prefs.sideRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The title keeps its length under the pointer and fades out
        // beneath the cross, rather than being cut shorter, so its end
        // doesn't jump on each row the pointer passes.
        .mask {
            ZStack {
                Rectangle().opacity(hovering && !editing && !status ? 0 : 1)
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                    Color.clear.frame(width: RowCross.size + Metrics.rowCrossInset + 2)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if !editing {
                ZStack {
                    if hovering {
                        // A pinned row is put down, not closed (see
                        // Browser.close), and says so with a minus; so is a
                        // grouped tab's page while it is open (closeTab).
                        // Put down, its × takes the pin out.
                        RowCross(symbol: (tab.pin != nil && !deletes) || (putsAway && !tab.asleep) ? "minus" : "xmark",
                                 height: prefs.sideRow) {
                            guard hovering else { return }
                            if deletes { browser.deletePin(tab) } else { close() }
                        }
                            .transition(.opacity)
                    }
                }
                .frame(width: RowCross.size, height: RowCross.size)
                .padding(.trailing, Metrics.rowCrossInset)
            }
        }
        .animation(Motion.quick, value: tab.loading)
        .animation(Motion.quick, value: speaker)
        .animation(Motion.quick, value: tab.blockedPopups.isEmpty)
        .animation(Motion.quick, value: tab.translation == nil)
        .animation(Motion.quick, value: peeking)
        // The slash opens its place on the row's spring, the title moving
        // with it (see `slash`).
        .animation(Motion.settle, value: away)
        .onChange(of: away) { _, now in if !now { homeHovering = false } }
        // Lit at once when it comes to the front: nothing glides or fades
        // from the tab that was.
        .background { ground.animation(nil, value: live) }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .modifier(Shake(travel: shake))
        .modifier(Give(pressed: pressed && prefs.tabsGive))
        .contentShape(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
        .modifier(OneClick(double: false) {
            guard interactive, !selectedOnPress, TabClick.flags.intersection([.command, .shift, .option]).isEmpty else { return }
            browser.clearTabSelection()
            if live { browser.beginTabEdit(tab) } else { browser.select(tab) }
        })
        .modifier(ModifiedTabClick { if interactive && !editing { browser.extendTabSelection(to: tab, modifiers: $0) } })
        .modifier(OptionClick { if interactive && !editing { browser.optionClick(tab) } })
        .overlay { if interactive { MiddleClick(act: close) } }
        .onHover(perform: hover)
        .tabHoverCard(tab, in: browser, enabled: interactive && !editing)
        .onAppear { if interactive { Bench.rowAppeared(tab.id, hover: hover) } }
        .onDisappear { if interactive { Bench.rowDisappeared(tab.id) } }
        .contextMenu { if interactive { TabMenu(browser: browser, tab: tab, close: close) } }
        .background {
            if interactive && prefs.splitView {
                SplitDropZone(browser: browser, tab: tab, kind: .strip)
            }
        }
        .animation(nil, value: hovering)
        .animation(Motion.glide, value: editing)
        .onChange(of: refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        .transition(.sideRow)
    }

    private func hover(_ over: Bool) { hovering = over }

    /// The icon, the same view at home and away, so going away or coming
    /// back changes only its picture where the two differ: away, the home's,
    /// on the square HomeDoor lights under the pointer.
    private var mark: some View {
        Mark(icon: prefs.glyph == .icons ? (away ? tab.homeIcon : tab.icon) : nil,
             letter: away ? tab.pin ?? tab.monogram : tab.monogram, size: prefs.sideMark, dim: putAway)
            .background {
                RoundedRectangle(cornerRadius: RowCross.corner, style: .continuous)
                    .fill(Palette.ink.opacity(away && homeHovering ? 0.1 : 0))
                    .padding(-HomeDoor.margin)
                    .animation(Motion.quick, value: homeHovering)
            }
    }

    /// The slash after the icon while the pin is away. Always there, its
    /// place opening and closing: it keeps to the title's side of that
    /// place, so it travels with the title as the title makes way or comes
    /// back, rather than fading where it stands while the title slides
    /// through it.
    private var slash: some View {
        Text("/")
            .font(.system(size: prefs.sideTitle))
            .foregroundStyle(Palette.faint)
            .frame(width: Self.slashWidth)
            .frame(width: away ? Self.slashPlace : 0, alignment: .trailing)
            .clipped()
            .opacity(away ? 1 : 0)
            .accessibilityHidden(!away)
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            ZStack(alignment: .leading) {
                Rectangle().fill(greys.wash)
                if prefs.showsReading {
                    GeometryReader { geo in
                        ReadingFill(meter: tab.meter, width: geo.size.width)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
        } else if selected {
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(greys.wash)
        } else if hovering {
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(greys.hover)
        }
    }

    private var colour: Color {
        if live { return Palette.ink }
        let colour = hovering ? Palette.ink.opacity(0.7) : Palette.muted
        return putAway ? colour.opacity(0.45) : colour
    }
}

/// A row that is an action rather than a page. Quiet until the pointer is on it.
struct Quiet: View {
    @Environment(\.greys) private var greys
    let icon: String
    let title: String
    var height: CGFloat = 28
    var size: CGFloat = 12.5
    /// The icon alone, in the middle: the column of icons' new tab.
    var centred = false
    /// Worn as the live tab's row is: the New tab row while ⌘T's field is
    /// up, as Zen's is, the tab that will be made being the one in front.
    var lit = false
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: Metrics.rowSpacing) {
                if centred { Spacer(minLength: 0) }
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 15)
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: size))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(lit ? Palette.ink : hovering ? Palette.ink.opacity(0.7) : Palette.faint)
            .padding(.leading, centred ? 0 : Metrics.rowInset)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(lit ? greys.wash : hovering ? greys.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// The line between what is kept and the tabs that come and go, as Arc
/// draws it over its Today tabs, with Clear at its end under the pointer:
/// the tabs below it closed, everything above it left as it was.
extension AnyTransition {
    /// A line of the column coming or going: a tab's, or another device's
    /// page (Elsewhere.swift), shrinking a touch towards its start as it
    /// fades, while the column settles round it (Motion.settle).
    static let sideRow = AnyTransition.scale(scale: 0.94, anchor: .leading).combined(with: .opacity)
}

/// The face every small control on a line of the column wears, after Dia's:
/// a symbol alone, on a square of grey with rounded corners only while the
/// pointer is on it — the cross, the speaker and the player's buttons all
/// the same, so none reads as heavier than the one beside it. One face, so
/// a control restyled is restyled everywhere.
struct RowSquare: View {
    let symbol: String
    let hovering: Bool
    /// The symbol's size: the cross a touch larger, for its thin strokes.
    var glyph: CGFloat = 10
    /// The square's side: a line's, or a card's roomier one (TabHoverCard).
    var size: CGFloat = RowCross.size

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RowCross.corner, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: glyph, weight: .medium))
            .foregroundStyle(Palette.ink.opacity(hovering ? 0.9 : 0.65))
            .frame(width: size, height: size)
            .background(Palette.ink.opacity(hovering ? 0.1 : 0), in: shape)
            .contentShape(shape)
    }
}

/// The cross at the end of a line in the column, under the pointer: a
/// tab's, or a group heading's; a pinned tab's minus. As Dia's: a plain
/// cross the size of the line's text, on nothing, that wears a rounded
/// square of grey while the pointer is on it.
struct RowCross: View {
    var symbol = "xmark"
    /// The line's height: the pointer anywhere in its reach, that tall,
    /// lights it and its click takes it.
    var height: CGFloat = 28
    /// What a click in its reach does; nil where something round it takes
    /// the click (a button it is the face of, or CloseClick).
    var action: (() -> Void)?

    @State private var hovering = false

    static let size: CGFloat = 22
    /// Its square's corners, the speaker's too (Speaker).
    static let corner: CGFloat = 6
    /// How wide a reach around it takes the click.
    static let reachWidth: CGFloat = 30

    var body: some View {
        RowSquare(symbol: symbol, hovering: hovering, glyph: 11)
            .overlay {
                // Wider than it, and the line's whole height.
                Color.clear
                    .frame(width: Self.reachWidth, height: height)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .taking(action)
            }
            .animation(Motion.quick, value: hovering)
    }
}

private extension View {
    /// The click, when there is something for it to do; else left to what
    /// is round it, a button the cross is the face of.
    @ViewBuilder func taking(_ action: (() -> Void)?) -> some View {
        if let action { onTapGesture(perform: action) } else { self }
    }
}

struct KeepLine: View {
    static let height: CGFloat = 18
    /// How many are drawn, for the bench (`columnscroll`). Test runs only.
    @MainActor static var drawn = 0
    /// Whether there is anything under it to clear.
    let clears: Bool
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
            if clears && hovering {
                Button(action: act) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .semibold))
                        Text("Clear")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Palette.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close the tabs under the line. Pins and groups stay; ⇧⌘T brings them all back.")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: KeepLine.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { if Store.testing { KeepLine.drawn += 1 } }
        .onDisappear { if Store.testing { KeepLine.drawn -= 1 } }
        .animation(Motion.quick, value: hovering)
    }
}

/// A pinned row's way home while it is away from its page: a click on its
/// home's icon takes the pin back. Nothing of its own to see, so nothing
/// fades in or out over the icon as the pin goes and comes back; the row
/// lights the icon's square while the pointer is here (SideRow.mark), as
/// the row's other small controls light theirs (RowSquare).
private struct HomeDoor: View {
    let size: CGFloat
    @Binding var hovering: Bool
    let act: () -> Void

    /// How far its square reaches past the icon on each side.
    static let margin: CGFloat = 3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RowCross.corner, style: .continuous)
        Button(action: act) {
            Color.clear
                .frame(width: size + Self.margin * 2, height: size + Self.margin * 2)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Back to Pinned Page")
        .accessibilityLabel("Back to Pinned Page")
    }
}

/// A playing or muted tab's speaker, which mutes or unmutes it: as Dia's,
/// just after the site's icon, for as long as the page plays or is muted,
/// rather than a small circle at the row's end that stepped aside for the
/// cross under the pointer. It wears the cross's face (RowSquare).
struct Speaker: View {
    @ObservedObject var tab: Tab
    /// Across the top, where a tab is too short for the square: the small
    /// circle it always wore there.
    var small = false

    @State private var hovering = false

    var body: some View {
        Button(action: tab.toggleMute) {
            if small {
                Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 15, height: 15)
                    .background(Palette.ink.opacity(hovering ? 0.07 : 0), in: Circle())
                    .contentShape(Circle())
            } else {
                RowSquare(symbol: tab.muted ? "speaker.slash" : "speaker.wave.2", hovering: hovering)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.muted ? "Unmute Tab" : "Mute Tab")
        .animation(Motion.quick, value: hovering)
    }
}

/// A small square holding one symbol. Lit when what it opens is open.
struct Door: View {
    @Environment(\.greys) private var greys
    let icon: String
    var on = false
    var help = ""
    /// What holding the button down opens, as Back and Forward list the
    /// pages that way. Nil, or a nil menu, and a hold is just a slow click.
    var held: (() -> NSMenu?)? = nil
    let act: () -> Void

    @State private var hovering = false
    /// The hold opened its menu: the click that ends the press is the
    /// menu's, not the button's.
    @State private var opened = false

    var body: some View {
        Button {
            if opened { opened = false } else { act() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? greys.wash : (hovering ? greys.hover : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                guard let menu = held?() else { return }
                opened = true
                // Opened under the pointer while the button is still down,
                // so dragging onto a row and letting go picks it, as in
                // Safari. popUp returns once the menu has closed.
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                // The press ended inside the menu, so no click may reach the
                // button after all; don't let this one swallow the next.
                DispatchQueue.main.async { opened = false }
            },
            isEnabled: held != nil
        )
        // A right-click opens the same menu at once, as in Chrome.
        .overlay { if let held { RightClick(menu: held) } }
        .onHover { hovering = $0 }
        .help(help)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: on)
    }
}

/// A right-click over a door, and only that. SwiftUI has no right-click of
/// its own short of a context menu built when the view is drawn, which would
/// list the pages as they were then. This view answers the hit test only for
/// a right-click, so every other click and the hover fall through to the
/// button beneath.
private struct RightClick: NSViewRepresentable {
    let menu: () -> NSMenu?

    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ view: Catcher, context: Context) { view.pages = menu }

    final class Catcher: NSView {
        var pages: (() -> NSMenu?)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .rightMouseDown else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = pages?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

/// A pinned square picked up and carried across the grid, its travel its
/// own: only the square being carried redraws as the hand moves, and the
/// grid only when it changes place.
struct PinCarried: ViewModifier {
    let index: Int
    let cells: [CGRect]
    /// Carried out over the tabs (see Carried.cross): true while they show
    /// where it would land, and the square then stays out of the grid's way.
    var cross: ((CGPoint) -> Bool)? = nil
    /// Let go: true when the tabs took it.
    var land: ((CGPoint?) -> Bool)? = nil
    let move: (Int) -> Void

    @State private var held = false
    @State private var from = 0
    @State private var travel: CGSize = .zero
    /// Put back by SwiftUI when the drag is called off as well as when it
    /// ends: the square's look changing under the hand calls it off, and the
    /// square stayed floating (see CarryGuard).
    @GestureState private var carrying = false
    @State private var ticket = UUID()

    func body(content: Content) -> some View {
        content
            // Read where the square is drawn this frame, partway through the
            // spring to its new cell, and only for the square in hand.
            .visualEffect { [held, travel, from, cells] content, proxy in
                guard held else { return content.offset(.zero) }
                let frame = proxy.frame(in: .named("pins"))
                return content.offset(PinCarried.offset(travel: travel, from: from, cells: cells,
                                                        now: CGPoint(x: frame.midX, y: frame.midY)))
            }
            // Under the hand exactly, as a row is (see Carried).
            .transaction { if held { $0.animation = nil } }
            .zIndex(held ? 1 : 0)
            .shadow(color: .black.opacity(held ? 0.16 : 0), radius: 10, y: 3)
            // Measured in the grid's own space, not the square's: a square
            // that has just been moved to a new cell would otherwise report
            // the drag from where it now is, and shuttle between two cells.
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("pins"))
                    .updating($carrying) { _, carrying, _ in carrying = true }
                    .onChanged { value in
                        if !held {
                            held = true
                            from = index
                            CarryGuard.open(ticket, end: callOff)
                        }
                        travel = value.translation
                        if cross?(value.location) == true { return }
                        let target = PinCarried.target(travel: travel, from: from, cells: cells)
                        if target != index {
                            withAnimation(Motion.settle) { move(target) }
                        }
                    }
                    .onEnded { value in
                        guard CarryGuard.close(ticket) else { return }
                        _ = land?(value.location)
                        withAnimation(Motion.settle) {
                            held = false
                            travel = .zero
                        }
                    }
            )
            .onChange(of: carrying) { _, now in if !now { callOff() } }
    }

    /// Called off rather than let go: it stays in the cell it was last
    /// moved to, and nothing is dropped across.
    private func callOff() {
        CarryGuard.close(ticket)
        guard held else { return }
        _ = land?(nil)
        withAnimation(Motion.settle) {
            held = false
            travel = .zero
        }
    }

    /// The held square stays glued to the fingers; every other square is
    /// already where it belongs, because the move put it there. This only
    /// takes off what the held square got for free by changing cell under
    /// its own drag: as far as its centre is drawn `now`, which the spring
    /// to the new cell hasn't finished carrying yet.
    nonisolated static func offset(travel: CGSize, from: Int, cells: [CGRect], now: CGPoint) -> CGSize {
        guard cells.indices.contains(from) else { return .zero }
        let start = cells[from]
        return CGSize(width: travel.width - (now.x - start.midX), height: travel.height - (now.y - start.midY))
    }

    /// The cell the held square is over: the one whose centre is nearest to
    /// where the fingers have taken the square's own centre. Rows of
    /// different lengths have cells of different widths, so a count of
    /// steps along one axis would land in the wrong one.
    static func target(travel: CGSize, from: Int, cells: [CGRect]) -> Int {
        guard cells.indices.contains(from) else { return 0 }
        let start = cells[from]
        let point = CGPoint(x: start.midX + travel.width, y: start.midY + travel.height)
        func distance(_ cell: CGRect) -> CGFloat { hypot(cell.midX - point.x, cell.midY - point.y) }
        return cells.indices.min { distance(cells[$0]) < distance(cells[$1]) } ?? from
    }
}
