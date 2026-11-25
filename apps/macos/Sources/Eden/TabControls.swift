import SwiftUI

/// A tab's name, typed in its own row (Browser.beginTabRename).
///
/// A field of its own rather than SwiftUI's, for one reason: the system paints
/// selected text as a solid block of accent colour, which over a pale grey pill
/// this size is the loudest thing in the window. Here it is a tenth of the ink.
struct TabNameField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    /// The row's title size, so the name being typed is the name as it will
    /// read.
    let size: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: size)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        // Without this the field editor stays as wide as the field: the text
        // past the edge is cut off, and the caret, Home/End and a click can't
        // reach it. Scrollable, the editor grows to the text and follows the caret.
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.stringValue = browser.tabDraft
        field.setAccessibilityLabel("Tab name")
        context.coordinator.watch(field)
        return field
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.unwatch()
    }

    /// The width it is offered, never the name's own. Left to its own, the
    /// field was as wide as the whole name and the row cut it off: a field
    /// that never runs out of room never scrolls, so the caret went on out
    /// of sight with ← and →, and so did what was typed at the end.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let natural = field.intrinsicContentSize
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: max(0, width), height: proposal.height ?? natural.height)
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        if !coordinator.typing, field.stringValue != browser.tabDraft {
            field.stringValue = browser.tabDraft
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.11)),
                .foregroundColor: Palette.NS.ink,
            ]
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var claimed = false
        var typing = false

        init(browser: Browser) { self.browser = browser }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            defer { typing = false }
            browser.tabDraft = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                browser.commitTabEdit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                browser.cancelTabEdit()
                return true
            default:
                return false
            }
        }

        /// Clicking anywhere else keeps what was typed, as Return does.
        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.commitTabEdit() }
        }

        /// A press on something that takes no focus — the column below the
        /// rows — leaves the field focused and
        /// editing, so presses are watched for while it is there: one anywhere
        /// but in the field ends the edit the same way. The press itself goes
        /// on to what it was for.
        private var watcher: Any?

        @MainActor func watch(_ field: NSTextField) {
            guard watcher == nil else { return }
            watcher = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak field] event in
                guard let self, let field, event.window === field.window,
                      !field.bounds.contains(field.convert(event.locationInWindow, from: nil))
                else { return event }
                let browser = self.browser
                DispatchQueue.main.async { browser.commitTabEdit() }
                return event
            }
        }

        @MainActor func unwatch() {
            if let watcher { NSEvent.removeMonitor(watcher) }
            watcher = nil
        }
    }
}

/// What a right-click on any tab offers, wherever the tab is drawn. Its
/// actions are the hover card's and the menu bar's (Browser's one set of
/// tab actions), and none goes to the tab unless going there is the point.
/// Right-clicked among tabs picked in the column, each acts on all of them.
struct TabMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let close: () -> Void

    /// What the actions act on: the picked tabs, or this one alone.
    private var tabs: [Tab] { browser.acting(on: tab) }

    var body: some View {
        if browser.prefs.usesTabGroups && tab.pin == nil && !tab.shy && !tab.bench {
            // Right-clicked among tabs picked in the column: all of them, as
            // a drag onto a group takes them (see carried).
            let moving = browser.carried(with: tab)
            Menu("Move to Group") {
                Button("New Group") {
                    let id = browser.addTabGroup(containing: tab)
                    for other in moving where other !== tab { browser.move(other, toGroup: id) }
                }
                if !browser.tabGroups.isEmpty { Divider() }
                ForEach(browser.tabGroups) { group in
                    Button(group.name) { for each in moving { browser.move(each, toGroup: group.id) } }
                        .disabled(moving.allSatisfy { $0.groupID == group.id })
                }
                if moving.contains(where: { $0.groupID != nil }) {
                    Divider()
                    Button("Remove from Group") { for each in moving { browser.move(each, toGroup: nil) } }
                }
            }
        }
        if tab.pin == nil {
            Button("Pin") { browser.pin(tabs, listed: false) }
                .disabled(!tab.isWeb || tab.shy)
            Button("Pin as Row") { browser.pin(tabs, listed: true) }
                .disabled(!tab.isWeb || tab.shy)
        } else {
            Button(tab.listed ? "Show as Square" : "Show as Row") { browser.setListed(tab, !tab.listed) }
            // A row of this space's own into a kept group, a new one or one
            // there is.
            if browser.fitsKeptGroup(tab) {
                Button("New Folder") { browser.newKeptGroup(holding: tab) }
                let groups = browser.keptGroups
                if !groups.isEmpty {
                    Menu("Move to Folder") {
                        ForEach(groups) { group in
                            Button(group.name) { browser.move(tab, to: ColumnPlace(area: .kept, group: group.id)) }
                                .disabled(tab.keptGroupID == group.id)
                        }
                        if browser.keptGroup(of: tab) != nil {
                            Divider()
                            Button("Remove from Folder") { browser.move(tab, to: ColumnPlace(area: .kept)) }
                        }
                    }
                }
            }
            // A row wears its title, not its letter; and a click on it is
            // the address, so the way home a square's double-click is
            // (Browser.goHome) is here instead, while it has wandered.
            if tab.listed {
                Button("Back to Pinned Page") { browser.goHome(tab) }
                    .disabled(!tab.wandered)
            } else {
                Button("Change Letter") { browser.editLetter(tab) }
            }
            Button("Replace Pinned Page with Current URL") { browser.rehome(tab) }
                .disabled(!tab.isWeb || tab.home.map { Browser.samePage($0, tab.address) } ?? false)
            if browser.prefs.showsSharedPins {
                Button(tab.everywhere ? "Only in This Space" : "Keep in Every Space") {
                    if tab.everywhere { browser.keepHere(tab) } else { browser.shareEverywhere(tab) }
                }
            }
            Button("Unpin") { browser.unpin(tabs) }
            // Away for good in one go, where Unpin, finding the row and its
            // × took three (#834); ⇧⌘T brings it back a pin.
            Button("Delete") { browser.deletePin(tab) }
        }
        // A shared pin is in every space already: nowhere to move it.
        if browser.prefs.usesSpaces, !tab.bench, !tab.everywhere,
           tab.address.flatMap({ Browser.extensionHost(of: $0) }) == nil {
            // Not the pins every space shows among those picked: they stay.
            let moving = browser.movableToSpace(tabs)
            Menu("Move to Space") {
                ForEach(browser.spaces.filter { $0.id != browser.spaceID }) { space in
                    Button {
                        browser.move(moving, toSpace: space.id)
                    } label: {
                        Label(space.name, systemImage: space.symbol)
                    }
                }
                if browser.spaces.count > 1 { Divider() }
                Button("New Space…") {
                    browser.askForSpace { space in
                        browser.move(moving, toSpace: space.id) {
                            browser.switchSpace(to: space.id)
                        }
                    }
                }
            }
            .disabled(moving.isEmpty)
            .help("Pages moved to a Space with different sign-ins reopen there.")
        }
        // Settings › Spaces & Pins › Send links to a space, from here: the
        // tab's site to the space it is in, or back out of it.
        if browser.prefs.usesSpaces, browser.prefs.sendsLinksToSpaces, !tab.shy, !tab.bench,
           let site = tab.address.flatMap(SpaceRoutes.site(of:)) {
            let space = browser.space
            if browser.prefs.spaceRoutes.contains(SpaceRoute(site: site, space: space.id)) {
                Button("Stop Opening \(site) in \(space.name)") { SpaceRoutes.remove(site) }
            } else {
                Button("Always Open \(site) in \(space.name)") { SpaceRoutes.set(site, to: space.id) }
            }
        }
        if browser.prefs.splitView {
            // Right-clicked among tabs picked in the column: those side by
            // side, up to four. More can't be, so it is there but off.
            let picked = browser.selectedTabIDs.contains(tab.id) ? browser.visibleSelectedTabCount : 1
            if picked > 1 && !browser.pickedTabsArePaired {
                Button("Open \(picked) Tabs in Split View") { browser.pairPickedTabs(focus: tab) }
                    .disabled(browser.pickedSplit == nil)
            }
            if let pair = browser.split(for: tab) {
                Button("Swap Pages") {
                    browser.focusPane(tab)
                    browser.swapSplit()
                }
                if pair.tabs.count > 2 {
                    // This page alone out of it; the others stay together.
                    Button("Remove from Split View") { browser.leaveSplit(tab) }
                }
                Button("Separate Pages") { browser.detachSplit(tab) }
                Button(pair.tabs.count > 2 ? "Close All Pages" : "Close Both Pages") {
                    browser.focusPane(tab)
                    browser.closeSplit()
                }
            } else if picked == 1 {
                // Beside the page on screen; on that page itself, an empty
                // page beside it. On a split with room, one more page in it.
                let current = browser.active
                let adding = browser.activeSplit != nil && current?.id != tab.id
                Button(adding ? "Add to Split View" : "Open in Split View") { browser.openInSplit(tab) }
                    // Nothing in front: nothing to be beside.
                    .disabled(tab.bench || current == nil || (adding && current.map { !browser.canJoin(tab, beside: $0) } ?? true))
            }
        }
        if tab.pin == nil, !tab.bench {
            // Another window, or a new one (see Browser.moveToWindow).
            let moving = tabs
            let others = Browsers.all.filter { $0 !== browser && $0.isOpen && !$0.isPopup && $0.profileID == browser.profileID }
            if others.isEmpty {
                Button("Move to New Window") { browser.move(moving, toWindow: nil) }
                    .disabled(!browser.canMoveToWindow(moving))
            } else {
                Menu("Move to Window") {
                    Button("New Window") { browser.move(moving, toWindow: nil) }
                        .disabled(!browser.canMoveToWindow(moving))
                    Divider()
                    ForEach(Array(others.enumerated()), id: \.offset) { _, other in
                        Button(other.windowName) { browser.move(moving, toWindow: other) }
                    }
                }
            }
        }
        Divider()
        // A square's name is its letter, which Change Letter changes, above.
        if tab.pin == nil || tab.listed {
            Button("Rename…") { browser.beginTabRename(tab) }
        }
        Button("Duplicate") { browser.duplicate(tabs) }
            .disabled(!tab.isWeb)
        // The site's controls hang from the address bar, which is the tab
        // in front's: going there is the point.
        Button("Site Controls…") {
            if browser.activeID != tab.id { browser.select(tab) }
            browser.siteControlsShown = true
        }
        .disabled(!tab.isWeb || browser.folded && !browser.peeking)
        let several = tabs.count > 1
        Button(several ? "Copy Addresses" : "Copy Address") { browser.copyAddresses(of: tabs) }
            .disabled(!tabs.contains(where: \.isWeb))
        Button(several ? "Copy as Markdown Links" : "Copy as Markdown Link") { browser.copyMarkdownLinks(of: tabs) }
            .disabled(!tabs.contains(where: \.isWeb))
        Button(several ? "Copy Clean Links" : "Copy Clean Link") { browser.copyCleanLinks(of: tabs) }
            .disabled(!tabs.contains(where: \.isWeb))
        SendToMenu(browser: browser, tabs: tabs)
        if browser.prefs.sitesInPanel {
            Button("Open in Side Panel") { browser.openInSidePanel(tab) }
                .disabled(!tab.isWeb || tab.shy)
        }
        Divider()
        Button("Reload") { browser.reload(tabs) }
            .disabled(!tabs.contains { $0.built != nil })
        Button(tab.muted ? "Unmute Tab" : "Mute Tab") { browser.toggleMute(tab) }
        // Its page let go of now, as it would be after half an hour unseen:
        // the row keeps its title and picture, and it loads again when gone
        // to. Not the tab on screen, nor one that has to stay awake (#310).
        Button("Put to Sleep") { browser.sleep(tabs) }
            .disabled(tabs.allSatisfy { browser.awake(because: $0) != nil })
        Divider()
        // Says what it does: a pin is put down, a tab in a group put away
        // (Browser.closeTab), any other closed. Right-clicked among tabs
        // picked in the column: all of them, as ⌘W closes them.
        if several {
            Button(TabMenu.closing(tabs, in: browser)) { browser.closePickedTabs() }
        } else {
            // A pin put down already has nothing more to put down: Delete,
            // above, takes it out.
            Button(TabMenu.closing([tab], in: browser), action: close)
                .disabled(tab.pin != nil && tab.asleep)
        }
        Button("Close Other Tabs") { browser.closeOthers(but: tab) }
            .disabled(browser.othersToClose(but: tab).isEmpty)
        Button("Close Tabs Below") { browser.closeTabsBelow(tab) }
            .disabled(browser.tabsBelow(tab).isEmpty)
        // ⌘⇧T, and the History menu's Recently Closed, where few think to
        // look for it: here too, where tabs are closed.
        Button(browser.reopenTitle) { browser.reopen() }
            .disabled(browser.ghosts.isEmpty)
    }

    /// Close's words for `tabs`, as ⌘W and the row's mark treat each: Put
    /// Down for pins, Put Away for tabs in a group that keeps them, Close
    /// for the rest, and Close when they are of more than one kind.
    static func closing(_ tabs: [Tab], in browser: Browser) -> String {
        let pins = tabs.allSatisfy { $0.pin != nil }
        let away = tabs.allSatisfy { $0.pin == nil && browser.putsAway($0) }
        guard tabs.count > 1 else { return pins ? "Put Down" : away ? "Put Away" : "Close Tab" }
        if pins { return "Put Down \(tabs.count) Pins" }
        return away ? "Put Away \(tabs.count) Tabs" : "Close \(tabs.count) Tabs"
    }
}

/// Observe the press without recognizing a hold that would take the row's drag.
struct TabPress: ViewModifier {
    let enabled: Bool
    let active: Bool
    @Binding var selected: Bool
    /// Told when the button goes down on the tab and comes back up, whatever
    /// the press goes on to do, for the tab to give under it (see Give).
    var pressing: Binding<Bool>? = nil
    let act: () -> Void

    /// How far the hand may go before the press gives way to the row's
    /// drag, which starts at 5. A long press that never gave way (as this
    /// was first written, with no limit) kept the press to itself: the drag
    /// that carries a row or a pin waited for it to fail, which it only did
    /// at the release, so nothing moved under the hand — the row jumped to
    /// its place on letting go, and a pin held still a moment before
    /// letting go wasn't moved at all.
    static let travel: CGFloat = 4

    /// When the last press opened its tab, until the next press (or the
    /// release, after a drag). A tab carried from it onto the page asks (see
    /// TabDrag.begin): the page under the hand is then its own, with
    /// nothing to split.
    private(set) static var openedAt: TimeInterval?

    func body(content: Content) -> some View {
        _ = TabClick.watching
        return content.onLongPressGesture(minimumDuration: .infinity, maximumDistance: TabPress.travel, pressing: { down in
            pressing?.wrappedValue = down
            if !down {
                // Given way to a drag, the button still down: what the press
                // did stands until the release, so the release can't take
                // it for a fresh click on the tab now on screen.
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    TabPress.untilRelease { selected = false; TabPress.openedAt = nil }
                    return
                }
                // The row's release handler must see which press selected it.
                // `openedAt` stays until the next press: an event made by a
                // test has no button down, and a drag it carries on with
                // still asks.
                DispatchQueue.main.async { selected = false }
                return
            }
            TabPress.openedAt = nil
            guard enabled, TabClick.flags.intersection([.command, .control, .shift, .option]).isEmpty,
                  !TabPress.otherButton else { return }
            selected = !active
            if selected {
                TabPress.openedAt = ProcessInfo.processInfo.systemUptime
                act()
            }
        }, perform: {})
    }

    /// The press is the right button's or the middle one's: the long press
    /// hears every button go down, and a right-click is the tab's menu, a
    /// middle-click its closing, never its selection.
    private static var otherButton: Bool {
        if let type = NSApp.currentEvent?.type { return type == .rightMouseDown || type == .otherMouseDown }
        let buttons = NSEvent.pressedMouseButtons
        return buttons != 0 && buttons & 1 == 0
    }

    /// Once, at the left button's release.
    private static func untilRelease(_ act: @escaping () -> Void) {
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            DispatchQueue.main.async(execute: act)
            return event
        }
    }
}

/// A tab gives a little under the button and springs back when it is let
/// go, the life Arc's tabs have when clicked. Going down is quick, so the
/// click is answered at once; coming back is the settle spring. Only the
/// scale is animated, so the selection the press makes isn't slowed with
/// it. Nothing moves with Reduce Motion on.
struct Give: ViewModifier {
    let pressed: Bool

    func body(content: Content) -> some View {
        content.animation(pressed ? Motion.quick : Motion.settle) {
            $0.scaleEffect(pressed && !Motion.reduced ? Motion.give : 1)
        }
    }
}

/// A modified tap selects tabs; a drag stays with the row's drag gesture.
struct ModifiedTabClick: ViewModifier {
    let act: (NSEvent.ModifierFlags) -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(TapGesture().onEnded {
            let modifiers = TabClick.flags
            if !modifiers.intersection([.command, .shift]).isEmpty { act(modifiers) }
        })
    }
}

/// The keys held with the click a tab is answering, read the same way by
/// the press, the click and the modified clicks, so they agree on a click:
/// one with ⌥ is OptionClick's, one with ⌘ or ⇧ ModifiedTabClick's. The
/// click's own keys, as the app was handed it: a tap gesture ends after
/// AppKit has let go of its event, so NSApp.currentEvent is gone by then.
/// Only a click just made counts (`fresh`); otherwise the keys held now.
@MainActor
enum TabClick {
    private static var last: (flags: NSEvent.ModifierFlags, count: Int, at: TimeInterval)?
    /// How long a click's keys are its own: a press answers on the way down
    /// and a tap on the way up, well within this.
    static let fresh: TimeInterval = 0.5
    /// Watching the app's left-button events, from the first tab drawn.
    static let watching: Any? = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
    ) { event in
        MainActor.assumeIsolated { TabClick.last = (event.modifierFlags, event.clickCount, event.timestamp) }
        return event
    }

    static var flags: NSEvent.ModifierFlags {
        if let last, ProcessInfo.processInfo.systemUptime - last.at < fresh { return last.flags }
        return NSEvent.modifierFlags
    }

    /// Which click of a run this one is: 2 for a double-click's second.
    /// One tap that reads it, rather than a double tap beside the single,
    /// which would hold every single click back until a second couldn't
    /// come.
    static var count: Int {
        if let last, ProcessInfo.processInfo.systemUptime - last.at < fresh { return last.count }
        return 1
    }

    /// For tests: no click remembered.
    static func forget() { last = nil }
}

/// ⌥ and the click, nothing else held: Split View (Browser.optionClick).
/// Beside the tab's other gestures, as ModifiedTabClick is, so a pin that
/// answers only a double click still hears it once; those gestures and the
/// press (TabPress) leave a click with ⌥ to this one.
struct OptionClick: ViewModifier {
    let act: () -> Void

    func body(content: Content) -> some View {
        _ = TabClick.watching
        return content.simultaneousGesture(TapGesture().onEnded {
            if TabClick.flags.intersection([.command, .shift, .option, .control]) == .option { act() }
        })
    }
}

/// One gesture or the other, never the two together.
struct OneClick: ViewModifier {
    let double: Bool
    let act: () -> Void

    /// One gesture whose count changes, not two in turn: a pin becomes
    /// the one on screen as the button goes down (TabPress), and swapping
    /// one tap for the other then made the square anew under the hand, which
    /// dropped the drag that had picked it up.
    func body(content: Content) -> some View {
        content.onTapGesture(count: double ? 2 : 1, perform: act)
    }
}

/// A click on a tab's cross closes it — taken by a real view laid over the
/// cross rather than by a SwiftUI tap. Out over the page, in the column
/// folded away with ⌘S, the tap never came: the cross showed under the pointer and
/// clicking it did nothing (Drice). A view of AppKit's own is handed the
/// press by AppKit itself, as the middle button's is (MiddleClick), and it
/// answers only while the cross is there to be pressed, only to the left
/// button; to anything else it isn't there, and the tab goes on as before.
struct CloseClick: NSViewRepresentable {
    let armed: Bool
    let act: () -> Void

    func makeNSView(context: Context) -> NSView { Cross() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Cross)?.armed = armed
        (view as? Cross)?.act = act
    }

    private final class Cross: NSView {
        var armed = false
        var act: () -> Void = {}
        private var pressed = false

        /// Never the window's to drag from: the press is the cross's.
        override var mouseDownCanMoveWindow: Bool { false }

        /// Asked about every event over the cross, the pointer moving included;
        /// only a left press, while the cross shows, is this view's.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard armed, let event = NSApp.currentEvent,
                  event.type == .leftMouseDown, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            pressed = true
        }

        /// On the release, and only if it is still over the cross: a press
        /// taken back by moving off before letting go closes nothing.
        override func mouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
        }
    }
}

/// The middle button on a tab closes it, as it does in every other browser.
///
/// SwiftUI has no gesture for that button, so this is a real view laid over
/// the tab — and a real view is asked first (see DragStrip). It says yes for
/// the middle button and nothing else: to a left click, a drag or a right
/// click it isn't there, and the tab's own gestures and menu go on as before.
struct MiddleClick: NSViewRepresentable {
    let act: () -> Void

    func makeNSView(context: Context) -> NSView { Catch() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Catch)?.act = act
    }

    private final class Catch: NSView {
        var act: () -> Void = {}
        private var pressed = false

        /// Asked about every event that lands on the tab, the pointer moving
        /// over it included; the one being delivered is the one to judge by.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .otherMouseDown || event.type == .otherMouseUp,
                  event.buttonNumber == 2
            else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseDown(with event: NSEvent) {
            pressed = true
        }

        /// On the release, not the press, and only if it is still over the
        /// tab: a middle button pressed by mistake can be taken back the way
        /// a click on the cross can, by moving off before letting go.
        override func otherMouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
        }
    }
}

/// An almost-closed ring, turning — the same one the canvas app uses, small
/// enough to sit inside a tab without becoming the loudest thing in it.
///
/// Turned by Core Animation rather than SwiftUI. A SwiftUI animation that
/// never ends has the whole window's view tree laid out and redrawn every
/// frame for as long as it runs — a fifth of a core, all the while a page
/// in some tab behind was still loading. A layer's own animation is played
/// by the render server and costs this process nothing.
struct Ring: NSViewRepresentable {
    var size: CGFloat = 10

    func makeNSView(context: Context) -> RingView { RingView() }
    func updateNSView(_ view: RingView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RingView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    final class RingView: NSView {
        private let ring = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            ring.fillColor = nil
            ring.lineWidth = 1.4
            ring.lineCap = .round
            ring.strokeEnd = 0.78
            // Nothing but the turn moves: a new size or colour is there at
            // once, not eased into by Core Animation's own quarter second.
            ring.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull()]
            layer?.addSublayer(ring)
        }

        required init?(coder: NSCoder) { nil }

        /// Seen, never pressed: it sits in a tab, over the × while the page
        /// loads and in the middle of a tab down to its mark, and a real view
        /// would take the click meant for either.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            let inset = ring.lineWidth / 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = bounds
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
            CATransaction.commit()
        }

        /// The colour is resolved against the window's appearance, so it is
        /// set again whenever that changes.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.strokeColor = Palette.NS.muted.withAlphaComponent(0.7).cgColor
            }
        }

        /// Turning only while it is in a window: a layer animation is dropped
        /// when the view leaves one, so it is added each time it arrives.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            viewDidChangeEffectiveAppearance()
            ring.removeAnimation(forKey: "turn")
            guard window != nil else { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            // Clockwise, as the SwiftUI one turned: a layer's positive angle
            // is anticlockwise in a view that isn't flipped.
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = 0.85
            turn.repeatCount = .infinity
            ring.add(turn, forKey: "turn")
        }
    }
}

/// The letter of a pinned tab, typed in the square itself.
///
/// A field of its own rather than SwiftUI's, for the same reason as the address
/// in a tab: the system paints selected text as a solid block of accent colour,
/// and over a thirty-point grey square that is the loudest thing on screen.
struct PinField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, tab: tab) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = tab.pin ?? ""
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.tab = tab
        if !coordinator.typing, field.stringValue != tab.pin ?? "" {
            field.stringValue = tab.pin ?? ""
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            // The guessed letter arrives selected, so one keystroke replaces it
            // and doing nothing keeps it.
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var tab: Tab
        var claimed = false
        var typing = false

        init(browser: Browser, tab: Tab) {
            self.browser = browser
            self.tab = tab
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            browser.letter(field.stringValue, for: tab)
            // One character only, and shown as it will be worn.
            field.stringValue = tab.pin ?? ""
            typing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.cancelOperation(_:)),
                 #selector(NSResponder.insertTab(_:)):
                browser.endPinEdit()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.endPinEdit() }
        }
    }
}
