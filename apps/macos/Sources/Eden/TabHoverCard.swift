import AppKit
import Combine
import SwiftUI

// The card a tab in the column shows when the pointer rests on it (#4), a
// row, a pinned square or a tile alike: a picture of its page, its title and
// site, and the few things worth doing to it without going there. Copy its
// address, pin or unpin it, duplicate it; while it plays, or was paused from
// Eden, pause or play it and mute it.
//
// A group's heading shows one too: the four of its tabs you were in last as
// one picture, its name and how many tabs it holds, and what can be done to
// all of them. It is most of use folded, when its tabs can't be seen. A
// group above the line, a kept group (Column.swift), has the same card for
// its pins.
//
// The picture is taken once, as the card comes up, not kept live: a page out
// of sight is drawn by its own process only when asked, and asking on every
// frame would cost the battery for a thumbnail. A sleeping tab shows the
// picture it keeps for waking, and one brought back from last time the one
// kept on disk as it was last left (Tab.keepPicture).
//
// It waits for the pointer to rest, so running down the column flashes
// nothing, and once up it follows the pointer from tab to tab without waiting
// again. It never takes the keys, so the pointer can go over to it and use
// its buttons. On its way there the pointer may cross other tabs; while it
// heads for the card, inside the cone from where it is to the card's near
// edge, as a menu's submenu waits for it, the card stays the tab's it came
// from. A press anywhere else, a scroll or a key puts it away: a press on a
// tab is a click or the start of a drag, and the card would only be in the
// way of either.
//
// Turning from one tab to the next, it is one card that moves, not one card
// going and another coming: its frame glides to the new tab on a spring and
// takes the new content's height, while the content trails it at a quarter of
// its pace, the old fading out and the new in, clipped by the frame as it
// passes over them, as a window passes over a page behind it. For that the
// card's window is a tall strip beside the column, clear but for the card,
// and all of it moves in SwiftUI, in one animation, rather than a window
// being moved, which can't take the content one way and the frame another.
// The strip lets the pointer through to the page everywhere but on the card.

@MainActor
enum TabHoverCard {
    /// Where a tab's line or square is in its window, as SwiftUI last laid it
    /// out: kept in a box so a scroll moving it draws nothing.
    final class Spot {
        var frame: CGRect = .zero
    }

    /// What a card is of: a tab, or a group in either area, by its heading.
    enum Subject {
        case tab(Tab)
        case group(UUID)

        var key: Key {
            switch self {
            case .tab(let tab): return .tab(tab.id)
            case .group(let id): return .group(id)
            }
        }
    }

    /// Which card: a layer's, the wait for one, the line under the pointer.
    enum Key: Hashable {
        case tab(Tab.ID)
        case group(UUID)
    }

    /// How long the pointer rests on a tab before its card comes up.
    private static let rest: TimeInterval = 0.5
    /// How long the pointer, heading for the card, may stop before it is
    /// taken to have stopped there: on another tab, the card turns to it;
    /// anywhere else it goes.
    private static let settle: TimeInterval = 0.25
    /// How often the pointer is looked at while a card is up.
    private static let tick: TimeInterval = 0.016
    /// How far past the card's top and foot the cone reaches, for a hand
    /// that doesn't quite aim.
    private static let slack: CGFloat = 24
    /// How long the card waits, once nothing holds it, for the pointer to
    /// come onto it or another tab, as through the gap between two lines.
    private static let linger: TimeInterval = 0.15
    /// Gone for less than this, the next tab's card comes up at once: the
    /// pointer was only passing from one tab to the next by way of a gap.
    private static let warm: TimeInterval = 0.4
    /// The card's width.
    static let width: CGFloat = 260
    /// The room left round the card for its shadow, and kept from the
    /// screen's top and foot.
    fileprivate static let margin: CGFloat = 8
    /// Between the column's edge and the card.
    private static let gap: CGFloat = 4
    /// The frame's glide from one tab to the next, and its height's.
    fileprivate static let glide = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// Coming up and going.
    private static let fade = Animation.easeOut(duration: 0.14)

    private static let model = Model()
    private static var panel: Panel?
    /// A card going: put away once its fade is done, unless one comes back
    /// first and takes the same window up again.
    private static var closing: Task<Void, Never>?
    /// The cards no longer shown, let go of once they have faded.
    private static var pruning: Task<Void, Never>?
    /// A card on its way: the tab it is for, and the wait.
    private static var pending: (key: Key, wait: Task<Void, Never>)?
    /// The tab under the pointer: set as the pointer comes onto a tab and
    /// cleared as it leaves that same one, so it holds whichever order the
    /// two arrive in from neighbouring lines.
    private static var under: Under?
    /// The pointer, watched while a card is up (see follow).
    private static var following: Task<Void, Never>?
    private static var hiddenAt: Date = .distantPast
    private static var watching = false

    /// Up, and not on its way out.
    static var isShown: Bool { panel != nil && closing == nil }

    // MARK: - when

    /// The pointer came onto a tab's line or square, or a group's heading,
    /// laid out at `spot`. With a card up, follow decides what that means.
    static func enter(_ subject: Subject, in browser: Browser, at spot: Spot) {
        watch()
        let target = Under(subject, browser: browser, spot: spot)
        under = target
        cancelPending()
        // Only in the window you are using, with no button held: a button
        // held is a tab being carried across the column.
        guard NSApp.isActive, browser.window?.isKeyWindow == true,
              NSEvent.pressedMouseButtons == 0, worthACard(subject, in: browser) else {
            hide()
            return
        }
        guard !isShown else { return }
        let warmed = Date().timeIntervalSince(hiddenAt) < warm
        guard !warmed else { return show(subject, in: browser, at: spot.frame) }
        pending = (subject.key, Task {
            try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000))
            guard !Task.isCancelled else { return }
            pending = nil
            guard let subject = target.subject, let browser = target.browser else { return }
            show(subject, in: browser, at: spot.frame)
        })
    }

    /// A blank tab has nothing to show, nor a group with no tabs.
    private static func worthACard(_ subject: Subject, in browser: Browser) -> Bool {
        switch subject {
        case .tab(let tab): return !tab.isBlank
        case .group(let id): return !browser.members(ofGroup: id).isEmpty || !browser.heldRows(ofGroup: id).isEmpty
        }
    }

    /// The pointer left a tab or a heading: a card on its way for it doesn't
    /// come.
    static func leave(_ subject: Subject) {
        if pending?.key == subject.key { cancelPending() }
        if under?.subject?.key == subject.key { under = nil }
    }

    /// A tab's line or square, or a heading, went: closed, scrolled away, or
    /// in another space now.
    static func gone(_ subject: Subject) {
        leave(subject)
        if model.current == subject.key {
            hide()
        } else {
            model.layers.removeAll { $0.id == subject.key }
        }
    }

    /// While a card is up, where the pointer is decides, sixty times a
    /// second, rather than the order the lines and the card say they were
    /// entered and left in, which can come either way round. On the card or
    /// on its tab, nothing changes. Elsewhere, for as long as each step
    /// stays inside the cone from where the pointer was to the card's near
    /// edge, it is on its way to the card, and the tabs it crosses are
    /// passed by. Once a step leaves the cone, or the pointer stops, it has
    /// gone somewhere else: the card turns to the tab it is on, or, with
    /// none, goes after a moment. The strip around the card lets the pointer
    /// through, and only the card takes it.
    private static func follow() {
        following?.cancel()
        following = Task {
            var last = NSEvent.mouseLocation
            var still: TimeInterval = 0
            var away: TimeInterval = 0
            var towards = false
            while true {
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                guard !Task.isCancelled, let panel, let card = model.current else { return }
                let now = NSEvent.mouseLocation
                let face = onScreen(model.displayed.rect, in: panel)
                let over = face.contains(now)
                if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
                if now == last {
                    still += tick
                    if still >= settle { towards = false }
                } else {
                    still = 0
                    towards = heading(from: last, to: now, card: face)
                }
                last = now
                if over || under?.subject?.key == card || towards {
                    away = 0
                } else if let under, let subject = under.subject, let browser = under.browser {
                    away = 0
                    show(subject, in: browser, at: under.spot.frame)
                    // Not laid out where the card can stand by it: as no tab.
                    if model.current != subject.key { self.under = nil }
                } else {
                    away += tick
                    if away >= linger { return hide() }
                }
            }
        }
    }

    /// Whether the step from `from` to `to` keeps inside the triangle from
    /// `from` to the card's near edge, its corners stretched by `slack`.
    private static func heading(from: NSPoint, to: NSPoint, card: NSRect) -> Bool {
        let x = from.x < card.midX ? card.minX : card.maxX
        // On the edge already, the cone is a line: a step along it, up or
        // down past the card, is no step towards it.
        guard abs(x - from.x) >= 1 else { return false }
        let top = NSPoint(x: x, y: card.maxY + slack)
        let foot = NSPoint(x: x, y: card.minY - slack)
        func side(_ a: NSPoint, _ b: NSPoint, _ p: NSPoint) -> CGFloat {
            (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        }
        let sides = [side(from, top, to), side(top, foot, to), side(foot, from, to)]
        return sides.allSatisfy { $0 >= 0 } || sides.allSatisfy { $0 <= 0 }
    }

    private static func cancelPending() {
        pending?.wait.cancel()
        pending = nil
    }

    /// A press anywhere but the card, a scroll, a key (⌘ or ⇧ alone too, on
    /// its way to a click that picks tabs) or Eden left puts the card away,
    /// and one still on its way doesn't come. Watched from the first card
    /// on, for as long as Eden runs: each event only finds nothing to do.
    private static func watch() {
        guard !watching else { return }
        watching = true
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .flagsChanged, .swipe]) { event in
            MainActor.assumeIsolated {
                guard isShown || pending != nil else { return }
                // A press on the card is for its buttons; a scroll or a key
                // over it puts it away as anywhere else.
                let press = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
                if press, let panel, event.window === panel { return }
                hide()
            }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hide() }
        }
    }

    // MARK: - the window

    private static func show(_ subject: Subject, in browser: Browser, at frame: CGRect) {
        guard let window = browser.window, window.isVisible, let content = window.contentView,
              frame != .zero, browser.columnFrame != .zero else { return }
        // A card still up in another window is that window's.
        if let panel, panel.parent !== window { putAway() }

        // The tab's line and the column, from SwiftUI's top-left points to
        // the screen's; the strip the card moves in, beside the column, the
        // screen's height.
        let row = window.convertToScreen(content.convert(flip(frame, in: content), to: nil))
        let column = window.convertToScreen(content.convert(flip(browser.columnFrame, in: content), to: nil))
        let onRight = browser.prefs.sidePosition == .right
        let outer = width + margin * 2
        let screen = window.screen?.visibleFrame ?? window.frame
        var x = onRight ? column.minX - gap - outer + margin : column.maxX + gap - margin
        x = min(max(x, screen.minX), screen.maxX - outer)
        let strip = NSRect(x: x, y: screen.minY, width: outer, height: screen.height)
        let top = strip.maxY - row.maxY

        model.browser = browser
        model.onRight = onRight
        model.stripHeight = strip.height

        if let panel {
            if panel.frame != strip { panel.setFrame(strip, display: true) }
            if closing != nil {
                // Coming back as it went: the same card, from where it is.
                closing?.cancel()
                closing = nil
                withAnimation(fade) { model.shown = true }
                follow()
            }
            turn(to: subject, in: browser, top: top)
            return
        }

        var first = layer(for: subject, in: browser, top: top)
        // Its fade is the card's own, coming up.
        first.lit = true
        model.layers = [first]
        model.current = subject.key
        let host = Host(rootView: Strip(model: model))
        // The strip is the size it is given, and the host never sizes its
        // window: as the window's own content it did, asking again on every
        // pass as the card measured its layers, until AppKit, out of passes,
        // threw. Inside a plain view, it is only a view.
        host.sizingOptions = []
        let holder = NSView(frame: NSRect(origin: .zero, size: strip.size))
        host.frame = holder.bounds
        host.autoresizingMask = [.width, .height]
        holder.addSubview(host)
        let panel = Panel(contentRect: strip, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = holder
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        // Through to the page until the pointer is on the card (follow).
        panel.ignoresMouseEvents = true
        panel.appearance = window.effectiveAppearance
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        // In once it has been laid out at its tab, its height measured.
        DispatchQueue.main.async {
            guard self.panel === panel, closing == nil else { return }
            if Motion.reduced { model.shown = true } else { withAnimation(fade) { model.shown = true } }
        }
        follow()
    }

    /// The card, up already, turned to `subject`, whose line's top is `top`
    /// points down the strip.
    private static func turn(to subject: Subject, in browser: Browser, top: CGFloat) {
        let key = subject.key
        guard model.current != key || model.layers.first(where: { $0.id == key })?.top != top else { return }
        var made = layer(for: subject, in: browser, top: top)
        // A layer new to the card is inserted lit, its fade its insertion's.
        made.lit = true
        let change = {
            if let index = model.layers.firstIndex(where: { $0.id == key }) {
                model.layers[index].top = top
            } else {
                model.layers.append(made)
                // A sweep down the column: only the last few still fading.
                if model.layers.count > 4 { model.layers.removeFirst(model.layers.count - 4) }
            }
            model.current = key
        }
        // With Reduce animations, at once, as every move is.
        if Motion.reduced {
            change()
            for index in model.layers.indices { model.layers[index].lit = model.layers[index].id == key }
        } else {
            withAnimation(glide, change)
            light(key)
        }
        prune()
    }

    /// The new layer's fade in, as the old one's fade out: a hair behind it,
    /// so two titles are hardly read over each other, and never an empty
    /// card between them.
    fileprivate static let entrance = Animation.easeOut(duration: 0.2).delay(0.02)
    private static let exit = Animation.easeOut(duration: 0.14)

    /// The layer in front lit and the others out, the old gone quickly. One
    /// just added came in lit, and fades in as it is inserted (CardFrame).
    private static func light(_ id: Key) {
        withAnimation(exit) {
            for index in model.layers.indices where model.layers[index].id != id && model.layers[index].lit {
                model.layers[index].lit = false
            }
        }
        guard let index = model.layers.firstIndex(where: { $0.id == id }), !model.layers[index].lit else { return }
        withAnimation(entrance) { model.layers[index].lit = true }
    }

    /// A new layer for `subject`, the pictures it shows asked for: a tab's
    /// own if it has one to give, a group's for each of its collage's tabs.
    private static func layer(for subject: Subject, in browser: Browser, top: CGFloat) -> Layer {
        if let kept = model.layers.first(where: { $0.id == subject.key }) {
            var layer = kept
            layer.top = top
            return layer
        }
        let members: [Tab]
        let wantsPicture: Bool
        switch subject {
        case .tab(let tab):
            members = [tab]
            wantsPicture = tab.hasPreview
        case .group(let id):
            members = collage(id, in: browser)
            // Its collage stands whatever it has: a tab with no picture
            // shows its icon there.
            wantsPicture = true
        }
        var layer = Layer(subject: subject, top: top, wantsPicture: wantsPicture)
        ask(members, into: &layer)
        return layer
    }

    /// Pictures for `tabs` not yet asked for in `layer`: each tab's once.
    private static func ask(_ tabs: [Tab], into layer: inout Layer) {
        for tab in tabs where !layer.asked.contains(tab.id) {
            layer.asked.insert(tab.id)
            if tab.hasPreview { takePicture(of: tab, for: layer.request) }
        }
    }

    /// A group's collage changed as its tabs did: one closed or moved out
    /// leaves its place to the next, whose picture is asked for here.
    fileprivate static func showing(_ tabs: [Tab], for key: Key) {
        guard let index = model.layers.firstIndex(where: { $0.id == key }) else { return }
        ask(tabs, into: &model.layers[index])
    }

    /// A group's tabs for its collage: the four you were in last, the one on
    /// screen first. What you were doing in the group is what its card
    /// shows, not whichever tabs happen to be at its top.
    fileprivate static func recent(_ tabs: [Tab], in browser: Browser) -> [Tab] {
        let shown = browser.visibleTabIDs
        let ordered = tabs.sorted { a, b in
            let aShown = shown.contains(a.id), bShown = shown.contains(b.id)
            if aShown != bShown { return aShown }
            return a.touched > b.touched
        }
        return Array(ordered.prefix(4))
    }

    /// A group's collage, as `recent`, with a folder's rows held as data
    /// (HeldPins.swift) among its tabs by when each was last looked at, as
    /// stand-ins (Browser.standIns); those never looked at last, in order.
    fileprivate static func collage(_ id: UUID, in browser: Browser) -> [Tab] {
        struct Part {
            let front: Bool
            let at: Date
            let tab: Tab?
            let pin: UUID?
        }
        let shown = browser.visibleTabIDs
        let tabs = browser.members(ofGroup: id).map { Part(front: shown.contains($0.id), at: $0.touched, tab: $0, pin: nil) }
        let rows = browser.heldRows(ofGroup: id)
        let held = rows.map { Part(front: false, at: browser.lookedAt(heldPin: $0.id) ?? .distantPast, tab: nil, pin: $0.id) }
        let picked = (tabs + held).enumerated().sorted { a, b in
            if a.element.front != b.element.front { return a.element.front }
            if a.element.at != b.element.at { return a.element.at > b.element.at }
            return a.offset < b.offset
        }.prefix(4).map(\.element)
        let wanted = Set(picked.compactMap(\.pin))
        let standIns = browser.standIns(for: rows.filter { wanted.contains($0.id) })
        return picked.compactMap { part in part.tab ?? standIns.first { $0.pinID == part.pin } }
    }

    /// The cards the frame has left, once they have faded.
    private static func prune() {
        pruning?.cancel()
        pruning = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            model.layers.removeAll { $0.id != model.current }
        }
    }

    /// The card, as laid out in the strip, on the screen.
    private static func onScreen(_ card: CGRect, in panel: NSPanel) -> NSRect {
        NSRect(x: panel.frame.minX + card.minX, y: panel.frame.maxY - card.maxY, width: card.width, height: card.height)
    }

    /// SwiftUI's top-down points as the content view counts them.
    private static func flip(_ rect: CGRect, in view: NSView) -> NSRect {
        view.isFlipped ? rect : NSRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The card goes, fading back towards the column, and its window with it
    /// once the fade is done; at once with Reduce Motion.
    static func hide() {
        cancelPending()
        following?.cancel()
        following = nil
        guard let panel, closing == nil else { return }
        hiddenAt = Date()
        panel.ignoresMouseEvents = true
        guard !Motion.reduced else { return putAway() }
        withAnimation(fade) { model.shown = false }
        closing = Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            putAway()
        }
    }

    /// The window gone, and everything it showed.
    private static func putAway() {
        closing?.cancel()
        closing = nil
        pruning?.cancel()
        pruning = nil
        following?.cancel()
        following = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        model.layers = []
        model.current = nil
        model.heights = [:]
        model.displayed.rect = .zero
        model.shown = false
        model.browser = nil
        hiddenAt = Date()
    }

    // MARK: - the picture

    /// Only into the layer it was taken for: one for the same tab or group,
    /// let go of and made again before the picture came, asks for its own.
    private static func takePicture(of tab: Tab, for request: UUID) {
        let id = tab.id
        tab.preview(width: HoverCard.pictureWidth) { image in
            guard let index = model.layers.firstIndex(where: { $0.request == request }) else { return }
            if Motion.reduced {
                model.layers[index].pictures[id] = image
            } else {
                withAnimation(.easeOut(duration: 0.18)) { model.layers[index].pictures[id] = image }
            }
        }
    }

    // MARK: -

    /// The tab or heading under the pointer, and where it is: the tab held
    /// weakly, so one closed meanwhile is no one's.
    private struct Under {
        weak var tab: Tab?
        /// A group's or a folder's heading: never a tab, held weakly above.
        let heading: Subject?
        weak var browser: Browser?
        let spot: Spot

        init(_ subject: Subject, browser: Browser, spot: Spot) {
            if case .tab(let tab) = subject {
                self.tab = tab
                heading = nil
            } else {
                tab = nil
                heading = subject
            }
            self.browser = browser
            self.spot = spot
        }

        var subject: Subject? {
            if let tab { return .tab(tab) }
            return heading
        }
    }

    /// One tab's or group's content in the card: the one shown, or one
    /// fading out.
    fileprivate struct Layer: Identifiable {
        let subject: Subject
        /// Where its line's top is, in points down the strip.
        var top: CGFloat
        let wantsPicture: Bool
        var pictures: [Tab.ID: NSImage] = [:]
        /// The tabs whose pictures have been asked for.
        var asked: Set<Tab.ID> = []
        /// Seen: the layer in front once it has faded in, and none of the
        /// others once they have faded out.
        var lit = false
        /// Its own, for its pictures to find it.
        let request = UUID()

        var id: Key { subject.key }

        init(subject: Subject, top: CGFloat, wantsPicture: Bool) {
            self.subject = subject
            self.top = top
            self.wantsPicture = wantsPicture
        }
    }

    /// What the strip shows: the card's layers, which of them is in front,
    /// and where the frame stands for it.
    @MainActor
    fileprivate final class Model: ObservableObject {
        @Published var layers: [Layer] = []
        @Published var current: Key?
        /// Each layer's height, as it laid itself out.
        @Published var heights: [Key: CGFloat] = [:]
        /// In, or on its way out.
        @Published var shown = false
        var stripHeight: CGFloat = 0
        var onRight = false
        weak var browser: Browser?

        /// How far behind the frame the content goes: a quarter of its pace.
        static let trail: CGFloat = 0.75

        /// Where a layer's frame would stand: at its line's top, kept on the
        /// screen by as much as its height asks.
        func home(_ layer: Layer) -> CGFloat {
            let height = heights[layer.id] ?? 0
            let lowest = stripHeight - height - TabHoverCard.margin
            return max(TabHoverCard.margin, min(layer.top, lowest))
        }

        /// The card's frame in the strip: where the layer in front stands,
        /// as tall as it is.
        var cardRect: CGRect {
            guard let layer = layers.first(where: { $0.id == current }) else { return .zero }
            return CGRect(x: TabHoverCard.margin, y: home(layer), width: TabHoverCard.width, height: heights[layer.id] ?? 0)
        }

        /// Where the frame is on screen as it glides, in the strip, for the
        /// pointer to be tested against and the cone to aim at: where it is,
        /// not where it is going (CardFrame).
        let displayed = Displayed()

        /// A layer's place inside the frame standing at `top`: trailing the
        /// frame, so on the screen each layer moves a quarter of the frame's
        /// way. The one the frame has left drifts on as it fades; the one it
        /// goes to comes from as far back and settles as the frame arrives.
        func trail(of layer: Layer, from top: CGFloat) -> CGFloat {
            Motion.reduced ? 0 : Self.trail * (home(layer) - top)
        }

        /// A layer's height as it laid itself out: the frame takes it on
        /// the same spring as its glide, once the card is in.
        func measured(_ measured: CGFloat, for id: Key) {
            // To the point: a fraction coming and going is no change.
            let height = measured.rounded()
            guard heights[id] != height else { return }
            if shown, !Motion.reduced {
                withAnimation(TabHoverCard.glide) { heights[id] = height }
            } else {
                heights[id] = height
            }
        }
    }

    /// A place written as the frame is drawn, read by the pointer's loop:
    /// not published, since nothing is drawn from it.
    fileprivate final class Displayed {
        var rect: CGRect = .zero
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Takes the first click though its window never becomes key.
    private final class Host: NSHostingView<Strip> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

extension View {
    /// The card for `tab` when the pointer rests here (TabHoverCard). Off
    /// while `enabled` is false, without changing what the view is, so the
    /// line keeps its own state as it turns on and off.
    func tabHoverCard(_ tab: Tab, in browser: Browser, enabled: Bool) -> some View {
        modifier(HoverCardSource(browser: browser, subject: .tab(tab), enabled: enabled))
    }

    /// The card for a group, in either area, when the pointer rests on its
    /// heading.
    func groupHoverCard(_ group: TabGroup, in browser: Browser, enabled: Bool) -> some View {
        modifier(HoverCardSource(browser: browser, subject: .group(group.id), enabled: enabled))
    }
}

private struct HoverCardSource: ViewModifier {
    let browser: Browser
    let subject: TabHoverCard.Subject
    let enabled: Bool
    @State private var spot = TabHoverCard.Spot()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                spot.frame = frame
            }
            .onHover { over in
                if over, enabled {
                    TabHoverCard.enter(subject, in: browser, at: spot)
                } else {
                    TabHoverCard.leave(subject)
                }
            }
            .onDisappear { TabHoverCard.gone(subject) }
    }
}

// MARK: - the card

/// The strip beside the column, clear but for the card.
private struct Strip: View {
    @ObservedObject var model: TabHoverCard.Model

    var body: some View {
        let card = model.cardRect
        ZStack(alignment: .topLeading) {
            if let browser = model.browser, model.current != nil {
                CardFrame(model: model, browser: browser, top: card.minY, height: card.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The card's frame, drawn afresh on each step of its glide where it is
/// then: every layer inside it is placed from that, not from where the frame
/// is going, so the trailing holds all the way and through a turn to another
/// tab halfway, and the pointer is tested against where the card is seen.
private struct CardFrame: View, Animatable {
    @ObservedObject var model: TabHoverCard.Model
    let browser: Browser
    var top: CGFloat
    var height: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, height) }
        set {
            top = newValue.first
            height = newValue.second
        }
    }

    var body: some View {
        // Where it is seen, for the pointer's loop (TabHoverCard.follow).
        let _ = model.displayed.rect = CGRect(x: TabHoverCard.margin, y: top, width: TabHoverCard.width, height: height)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack(alignment: .top) {
            ForEach(model.layers) { layer in
                content(of: layer)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                        model.measured(height, for: layer.id)
                    }
                    .opacity(layer.lit ? 1 : 0)
                    .offset(y: model.trail(of: layer, from: top))
                    .allowsHitTesting(layer.id == model.current)
                    // A layer new to the card fades in as it is inserted; its
                    // going is its fade out, before it is pruned.
                    .transition(Motion.reduced ? .identity
                                : .asymmetric(insertion: .opacity.animation(TabHoverCard.entrance), removal: .identity))
            }
        }
        .frame(width: TabHoverCard.width, height: height, alignment: .top)
        .background(Palette.ground)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        // In from the column's side, and back towards it going.
        .scaleEffect(model.shown ? 1 : 0.97, anchor: model.onRight ? .trailing : .leading)
        .opacity(model.shown ? 1 : 0)
        .offset(x: TabHoverCard.margin, y: top)
    }

    @ViewBuilder
    private func content(of layer: TabHoverCard.Layer) -> some View {
        switch layer.subject {
        case .tab(let tab):
            HoverCard(browser: browser, tab: tab, picture: layer.pictures[tab.id], wantsPicture: layer.wantsPicture)
        case .group:
            GroupCard(browser: browser, subject: layer.subject, pictures: layer.pictures)
        }
    }
}

/// One tab's content: picture, title, site and buttons.
private struct HoverCard: View {
    static let pictureWidth = TabHoverCard.width - 16

    let browser: Browser
    @ObservedObject var tab: Tab
    let picture: NSImage?
    let wantsPicture: Bool

    @ObservedObject private var prefs = Shared.prefs
    @State private var copied = false

    /// The card's own padding, round the picture, which sits nearest.
    static let padding: CGFloat = 8
    static let button: CGFloat = 28
    static let glyph: CGFloat = 13
    /// How far the text and the buttons' symbols are from the card's sides:
    /// as far as the symbols are from its foot, their squares taking them
    /// in from the padding, so the corners at the foot are even.
    static let inset: CGFloat = padding + (button - glyph) / 2

    /// The site, for a web page; Eden's own pages have only their title.
    private var site: String? {
        guard tab.isWeb, let url = tab.pageAddress else { return nil }
        return SiteCard.site(url)
    }

    /// Pinned: it can be unpinned. Not pinned: only a web page that keeps
    /// its history can be, as its menu has it.
    private var pinnable: Bool { tab.pin != nil || (tab.isWeb && !tab.shy) }
    /// Playing, or paused from Eden and to be played from here again.
    private var playing: Bool { tab.noisy || tab.stilled }
    /// Beside the title: what the page in front warns of, and whether the
    /// tab keeps no history or is being recorded. Its sound is in its
    /// buttons.
    private var notes: String? {
        var notes: [String] = []
        if browser.activeID == tab.id, let warning = AtRest.warning(tab.restAddress) { notes.append(warning.text) }
        if tab.shy { notes.append("Private") }
        if tab.recording { notes.append("Recording") }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if wantsPicture {
                    TabPicture(image: picture, tab: tab, glyph: prefs.glyph,
                               width: Self.pictureWidth, height: Self.pictureWidth * TabPicture.ratio)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        // The site's icon on the page's top corner, on a
                        // chip of the card's ground so it reads over any page.
                        .overlay(alignment: .topLeading) {
                            mark
                                .padding(4)
                                .background(Palette.ground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .padding(6)
                        }
                }
                HStack(alignment: .top, spacing: 8) {
                    // With no picture to wear it, the icon stands by the title.
                    if !wantsPicture { mark }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tab.label)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let site {
                            Text(site)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let notes {
                            Text(notes)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                // In from the picture's edge, as far as the buttons' symbols
                // are from the card's sides and foot.
                .padding(.horizontal, Self.inset - Self.padding)
            }
            .contentShape(Rectangle())
            // The card stands for the tab: a click on it goes there.
            .onTapGesture {
                browser.select(tab)
                TabHoverCard.hide()
            }

            let controls = self.controls
            if !controls.isEmpty { CardControls(controls: controls) }
        }
        .padding(Self.padding)
        .frame(width: TabHoverCard.width, alignment: .leading)
        .animation(Motion.quick, value: playing)
        .animation(Motion.quick, value: tab.muted)
        .task(id: copied) {
            // The tick says it is done, then the button is a button again.
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }

    private var mark: some View {
        Mark(icon: prefs.glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: 18)
    }

    /// The tab's own few things, then its sound: the tab menu's actions
    /// (Browser's one set of tab actions), on this tab alone, picked or not,
    /// as the card is about it. Its copy shows a tick in place of the toast
    /// the menu's says.
    private var controls: [CardControl] {
        var controls: [CardControl] = []
        if tab.address != nil {
            controls.append(CardControl(id: "copy", symbol: copied ? "checkmark" : "link", help: "Copy Address") {
                browser.copyAddresses(of: [tab], quietly: true)
                copied = true
            })
            controls.append(CardControl(id: "duplicate", symbol: "plus.square.on.square", help: "Duplicate") {
                browser.duplicate([tab])
                TabHoverCard.hide()
            })
        }
        if pinnable {
            controls.append(CardControl(id: "pin", symbol: tab.pin == nil ? "pin" : "pin.slash",
                                    help: tab.pin == nil ? "Pin" : "Unpin") {
                if tab.pin == nil { browser.pin([tab], listed: false) } else { browser.unpin([tab]) }
                TabHoverCard.hide()
            })
        }
        if playing {
            controls.append(CardControl(id: "play", symbol: tab.stilled ? "play.fill" : "pause.fill",
                                    help: tab.stilled ? "Play" : "Pause") {
                if tab.stilled { tab.playAgain() } else { tab.still() }
            })
        }
        if playing || tab.muted {
            controls.append(CardControl(id: "mute", symbol: tab.muted ? "speaker.slash" : "speaker.wave.2",
                                    help: tab.muted ? "Unmute Tab" : "Mute Tab") {
                browser.mute([tab], !tab.muted)
            })
        }
        return controls
    }
}

/// One of a card's buttons. Its id is what it does, so one coming or going
/// (the sound's, as a page plays) fades on its own.
private struct CardControl {
    let id: String
    let symbol: String
    let help: String
    let act: () -> Void
}

/// A card's buttons, spread across it, the first and last symbols in line
/// with its text.
private struct CardControls: View {
    let controls: [CardControl]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(controls.enumerated()), id: \.element.id) { index, control in
                if index > 0 { Spacer(minLength: 0) }
                SquareButton(symbol: control.symbol, help: control.help, glyph: HoverCard.glyph, size: HoverCard.button, act: control.act)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - a group's card

/// A group's content, by its heading: the tabs you were in last as one
/// picture, its name and how many tabs it holds, and what can be done to
/// all of them. No Close Group: on a card that comes up under the pointer it
/// would be too near a slip, and the heading's own cross and menu have it.
/// A kept group's, above the line (Column.swift), is the same for its
/// pins, less Duplicate, which pins don't do.
private struct GroupCard: View {
    @ObservedObject var browser: Browser
    /// A group's or a folder's.
    let subject: TabHoverCard.Subject
    let pictures: [Tab.ID: NSImage]

    @ObservedObject private var prefs = Shared.prefs
    /// Its tabs' own changes, their sound among them, which the browser
    /// doesn't hear of.
    @StateObject private var tabsChanging = TabsChanging()
    @State private var copied = false

    var body: some View {
        if let found {
            card(found)
        }
    }

    /// The group as it is now, in either area.
    private var found: TabGroup? {
        switch subject {
        case .tab: nil
        case .group(let id): browser.columnGroup(id)
        }
    }

    /// Above the line: a kept group (Column.swift), whose tabs are pins.
    private var kept: Bool {
        guard case .group(let id) = subject else { return false }
        return browser.area(ofGroup: id) == .kept
    }

    private var counted: (one: String, many: String) {
        kept ? ("pin", "pins") : ("tab", "tabs")
    }

    private func card(_ found: TabGroup) -> some View {
        let tabs = browser.members(ofGroup: found.id)
        // Its rows held as data count as much as its tabs (HeldPins.swift).
        let total = tabs.count + browser.heldRows(ofGroup: found.id).count
        // Worked out as it is drawn: a tab closed or moved out leaves its
        // place to the next you were in.
        let shown = TabHoverCard.collage(found.id, in: browser)
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Collage(tabs: shown, pictures: pictures, glyph: prefs.glyph) { tab in
                    if let tab = browser.rowTab(for: tab) { browser.select(tab) }
                    TabHoverCard.hide()
                }
                .overlay(alignment: .topLeading) {
                    GroupIcons(tabs: shown, total: total, colour: found.colour, glyph: prefs.glyph)
                        .padding(6)
                        .allowsHitTesting(false)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(found.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(total == 1 ? "1 \(counted.one)" : "\(total) \(counted.many)")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, HoverCard.inset - HoverCard.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // The card stands for the group: a click on it opens it, at
                // the tab you were in last.
                .onTapGesture { open(found, at: shown.first) }
            }
            CardControls(controls: controls(found, tabs: tabs))
        }
        .padding(HoverCard.padding)
        .frame(width: TabHoverCard.width, alignment: .leading)
        .task(id: shown.map(\.id)) { TabHoverCard.showing(shown, for: subject.key) }
        .task(id: tabs.map(\.id)) { tabsChanging.follow(tabs) }
        .task(id: copied) {
            // The tick says it is done, then the button is a button again.
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }

    private func open(_ found: TabGroup, at tab: Tab?) {
        if found.collapsed { withAnimation(GroupLook.fold) { browser.toggleTabGroup(found.id) } }
        if let tab = tab.flatMap(browser.rowTab(for:)) { browser.select(tab) }
        TabHoverCard.hide()
    }

    /// Its links, a copy of it (a group's) and its fold; while one of its
    /// tabs plays or is muted, its sound.
    private func controls(_ found: TabGroup, tabs: [Tab]) -> [CardControl] {
        let kind = kept ? "Folder" : "Group"
        var controls = [
            CardControl(id: "copy", symbol: copied ? "checkmark" : "link", help: "Copy All Links") {
                let links = browser.links(of: found.id)
                guard !links.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
                copied = true
            },
        ]
        if !kept {
            controls.append(CardControl(id: "duplicate", symbol: "plus.square.on.square", help: "Duplicate Group") {
                browser.duplicateTabGroup(found.id)
                TabHoverCard.hide()
            })
        }
        controls.append(CardControl(id: "fold", symbol: found.collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                                    help: found.collapsed ? "Expand \(kind)" : "Collapse \(kind)") {
            withAnimation(GroupLook.fold) { browser.toggleTabGroup(found.id) }
        })
        if tabs.contains(where: { $0.noisy || $0.muted }) {
            // Heard: Mute All. Only silenced: Unmute All.
            let silencing = tabs.contains { $0.noisy && !$0.muted }
            controls.append(CardControl(id: "mute", symbol: silencing ? "speaker.wave.2" : "speaker.slash",
                                        help: silencing ? "Mute All" : "Unmute All") {
                // As the group stands when pressed, not as it was drawn.
                let now = browser.members(ofGroup: found.id)
                let silence = now.contains { $0.noisy && !$0.muted }
                for tab in now where silence ? (tab.noisy && !tab.muted) : tab.muted { tab.toggleMute() }
            })
        }
        return controls
    }
}

/// Tells a view of several tabs when any of them changes: their sound,
/// their title, their icon. Followed afresh as the tabs change.
private final class TabsChanging: ObservableObject {
    private var watching: AnyCancellable?

    func follow(_ tabs: [Tab]) {
        watching = Publishers.MergeMany(tabs.map(\.objectWillChange))
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

/// Up to four of a group's tabs as one picture, the size of a tab's: one
/// whole, two side by side, three in columns, four in the corners. Each part
/// goes to its tab.
private struct Collage: View {
    let tabs: [Tab]
    let pictures: [Tab.ID: NSImage]
    let glyph: Glyph
    let pick: (Tab) -> Void

    /// Between the parts: the card's ground showing through.
    private static let gap: CGFloat = 2
    private static let width = HoverCard.pictureWidth
    private static let height = HoverCard.pictureWidth * TabPicture.ratio

    var body: some View {
        Group {
            if tabs.count >= 4 {
                VStack(spacing: Self.gap) {
                    row(Array(tabs[0..<2]), height: (Self.height - Self.gap) / 2)
                    row(Array(tabs[2..<4]), height: (Self.height - Self.gap) / 2)
                }
            } else {
                row(tabs, height: Self.height)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func row(_ tabs: [Tab], height: CGFloat) -> some View {
        let count = CGFloat(max(tabs.count, 1))
        let width = (Self.width - Self.gap * (count - 1)) / count
        return HStack(spacing: Self.gap) {
            ForEach(tabs) { tab in
                TabPicture(image: pictures[tab.id], tab: tab, glyph: glyph, width: width, height: height, mark: 18)
                    .contentShape(Rectangle())
                    .onTapGesture { pick(tab) }
                    .help(tab.label)
            }
        }
    }
}

/// A group's tabs by their icons, on its collage's corner as a tab's icon
/// sits on its picture: three at most, then how many more, on a chip edged
/// in the group's colour.
private struct GroupIcons: View {
    /// The collage's tabs, the one you were in last first.
    let tabs: [Tab]
    /// How many the group holds.
    let total: Int
    let colour: GroupColour
    let glyph: Glyph

    var body: some View {
        let shown = Array(tabs.prefix(3))
        HStack(spacing: -4) {
            ForEach(shown) { tab in
                Mark(icon: glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: 16)
                    .padding(2)
                    .background(Palette.ground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            if total > shown.count {
                Text("+\(total - shown.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
            }
        }
        .padding(2)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(colour.swatch, lineWidth: 1.5))
    }
}
