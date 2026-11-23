import SwiftUI

/// What was let go into a gap (Carried.placed): the row carried, the page
/// picked up with it — either half of a pair — and whether that half leaves
/// its pair, as it does once the pair has been shown letting go of it (see
/// TabDrag.separate); else the pair goes whole. Neither for a group carried
/// by its heading. `drawn`: the leading edge of what is carried, under the
/// hand, in the run's space; `point`, where the hand let go, in the same
/// space.
struct CarriedDrop {
    let row: Tab?
    let source: Tab?
    let detaching: Bool
    let drawn: CGFloat?
    let point: CGPoint
}

/// What a run of the column does for a tab carried over it (Carried.gap).
enum CarryGap {
    /// Nothing: it is along its own run, and moves as it goes.
    case none
    /// A gap is open for it in another run, and its own place closes: the
    /// row holds still where it is.
    case away
    /// Over another device's group, and it is kept here: sent there as
    /// well, a gap open in its group, or turned down by it, nothing open.
    /// The row goes back to where it was picked up.
    case copy
    /// It is over a run that won't take it: nothing opens, and it holds
    /// still where it is.
    case held
}

/// A tab picked up and carried along its run of the column, the others
/// making way as it passes them.
///
/// The hand's travel is the tab's own: every move of the pointer redraws the
/// one tab being carried, not the whole column around it (with the
/// neighbouring spaces drawn beside it, that was every row and every square
/// of three spaces, each frame, and the tab trailed behind the hand). The row
/// only redraws when the tab actually changes place.
struct Carried: ViewModifier {
    let index: Int
    /// Every place in the run, in its order now: each item's length and the
    /// gap after it. Not one length for all: a pair is two lines tall, and a
    /// tab carried past one moves by the pair's length, not its own. Worked
    /// out as one step for everything, the tab jumped a line away from the
    /// hand at each pair it passed, and changed places with it before
    /// reaching it.
    let steps: [CGFloat]
    /// The run's coordinate space, not the tab's: a tab that has just moved
    /// keeps its bearings (see the sidebar's grid).
    let space: String
    var groupDestination: ((Tab, CGPoint) -> GroupDropTarget?)? = nil
    /// Let go outside the window: true when the tab was taken elsewhere —
    /// another window, or a new one (see Browser.dragOut).
    var outside: (() -> Bool)? = nil
    var browser: Browser? = nil
    var tab: Tab? = nil
    /// Carried over another block that would take it — the pins, for a
    /// tab; the tabs, for a pinned row — at this point in the row's space:
    /// true while that block shows where it would land, and the row then
    /// holds its place rather than moving along its own.
    var cross: ((CGPoint) -> Bool)? = nil
    /// Let go (nil: the drag was called off): true when that block took it.
    var land: ((CGPoint?) -> Bool)? = nil
    /// Over that block: faint, so the place it opened shows through.
    var faded = false
    /// Told when the tab is picked up and when it is put down, called off
    /// or cancelled: the row it is carried along can show its tabs' shapes.
    var holding: ((Bool) -> Void)? = nil
    /// Asked at every move (nil: no longer anywhere the rows could open
    /// for it): whether a gap is open for it in another run — either area
    /// of the column, a group in either, another device (ColumnCarry) — and
    /// what is carried then holds still, or goes back to its place, rather
    /// than moving along its own. Given, it takes the place of the old rule
    /// that a tab of a group, or one over a group, only landed when let go.
    /// A group carried by its heading is asked too.
    var gap: ((CGPoint?) -> CarryGap)? = nil
    /// Let go: true when it went into the gap that was open for it.
    var placed: ((CarriedDrop) -> Bool)? = nil
    /// A pin, carried: the tab you were on before the press that brought it
    /// forward comes back once the carry is over (PressBack).
    var back: PressBack? = nil
    /// Asked at pick-up: what puts the column back as it stood then, true
    /// when it could. The places taken on the way are given back so (over
    /// another device, called off) rather than by moving this one back to
    /// where it was, which leaves the tabs picked with it, moved with it,
    /// where they went.
    var keep: (() -> () -> Bool)? = nil
    /// Down the column: kept within the scrolling column's view however far
    /// the hand goes. Carried past the last row, or above the first, it was
    /// drawn outside the view and cut off at its edge where it went. What is
    /// in view is read as it is drawn, so it follows the column scrolling or
    /// changing size under the carry.
    var keptInView = false
    let move: (Int) -> Void

    @State private var held = false
    @State private var from = 0
    /// Where in the row its leading edge was when it was picked up.
    @State private var start: CGFloat = 0
    @State private var travel: CGFloat = 0
    @State private var reordered = false
    /// Off the row, with the hand: faint here, and carried by TabLift.
    @State private var lifted = false
    /// Where it was drawn in `space` when it was picked up, read once by the
    /// held item alone, so the others measure nothing as the row scrolls.
    @State private var origin: CGFloat?
    /// How long it is drawn, as it was picked up: its place less the gap
    /// after it. Not its place now, which closes to nothing while a gap is
    /// open for it elsewhere (RowGapSource) although it is drawn whole, the
    /// gap as long as this.
    @State private var length: CGFloat = 0
    /// True while the drag lasts, and put back by SwiftUI when it is called
    /// off as well as when it ends (see CarryGuard).
    @GestureState private var carrying = false
    @State private var ticket = UUID()
    /// Cancelled with Escape: put down until the hand lets go, not picked
    /// up again by its next move.
    @State private var escaped = false
    /// The tab to go back to once the carry is over (`back`).
    @State private var backTo: Tab.ID?
    /// The column as it stood at pick-up (`keep`).
    @State private var kept: (() -> Bool)?

    func body(content: Content) -> some View {
        // What it has travelled, less the ground its new place has already
        // given it: until its origin is read, the frame after pick-up, before
        // it has gone anywhere.
        let shift = held ? travel - (Carried.leading(of: index, in: steps) - start) : 0
        return content
            // Always attached and asked only while held. A reader added under
            // the hand at pick-up changed the view and called the drag off
            // (RowCarryTests' pair carry failed 8 of 8, 2026-11-07).
            .onGeometryChange(for: CGFloat?.self, of: { [held, space] proxy in
                guard held else { return nil }
                return proxy.frame(in: .named(space)).minY
            }) { drawn in
                if origin == nil, let drawn { origin = drawn }
            }
            // Its place springs when it passes another tab, so the ground the
            // place has given it is where the place is drawn this frame, not
            // where the spring will end. Taken from the end, the tab fell a
            // place behind the hand at every tab it passed and drifted back.
            .visualEffect { [held, origin, travel, shift, space, keptInView, length] content, proxy in
                var moved = shift
                if held, let origin {
                    moved = origin + travel - proxy.frame(in: .named(space)).minY
                    // The scroll view's bounds in its own place's terms,
                    // where it starts at 0: what is in view now.
                    if keptInView, let view = proxy.bounds(of: .scrollView) {
                        moved = Carried.kept(moved, top: 0, length: length, within: view.minY...view.maxY)
                    }
                }
                return content.offset(y: moved)
            }
            // Under the hand exactly. Its place in the row springs when it
            // passes another tab, and the offset springs back the same way —
            // until the next move of the hand cuts the offset's spring short
            // and leaves the place's running: the tab jumped a whole slot and
            // drifted back each time it passed one. Only the others glide.
            .transaction { if held { $0.animation = nil } }
            .zIndex(held ? 1 : 0)
            .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
            .opacity(held && (faded || lifted) ? 0.4 : 1)
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(space))
                    .updating($carrying) { _, carrying, _ in carrying = true }
                    .onChanged { value in
                        if !held {
                            guard !escaped else { return }
                            held = true
                            from = index
                            start = Carried.leading(of: index, in: steps)
                            length = steps.indices.contains(index) ? max(0, steps[index] - SideBar.gap) : 0
                            origin = nil
                            backTo = back?.before()
                            kept = keep?()
                            CarryGuard.open(ticket, end: callOff, escape: escape)
                        }
                        travel = value.translation.height
                        // Asked every move, so the block it left lets go
                        // of it as soon as it is elsewhere.
                        let crossed = cross?(value.location) == true
                        var splitting = false
                        if let browser, let tab, browser.prefs.splitView {
                            splitting = TabDrag.shared.update(browser: browser, tab: tab,
                                                              translation: value.translation)
                        }
                        // After the update, which works out the half of a
                        // pair that was picked up.
                        lift(at: value.location)
                        // Asked on every move, a group's tab too, and off
                        // into the pins or the page: it is how the group
                        // under the pointer knows to light, and to stop.
                        let over = tab.flatMap { groupDestination?($0, value.location) }
                        if splitting || crossed {
                            _ = gap?(nil)
                            return
                        }
                        if let gap {
                            // Along its own run it moves as it goes; out of
                            // it, the run it is over opens a gap for it.
                            switch gap(value.location) {
                            case .none:
                                break
                            case .away, .held:
                                return
                            case .copy:
                                // Kept where it was: the places it took on
                                // the way given back, so it stays put.
                                if index != from || reordered { withAnimation(Motion.settle) { giveBack() } }
                                return
                            }
                        } else if let browser, let tab, browser.prefs.usesTabGroups, tab.pin == nil,
                                  browser.group(of: tab) != nil || over != nil {
                            // A tab of a group, or one over a group, lands
                            // where it is let go (see GroupDropFrames.resolve)
                            // rather than moving along the row as it goes.
                            return
                        }
                        let target = Carried.slot(at: start + travel, carrying: index, in: steps)
                        if target != index {
                            reordered = true
                            withAnimation(Motion.settle) { move(target) }
                        }
                    }
                    .onEnded { value in
                        escaped = false
                        TabLift.shared.put()
                        // Already put down (see callOff): a press that
                        // came after can't be where it was let go.
                        guard CarryGuard.close(ticket) else { return }
                        if let browser, let tab, browser.prefs.splitView {
                            // Asked while the drag still knows which half
                            // of a pair is carried: finishing forgets it.
                            if TabDrag.shared.cancelledID != tab.id { askOnceMore(at: value.location) }
                            let finished = TabDrag.shared.finish(browser: browser, tab: tab)
                            let source = finished.source
                            // Let go over the pins, or out of them: theirs,
                            // before anything else here.
                            let cancelled: Bool
                            if case .cancelled = finished.drop { cancelled = true } else { cancelled = false }
                            if land?(cancelled ? nil : value.location) != true {
                                switch finished.drop {
                                case .stage(let target, let onLeft):
                                    browser.pair(source, with: target, onLeft: onLeft)
                                case .strip(let target):
                                    // Into the gap open for it: where it was
                                    // shown it would go, the half shown
                                    // leaving its pair on its own.
                                    if placed?(CarriedDrop(row: tab, source: source, detaching: true,
                                                           drawn: origin.map { $0 + travel }, point: value.location)) == true { break }
                                    if let destination = groupDestination?(source, value.location) {
                                        // Along its own group it has moved as
                                        // it went (see `gap`): already there.
                                        if gap != nil, source === tab, destination.group == browser.group(of: source) { break }
                                        // Resolve before detaching: the old pair still owns its frame.
                                        browser.move(source, toGroup: destination, detaching: true)
                                    } else {
                                        browser.dropTabIntoStrip(source, before: target)
                                    }
                                case .outside:
                                    if placed?(CarriedDrop(row: tab, source: source, detaching: false,
                                                           drawn: origin.map { $0 + travel }, point: value.location)) == true { break }
                                    _ = browser.dragOut(source, at: finished.point)
                                case .cancelled:
                                    if reordered { giveBack() }
                                }
                            }
                        } else {
                            askOnceMore(at: value.location)
                            if land?(value.location) != true, outside?() != true {
                                _ = placed?(CarriedDrop(row: tab, source: tab, detaching: false,
                                                        drawn: origin.map { $0 + travel }, point: value.location))
                            }
                        }
                        // Told now, not only when `held` changes: the drop
                        // may have taken this row away, and that change with it.
                        holding?(false)
                        withAnimation(Motion.settle) {
                            held = false
                            travel = 0
                            reordered = false
                        }
                        goBack()
                    }
            )
            .onChange(of: carrying) { _, now in if !now { callOff() } }
            .onChange(of: held) { _, now in
                holding?(now)
                if !now { lifted = false }
            }
            // Its row gone with the button still down, by closing it or by
            // the drop itself: nothing here will hear the rest of the drag.
            .onDisappear { if lifted { TabLift.shared.put() } }
            .onReceive(TabDrag.shared.$cancelledID) { id in
                guard id == tab?.id, held else { return }
                escape()
            }
    }

    /// Called off with Escape (CarryGuard.escape), the button still down:
    /// back where it was picked up, nothing dropped anywhere, and put down
    /// until the hand lets go.
    private func escape() {
        CarryGuard.close(ticket)
        guard held else { return }
        escaped = true
        TabLift.shared.put()
        if let tab { TabDrag.shared.callOff(tab) }
        _ = land?(nil)
        if reordered { giveBack() }
        held = false
        travel = 0
        reordered = false
        goBack()
    }

    /// A pin's carry over, however it ended: back on the tab you were on.
    private func goBack() {
        kept = nil
        guard let id = backTo else { return }
        backTo = nil
        back?.go(to: id)
    }

    /// The offset that moves what is carried, `length` long and starting at
    /// `top`, by `moved`, kept within `within`: never past either end of
    /// what is in sight. Too long to fit, its top stays in sight.
    nonisolated static func kept(_ moved: CGFloat, top: CGFloat, length: CGFloat, within: ClosedRange<CGFloat>) -> CGFloat {
        let highest = within.lowerBound - top
        let lowest = within.upperBound - length - top
        return max(highest, min(moved, max(highest, lowest)))
    }

    /// Where the item at `index` starts in the row: the places before it.
    static func leading(of index: Int, in steps: [CGFloat]) -> CGFloat {
        steps.prefix(max(0, index)).reduce(0, +)
    }

    /// The place for the item at `index` with its leading edge at `edge`:
    /// past a neighbour once it has come half that neighbour's place, going
    /// either way. With every place the same, that is a move each half step,
    /// as it always was; a pair is passed at its middle, not after a tab's
    /// length.
    static func slot(at edge: CGFloat, carrying index: Int, in steps: [CGFloat]) -> Int {
        guard steps.indices.contains(index) else { return index }
        var others = steps
        others.remove(at: index)
        var slot = index
        var before = leading(of: slot, in: others)
        while slot < others.count, edge > before + others[slot] / 2 {
            before += others[slot]
            slot += 1
        }
        while slot > 0, edge < before - others[slot - 1] / 2 {
            slot -= 1
            before -= others[slot]
        }
        return slot
    }

    /// Let go: where, asked once more, as on every move, so what is done
    /// is what the place it was let go shows, even with no move there
    /// first: over the squares or off them, and over another device's
    /// group, the places it took on the way given back (CarryGap.copy).
    private func askOnceMore(at location: CGPoint) {
        if cross?(location) == true {
            _ = gap?(nil)
            return
        }
        guard gap?(location) == .copy, index != from || reordered else { return }
        withAnimation(Motion.settle) { giveBack() }
    }

    /// The places it took on the way given back: the column as it stood
    /// at pick-up, or else this one back where it was.
    private func giveBack() {
        if kept?() == true { return }
        if index != from { move(from) }
    }

    /// Off to the side of the row, with some slack for a hand that wanders,
    /// or out of the window, where letting go takes the tab away: it goes on
    /// with the pointer in a window of its own. A pin can't leave, so nothing
    /// says it could.
    private func lift(at location: CGPoint) {
        guard let browser, let tab else { return }
        let carried = TabDrag.shared.source(of: tab) ?? tab
        guard carried.pin == nil else { return }
        let slack: CGFloat = 8
        let point = TabDrag.shared.pointer(in: browser)
        // The column's rows are measured from 10 inside its edges.
        let off = browser.isPastEdge(point)
            || location.x < -10 - slack || location.x > browser.prefs.columnWidth - 10 + slack
        if off != lifted { lifted = off }
        if off {
            TabLift.shared.carry(carried, browser: browser, at: point)
        } else {
            TabLift.shared.put()
        }
    }

    /// The drag taken away without onEnded (see CarryGuard): put down where
    /// it is, nothing dropped across, the split it may have been showing
    /// let go of. After a real end, held is already false and this is nothing.
    private func callOff() {
        CarryGuard.close(ticket)
        escaped = false
        guard held else { return }
        TabLift.shared.put()
        if let browser, let tab, browser.prefs.splitView { TabDrag.shared.callOff(tab) }
        _ = land?(nil)
        withAnimation(Motion.settle) {
            held = false
            travel = 0
            reordered = false
        }
        goBack()
    }
}

/// A pin carried by hand, as a square or a row, and the tab you were on
/// before the press that picked it up. A pin comes to the front as the
/// button goes down on it (TabPress), before anything says whether the
/// press is a click or the start of a carry; carried somewhere — along the
/// pins, into a folder, across the line, onto another device — it was left
/// in front, and the page you had been reading went behind it. Once the
/// carry is over, that page comes back, as it does for a tab carried onto
/// its own page (TabDrag.bringBack). The pin's own page has been woken by
/// then: the press can't wait to know.
@MainActor
struct PressBack {
    let browser: Browser
    let pin: Tab

    /// At pick-up: the tab the press put behind the pin, if the press did.
    func before() -> Tab.ID? {
        guard pin.pin != nil else { return nil }
        return PressBack.before(pin, in: browser)
    }

    /// The carry over: back on `id`, while the pin it went behind is still
    /// the one in front and `id` still open.
    func go(to id: Tab.ID) {
        guard browser.visibleTabIDs.contains(pin.id), !browser.visibleTabIDs.contains(id),
              let tab = browser.tabs.first(where: { $0.id == id }) else { return }
        browser.select(tab)
    }

    /// The tab on screen before the press that just brought `tab` forward,
    /// if it is still open and no longer on screen. A press long ago, or
    /// one that opened nothing, gives nothing.
    static func before(_ tab: Tab, in browser: Browser) -> Tab.ID? {
        let now = ProcessInfo.processInfo.systemUptime
        guard let opened = TabPress.openedAt, now - opened < TabDrag.pressed,
              let came = browser.cameFrom, came.at >= opened, let before = came.id,
              browser.visibleTabIDs.contains(tab.id), !browser.visibleTabIDs.contains(before),
              browser.tabs.contains(where: { $0.id == before }) else { return nil }
        return before
    }
}

/// A tab or pin carried by hand (Carried, PinCarried) that never hears the
/// drag end (#846). SwiftUI calls a drag off, without a word to onEnded,
/// when what is drawn in the carried view changes under the hand: a square
/// whose page starts loading as the press that picks it up selects it (the
/// ring in place of its icon, a second or so in), or whose icon arrives.
/// The square kept its held state and stayed floating mid-drag, shadowed,
/// the block it was over still showing where it would land. Each carry now
/// ends twice over: when SwiftUI puts its @GestureState back, which it does
/// on a call-off too, and, should even that not come, at the next press of
/// the button anywhere in Eden, which can't go down again before the
/// carry it was holding is over. A row is carried the same way and guarded
/// the same way.
///
/// Escape, with the button still down, calls off every carry under way
/// (`escape`): a tab, a pinned row or square, a group by its heading. It
/// used to reach only a tab under the line with Split View on, through the
/// split's own watch for it (TabDrag); a pin, a row above the line and a
/// heading went on being carried.
@MainActor
enum CarryGuard {
    private struct Carry {
        let end: () -> Void
        let escape: () -> Void
    }

    private static var carries: [UUID: Carry] = [:]
    private static var monitor: Any?
    private static var keys: Any?

    /// Carries under way, for the tests.
    static var count: Int { carries.count }

    /// `escape`: what Escape does to it, its end if nothing is said.
    static func open(_ id: UUID, end: @escaping () -> Void, escape: (() -> Void)? = nil) {
        carries[id] = Carry(end: end, escape: escape ?? end)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { CarryGuard.endAll() }
            return event
        }
        // Only while the button is down: a carry SwiftUI took away without
        // a word stays open until the next press, and its watch must not
        // eat an Escape meant for something else, a video's full screen
        // among them, in the meantime.
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, NSEvent.pressedMouseButtons & 1 != 0 else { return event }
            return MainActor.assumeIsolated { CarryGuard.escape() } ? nil : event
        }
    }

    /// True when it was still open: not already ended here.
    @discardableResult
    static func close(_ id: UUID) -> Bool {
        guard carries.removeValue(forKey: id) != nil else { return false }
        if carries.isEmpty { stop() }
        return true
    }

    /// Every carry still open, ended where it is.
    static func endAll() {
        let stale = carries.values
        carries = [:]
        stop()
        for carry in stale { carry.end() }
    }

    /// Escape: every carry under way called off, each back where it was
    /// picked up and nothing dropped. True when there was one to call off.
    @discardableResult
    static func escape() -> Bool {
        guard !carries.isEmpty else { return false }
        let escaping = carries.values
        carries = [:]
        stop()
        for carry in escaping { carry.escape() }
        return true
    }

    private static func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }
}
