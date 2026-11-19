import EdenCore
import SwiftUI

// iPhone's tabs, as the iPhone's own app switcher shows apps: each tab a
// card of its page, its site's icon and name above it, in a deck you swipe
// through sideways — the one you were just on at the front, the rest
// stacked behind it to the left, the newer sliding away right as you go
// back. Swipe a card up to close it; tap it and it grows back into its page
// (PhoneBrowser's zoom). Each space is a room of its own, in its colour, and
// private a dark one; the room's pins sit above the deck. iPad has its
// sidebar instead.

/// Between the browser and the deck, for the page's zoom into its card and
/// out of it again (PhoneBrowser): the page the overview opens from, which
/// the deck shrinks into its card, in its own place among the others; and a
/// card grown back to the screen as it closes. The overview's own controls
/// come in once the deck is on its way, and go as it leaves.
@MainActor
@Observable
final class DeckDirector {
    /// The page the overview is opening from, as it shows.
    @ObservationIgnored var entry: (tab: Tab.ID, picture: UIImage)?
    /// The overview's title, pins and controls: shown once it has arrived.
    var chrome = false
    @ObservationIgnored fileprivate weak var deck: CardDeck?

    /// `tab`'s card grown back to the whole screen, then `done`; false when
    /// it has no card in sight to grow, for the overview simply to fade.
    func leave(to tab: Tab.ID, done: @escaping () -> Void) -> Bool {
        guard let deck, deck.leave(to: tab, done: done) else { return false }
        withAnimation(.easeOut(duration: 0.2)) { chrome = false }
        return true
    }
}

/// The overview, drawn over the browser.
struct TabOverview: View {
    let browser: Browser
    @Binding var showingPrivate: Bool
    /// The page's zoom into its card and out again (DeckDirector).
    let director: DeckDirector
    /// What is typed in the search field of the bar at the foot, which the
    /// browser draws: the cards shown are those it matches.
    let query: String
    /// A tab picked, or nil for Done: the browser goes back to it.
    let leave: (Tab?) -> Void

    /// The card at the front of the deck.
    @State private var focus: Tab.ID?
    @State private var closes = 0
    @State private var managingSpaces = false
    @State private var showingDevices = false
    @State private var screen = CGSize(width: 402, height: 874)
    @Environment(\.colorScheme) private var colorScheme

    init(browser: Browser, showingPrivate: Binding<Bool>, director: DeckDirector, query: String,
         leave: @escaping (Tab?) -> Void) {
        self.browser = browser
        _showingPrivate = showingPrivate
        self.director = director
        self.query = query
        self.leave = leave
        _focus = State(initialValue: browser.activeID)
    }

    /// A tab closed, as much of it as Reopen brings back.
    private struct Closed {
        let title: String
        let url: URL
        let isPrivate: Bool
        let after: Tab.ID?
    }

    /// The room's tabs, in their own order: each keeps its place, and the
    /// deck opens at the one in front, wherever it is.
    private var room: [Tab] { showingPrivate ? browser.privateTabs : browser.looseTabs }

    /// Those the search matches, by name or address; all of them unsearched.
    private var deck: [Tab] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return room }
        return room.filter { tab in
            tab.title.lowercased().contains(words) || (tab.url?.absoluteString.lowercased().contains(words) ?? false)
        }
    }

    private var hasPins: Bool { !showingPrivate && !browser.shownPins.isEmpty }
    private var mood: Color? { browser.settings.usesSpaces ? browser.space.tint : nil }

    var body: some View {
        let cards = deck
        VStack(spacing: 0) {
            Group {
                header
                if hasPins {
                    PinStrip(browser: browser, container: "tabs") { leave(browser.active) }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
            }
            .opacity(director.chrome ? 1 : 0)
            .offset(y: director.chrome ? 0 : -10)
            if cards.isEmpty {
                emptyRoom.frame(maxHeight: .infinity)
            } else {
                DeckView(items: items(cards), front: focus, director: director,
                         open: { id in if let tab = cards.first(where: { $0.id == id }) { leave(tab) } },
                         close: { id in if let tab = cards.first(where: { $0.id == id }) { close(tab) } })
                    // A room of its own: another room's deck starts at its front.
                    .id(showingPrivate ? "private" : browser.spaceID.uuidString)
            }
        }
        // Over the deck, not in its way: the deck keeps its size.
        // The controls come in a moment after the page has begun to shrink,
        // so the eye stays on it.
        .onAppear { withAnimation(.smooth(duration: 0.35).delay(0.12)) { director.chrome = true } }
        .background {
            RoomBackdrop(tint: mood, isPrivate: showingPrivate)
                .ignoresSafeArea()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
                .animation(.smooth(duration: 0.5), value: showingPrivate)
                .animation(.smooth(duration: 0.5), value: browser.spaceID)
        }
        .environment(\.colorScheme, showingPrivate ? .dark : colorScheme)
        .sensoryFeedback(.impact(weight: .light), trigger: closes)
        .sensoryFeedback(.selection, trigger: showingPrivate)
        .sheet(isPresented: $managingSpaces) { SpacesSheet(browser: browser) }
        .sheet(isPresented: $showingDevices) {
            DevicesSheet(browser: browser) {
                showingDevices = false
                leave(nil)
            }
        }
        .task(id: showingPrivate ? "private" : browser.spaceID.uuidString) {
            let cards = room
            let front = cards.firstIndex { $0.id == browser.activeID } ?? cards.count - 1
            CardPictures.shared.want(cards.indices.sorted { abs($0 - front) < abs($1 - front) }.map { cards[$0] })
        }
        .onDisappear { CardPictures.shared.stop() }
    }

    // MARK: - the room's head

    /// The rooms, to switch between, and your other devices' tabs: the
    /// room says itself, so there is no title over it, and no count.
    private var header: some View {
        HStack(spacing: 10) {
            rooms
            Spacer(minLength: 0)
            if !showingPrivate, browser.elsewhere.contains(where: \.hasTabs) {
                Button { showingDevices = true } label: {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("On Your Other Devices")
                .accessibilityIdentifier("other-devices")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .tint(.primary)
    }

    // MARK: - closing, and bringing back

    /// Closed, it offers itself back for a moment: Reopen on the toast.
    private func close(_ tab: Tab) {
        let ids = deck.map(\.id)
        if let url = tab.url, let at = ids.firstIndex(of: tab.id) {
            let closed = Closed(title: tab.title.isEmpty ? Address.pretty(url) : tab.title, url: url,
                                isPrivate: tab.isPrivate, after: at > 0 ? ids[at - 1] : nil)
            browser.announce("Closed “\(closed.title)”", symbol: "xmark",
                             action: Toast.Action("Reopen", identifier: "reopen-tab") { reopen(closed) })
        }
        withAnimation(.smooth(duration: 0.35)) { browser.close(tab) }
        closes += 1
    }

    private func reopen(_ closed: Closed) {
        let after = closed.after.flatMap { id in browser.tabs.first { $0.id == id } }
        withAnimation(.smooth(duration: 0.35)) {
            let back = browser.newTab(url: closed.url, private: closed.isPrivate, select: false, after: after)
            focus = back.id
        }
    }

    // MARK: - nothing here yet

    private var emptyRoom: some View {
        VStack(spacing: 16) {
            Image(systemName: showingPrivate ? "eye.slash" : browser.space.symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(showingPrivate ? Color.purple.opacity(0.9) : (mood ?? .accentColor))
                .frame(width: 84, height: 84)
                .glassEffect(.regular, in: .circle)
            VStack(spacing: 6) {
                Text(showingPrivate ? "Nothing private open" : "Nothing open here").font(.title3.weight(.semibold))
                Text(showingPrivate
                     ? "A private tab keeps no history and its own cookies, gone when it closes."
                     : "Every tab you open in this room gathers here.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Button {
                browser.newTab(private: showingPrivate)
                leave(nil)
            } label: {
                Label(showingPrivate ? "New Private Tab" : "New Tab", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 20)
                    .frame(height: 46)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - the cards

    /// What each card shows (DeckItem): the page as it last showed, or what
    /// stands in for it.
    private func items(_ cards: [Tab]) -> [DeckItem] {
        cards.map { tab in
            let icon = SiteIcons.shared.icon(for: tab.url)
            let title = tab.title.isEmpty ? (tab.url.map(Address.pretty) ?? "New Tab") : tab.title
            let accent = icon.flatMap(SiteIcons.shared.accent(of:)).map(UIColor.init)
            return DeckItem(id: tab.id, title: title, icon: icon, picture: tab.snapshot, accent: accent,
                            letter: tab.url.map { String(Address.pretty($0).prefix(1)).uppercased() },
                            isPrivate: tab.isPrivate)
        }
    }

    /// The rooms: each space, in its colour, and private; or, with spaces
    /// off, tabs and private. The room shown says its name; tapped again,
    /// a space shows every space, to make, change or delete one.
    private var rooms: some View {
        HStack(spacing: 4) {
            if browser.settings.usesSpaces {
                ForEach(browser.spaces) { space in
                    let on = !showingPrivate && space.id == browser.spaceID
                    chip(space.name, symbol: space.symbol, tint: space.tint, on: on, named: on,
                         id: on ? "space-switcher" : "room-\(space.id.uuidString)",
                         label: on ? "Space: \(space.name)" : space.name) {
                        if on {
                            managingSpaces = true
                        } else {
                            showingPrivate = false
                            browser.enter(space.id)
                            focus = browser.activeID
                        }
                    }
                }
            } else {
                chip("Tabs", symbol: "square.on.square", tint: nil, on: !showingPrivate, named: true, id: "room-tabs") {
                    showingPrivate = false
                    focus = browser.activeID
                }
            }
            chip("Private", symbol: "eye.slash", tint: .purple, on: showingPrivate,
                 named: !browser.settings.usesSpaces || showingPrivate, id: "room-private") {
                showingPrivate = true
                focus = room.last?.id
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }

    private func chip(_ title: String, symbol: String, tint: Color?, on: Bool, named: Bool, id: String,
                      label: String? = nil, pick: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.4)) { pick() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                if named { Text(title).lineLimit(1) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .padding(.horizontal, named ? 14 : 12)
            .frame(height: 38)
            .background(on ? (tint ?? .accentColor).opacity(0.32) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

// MARK: - the deck

/// What a card shows, worked out where SwiftUI watches it, so a site's icon
/// or a page's picture arriving reaches the deck: its name and icon, the
/// page as it last showed, and, until there is a picture, what stands in
/// for it — the icon's colour and the site's letter.
private struct DeckItem: Equatable {
    let id: Tab.ID
    let title: String
    let icon: UIImage?
    let picture: UIImage?
    let accent: UIColor?
    /// The site's first letter; nil for a tab with no page.
    let letter: String?
    let isPrivate: Bool
}

/// The deck, as UIKit draws it (CardDeck): SwiftUI hands it the cards and
/// the one to bring to the front, and is told which was opened or thrown.
private struct DeckView: UIViewRepresentable {
    let items: [DeckItem]
    let front: Tab.ID?
    let director: DeckDirector
    let open: (Tab.ID) -> Void
    let close: (Tab.ID) -> Void

    func makeUIView(context: Context) -> CardDeck { CardDeck() }

    func updateUIView(_ deck: CardDeck, context: Context) {
        deck.open = open
        deck.close = close
        deck.director = director
        director.deck = deck
        deck.show(items, front: front)
    }
}

/// The cards, as the iPhone's app switcher moves its apps: a scroll view is
/// the motion — it follows the finger, carries on as it is let go and slows
/// as a scroll does, stops under a touch, gives at either end — and every
/// frame each card is put where its distance from the front says, on one
/// smooth curve: the newer slide on to the right, the next lying over the
/// front card's edge; the older gather in to the left, a sliver of each
/// showing; and the front card moves exactly with the finger. A card swiped
/// up is thrown away, the rest closing up as it goes.
///
/// The page zooms into its card as the overview opens, and a card back out
/// to the page as it closes, as part of the same placing: the card itself
/// goes between the whole screen and its place, in its own place among the
/// others — the newer card over it all the way — while they come in from
/// the sides, or go out to them, its corners easing from the screen's to a
/// card's, its shadow and every name coming in as it settles. Caught on the
/// way, the deck goes on from wherever the cards are.
private final class CardDeck: UIView, UIScrollViewDelegate {
    var open: (Tab.ID) -> Void = { _ in }
    var close: (Tab.ID) -> Void = { _ in }
    weak var director: DeckDirector?

    /// The page's zoom into its card as the overview opens, or a card's out
    /// to the page as it closes.
    private enum Motion {
        case arriving(Tab.ID)
        case leaving(Tab.ID, done: () -> Void)
    }
    private var motion: Motion?
    /// How far the zoom has come: nought with the page on the whole screen,
    /// one with every card in its place.
    private var progress: CGFloat = 1
    private var link: CADisplayLink?
    private var began: CFTimeInterval = 0
    private var from: CGFloat = 1
    private var to: CGFloat = 1
    /// Long enough for the zoom's spring to have settled.
    private static let settle: CFTimeInterval = 0.62

    private let scroll = DeckScroll()
    private var items: [DeckItem] = []
    private var cards: [Tab.ID: CardView] = [:]
    /// The card last asked to be at the front.
    private var asked: Tab.ID?
    /// One to put at the front once the deck has a size to do it in.
    private var pending: Tab.ID?
    /// Where the deck stood, in cards, as the finger took it.
    private var dragStart: CGFloat = 0

    private var width: CGFloat = 0
    private var height: CGFloat = 0
    private var margin: CGFloat = 0
    private var top: CGFloat = 0
    /// How far a finger goes to move the deck on by a card: as far as the
    /// front card goes to make way for the next, so it stays under the
    /// finger across the whole card, as in iOS.
    private var step: CGFloat { width * 0.875 }

    /// Room above a card for its site's icon and name.
    static let label: CGFloat = 42
    /// From one card to the next, the curve grows by this much.
    private static let ratio: CGFloat = 3.24

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.alwaysBounceVertical = false
        // Slowing as the app switcher does: a flick carries on by about a
        // card, a hard fling by two or three (measured against it).
        scroll.decelerationRate = UIScrollView.DecelerationRate(rawValue: 0.988)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.clipsToBounds = false
        scroll.delaysContentTouches = false
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let screen = window?.windowScene?.screen.bounds.size ?? CGSize(width: 402, height: 874)
        let aspect = screen.width / max(1, screen.height)
        let tall = max(120, bounds.height - Self.label - 24)
        width = min(bounds.width * 0.68, tall * aspect)
        height = width / aspect
        margin = (bounds.width - width) / 2
        top = max(Self.label, (bounds.height - height - Self.label) / 2 + Self.label)
        scroll.frame = bounds
        resize()
        if let pending, let at = index(of: pending) {
            scroll.contentOffset.x = CGFloat(at) * step
            self.pending = nil
        }
        place()
        arriveIfAsked()
    }

    private func resize() {
        scroll.contentSize = CGSize(width: bounds.width + CGFloat(max(0, items.count - 1)) * step, height: bounds.height)
    }

    private func index(of id: Tab.ID) -> Int? { items.firstIndex { $0.id == id } }

    /// The card nearest the front.
    private var frontIndex: Int {
        guard step > 0, !items.isEmpty else { return 0 }
        return min(items.count - 1, max(0, Int((scroll.contentOffset.x / step).rounded())))
    }

    /// The cards as they are now, and the one to bring to the front.
    func show(_ new: [DeckItem], front wanted: Tab.ID?) {
        let before = items.map(\.id)
        let standing = before.indices.contains(frontIndex) ? before[frontIndex] : nil
        items = new
        for item in new {
            let card = cards[item.id] ?? made(item.id)
            card.show(item)
        }
        for (id, card) in cards where !card.leaving && !new.contains(where: { $0.id == id }) {
            card.removeFromSuperview()
            cards[id] = nil
        }
        let changed = before != new.map(\.id)
        // Newer over older: each card over the one before.
        if changed { for item in new { if let card = cards[item.id] { scroll.bringSubviewToFront(card) } } }
        guard step > 0 else {
            pending = wanted ?? new.last?.id
            asked = wanted
            return
        }
        if changed {
            // The card that was at the front stays there; the rest close up
            // round it, or make room.
            let at = standing.flatMap(index(of:)) ?? min(frontIndex, new.count - 1)
            UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.resize()
                self.scroll.contentOffset.x = CGFloat(max(0, at)) * self.step
                self.place()
            }
        } else {
            place()
        }
        if let wanted, wanted != asked, let at = index(of: wanted), at != frontIndex {
            scroll.setContentOffset(CGPoint(x: CGFloat(at) * step, y: 0), animated: true)
        }
        asked = wanted
        arriveIfAsked()
    }

    private func made(_ id: Tab.ID) -> CardView {
        let card = CardView(id: id)
        card.open = { [weak self] in self?.open(id) }
        card.thrown = { [weak self] in self?.close(id) }
        card.gone = { [weak self] in self?.cards[id] = nil }
        card.canTap = { [weak self] in
            guard let self else { return false }
            return !scroll.isDragging && !scroll.isDecelerating && motion == nil
        }
        cards[id] = card
        scroll.addSubview(card)
        return card
    }

    /// Every card where its distance from the front puts it, and, while
    /// the page zooms, where the zoom has got to.
    private func place() {
        guard step > 0 else { return }
        let offset = scroll.contentOffset.x
        let stands = offset / step
        let base = width * 0.39
        let size = CGSize(width: width, height: height + Self.label)
        let hero = heroID.flatMap(index(of:))
        let zoom = progress
        let screen = screenCard()
        var frames = [CGRect?](repeating: nil, count: items.count)
        for index in items.indices {
            let away = CGFloat(index) - stands
            // Off the right edge, or wholly under the cards in front.
            guard (away >= -3.2 && away <= 1.75) || index == hero else { continue }
            var frame = CGRect(x: offset + margin + base * (pow(Self.ratio, away) - 1), y: top - Self.label,
                               width: size.width, height: size.height)
            if let hero {
                if index == hero {
                    frame = Self.mix(screen, frame, zoom)
                } else {
                    // The rest come in from the sides with it, or go out.
                    let out = index < hero ? -bounds.width * 0.55 : bounds.width * 1.05
                    frame.origin.x += out * (1 - zoom)
                }
            }
            frames[index] = frame
        }
        // Names and icons come in over the last of the zoom, and go first.
        let labels = hero == nil ? 1 : min(1, max(0, (zoom - 0.55) / 0.45))
        for (index, item) in items.enumerated() {
            guard let card = cards[item.id], !card.leaving else { continue }
            guard let frame = frames[index] else {
                if !card.isHidden { card.isHidden = true }
                continue
            }
            if card.isHidden { card.isHidden = false }
            if card.bounds.size != frame.size { card.bounds.size = frame.size }
            card.center = CGPoint(x: frame.midX, y: frame.midY)
            let away = CGFloat(index) - stands
            // Only the card in the middle is named, as in iOS: its name
            // all there within a quarter of a card of the middle, gone by
            // three quarters, whichever way it goes.
            card.naming = min(1, max(0, 1 - (abs(away) - 0.25) / 0.5))
            card.labels = labels
            let zooming = index == hero
            card.corner = zooming ? screenCorner + (CardView.corner - screenCorner) * zoom : CardView.corner
            card.shade = zooming ? zoom : 1
            // Its name stops short of the next card's icon.
            let next = frames.indices.contains(index + 1) ? frames[index + 1] : nil
            card.titleRoom = next.map { $0.minX - frame.minX - 46 } ?? .greatestFiniteMagnitude
        }
    }

    private var heroID: Tab.ID? {
        switch motion {
        case .arriving(let id): id
        case .leaving(let id, _): id
        case nil: nil
        }
    }

    /// A card the size of the whole screen, its page filling it, in the
    /// deck's own space.
    private func screenCard() -> CGRect {
        guard let window else { return .zero }
        let page = scroll.convert(window.bounds, from: window)
        return CGRect(x: page.minX, y: page.minY - Self.label, width: page.width, height: page.height + Self.label)
    }

    /// The screen's own corners: rounded on an iPhone with no home button.
    private var screenCorner: CGFloat { (window?.safeAreaInsets.bottom ?? 0) > 0 ? 55 : 0 }

    private static func mix(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    // MARK: the zoom

    /// The overview opening from a page: once the deck has its size, the
    /// page's card starts on the whole screen, showing the page as it was.
    private func arriveIfAsked() {
        guard motion == nil, step > 0, window != nil, let entry = director?.entry,
              let card = cards[entry.tab], index(of: entry.tab) != nil else { return }
        director?.entry = nil
        card.lend(entry.picture)
        motion = .arriving(entry.tab)
        run(from: 0, to: 1)
    }

    /// `id`'s card grown to the whole screen, over the rest, as they go out
    /// to the sides; then `done`. False with no card of it in sight.
    func leave(to id: Tab.ID, done: @escaping () -> Void) -> Bool {
        guard step > 0, let card = cards[id], !card.isHidden, !card.leaving else { return false }
        if case .leaving = motion { return true }
        if case .arriving(let other) = motion, other != id { cards[other]?.lend(nil) }
        // It stops sliding, and takes no more touches on its way out.
        scroll.setContentOffset(scroll.contentOffset, animated: false)
        scroll.isUserInteractionEnabled = false
        scroll.bringSubviewToFront(card)
        motion = .leaving(id, done: done)
        run(from: progress, to: 0)
        return true
    }

    private func run(from start: CGFloat, to end: CGFloat) {
        from = start
        to = end
        progress = start
        began = CACurrentMediaTime()
        link?.invalidate()
        let ticking = CADisplayLink(target: self, selector: #selector(tick))
        ticking.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        ticking.add(to: .main, forMode: .common)
        link = ticking
        place()
    }

    @objc private func tick() {
        let elapsed = CACurrentMediaTime() - began
        let settled = elapsed >= Self.settle
        progress = settled ? to : from + (to - from) * Self.spring(elapsed)
        place()
        if settled { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        switch motion {
        case .arriving(let id):
            motion = nil
            progress = 1
            cards[id]?.lend(nil)
            place()
        case .leaving(_, let done):
            // Left as it is, the page on the whole screen, for the browser
            // to take over from.
            done()
        case nil:
            break
        }
    }

    /// The zoom's spring, nought to one: quick, with the least overshoot.
    private static func spring(_ t: CFTimeInterval) -> CGFloat {
        let damping = 0.86, omega = 2 * Double.pi / 0.42
        let decay = exp(-damping * omega * t)
        let ringing = omega * (1 - damping * damping).squareRoot()
        return CGFloat(1 - decay * (cos(ringing * t) + damping * omega / ringing * sin(ringing * t)))
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { place() }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStart = step > 0 ? scrollView.contentOffset.x / step : 0
    }

    /// Let go: on to wherever the scroll would slow to, settled on a card.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset target: UnsafeMutablePointer<CGPoint>) {
        let last = CGFloat(max(0, items.count - 1))
        let now = scrollView.contentOffset.x / step
        let moved = now - dragStart
        var card = (target.pointee.x / step).rounded()
        // Which way it is going: the way it was flung, unless that is back
        // against the drag and too slow to mean it (a finger's wobble as it
        // lifts), when the drag's own way.
        var way: CGFloat = abs(velocity.x) > 0.2 ? (velocity.x > 0 ? 1 : -1) : 0
        if abs(moved) >= 0.25, way != 0, way != (moved > 0 ? 1 : -1), abs(velocity.x) < 0.8 { way = moved > 0 ? 1 : -1 }
        // Going one way, it settles on a card that way, never back behind
        // the finger; a drag of a quarter of a card or more goes on at least
        // to the next.
        if way > 0 { card = max(card, now.rounded(.up)) }
        if way < 0 { card = min(card, now.rounded(.down)) }
        if way == 0, abs(moved) >= 0.25 { card = moved > 0 ? max(card, dragStart.rounded() + 1) : min(card, dragStart.rounded() - 1) }
        card = min(last, max(0, card))
        target.pointee.x = card * step
        // Let go standing still, UIKit wouldn't move to it: glide there.
        if velocity.x == 0, abs(scrollView.contentOffset.x - card * step) > 0.5 {
            DispatchQueue.main.async { scrollView.setContentOffset(CGPoint(x: card * self.step, y: 0), animated: true) }
        }
    }
}

/// The deck's scroll: it takes only a sideways drag, leaving up and down to
/// the card under the finger.
private final class DeckScroll: UIScrollView {
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === panGestureRecognizer else { return super.gestureRecognizerShouldBegin(recognizer) }
        let travel = panGestureRecognizer.translation(in: self), speed = panGestureRecognizer.velocity(in: self)
        let sideways = travel == .zero ? abs(speed.x) >= abs(speed.y) : abs(travel.x) >= abs(travel.y)
        return sideways && super.gestureRecognizerShouldBegin(recognizer)
    }
}

/// One card: its site's icon and name above the page as it last showed. A
/// tap opens it; a swipe up throws it, from the speed it is let go at, and
/// one let go too soon settles back.
private final class CardView: UIView, UIGestureRecognizerDelegate {
    let id: Tab.ID
    var open: () -> Void = {}
    /// Thrown: the deck closes its tab and closes up, as it flies.
    var thrown: () -> Void = {}
    /// Out of sight: the deck lets it go.
    var gone: () -> Void = {}
    var canTap: () -> Bool = { true }
    /// On its way out: kept until it is out of sight, placed no more.
    private(set) var leaving = false
    /// How much of its name shows, by how near the middle it is.
    var naming: CGFloat = 1 {
        didSet { if naming != oldValue { label() } }
    }
    /// How much of its icon and name show, as the zoom brings them in.
    var labels: CGFloat = 1 {
        didSet { if labels != oldValue { label() } }
    }
    /// Its page's corners: the screen's as it zooms, a card's at rest.
    var corner: CGFloat = CardView.corner {
        didSet {
            guard corner != oldValue else { return }
            picture.layer.cornerRadius = corner
            setNeedsLayout()
        }
    }
    /// How much of its shadow shows: none on the whole screen.
    var shade: CGFloat = 1 {
        didSet { if shade != oldValue { holder.layer.shadowOpacity = Float(0.28 * shade) } }
    }
    /// How far its name may run before the next card's icon.
    var titleRoom: CGFloat = .greatestFiniteMagnitude {
        didSet { if titleRoom != oldValue { setNeedsLayout() } }
    }
    /// Its own picture, and one lent it for the zoom: the page as drawn,
    /// sharp on the whole screen.
    private var own: UIImage?
    private var lent: UIImage?
    private let fade = CAGradientLayer()

    private let icon = UIImageView()
    private let title = UILabel()
    private let holder = UIView()
    private let picture = UIImageView()
    /// What stands in for a page not yet photographed: its icon's colour,
    /// washed down the card, and the icon large, or the site's letter.
    private let standIn = UIView()
    private let wash = CAGradientLayer()
    private let bigIcon = UIImageView()
    private let letter = UILabel()
    private var settling: UIViewPropertyAnimator?
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))

    static let corner: CGFloat = 26
    private var shadowFor: CGRect = .zero

    /// The page's place within the card: from the card's own size, so it is
    /// right as soon as the deck has sized it, before its parts are laid out.
    var page: CGRect {
        CGRect(x: 0, y: CardDeck.label, width: bounds.width, height: max(0, bounds.height - CardDeck.label))
    }

    init(id: Tab.ID) {
        self.id = id
        super.init(frame: .zero)
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 7
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.tintColor = .secondaryLabel
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .label
        // Its end fades rather than stopping hard, where room runs out.
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        // A shadow drawn from its outline, once, not blurred every frame.
        holder.layer.shadowColor = UIColor.black.cgColor
        holder.layer.shadowOpacity = 0.28
        holder.layer.shadowRadius = 14
        holder.layer.shadowOffset = CGSize(width: 0, height: 8)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = Self.corner
        picture.layer.cornerCurve = .continuous
        picture.layer.borderWidth = 1
        picture.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        standIn.backgroundColor = .systemBackground
        standIn.layer.addSublayer(wash)
        bigIcon.contentMode = .scaleAspectFit
        bigIcon.layer.cornerRadius = 15
        bigIcon.layer.cornerCurve = .continuous
        bigIcon.clipsToBounds = true
        let bold = UIFont.systemFont(ofSize: 48, weight: .bold)
        letter.font = bold.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 48) } ?? bold
        letter.textColor = UIColor.white.withAlphaComponent(0.9)
        letter.textAlignment = .center
        standIn.addSubview(bigIcon)
        standIn.addSubview(letter)
        picture.addSubview(standIn)
        addSubview(icon)
        addSubview(title)
        addSubview(holder)
        holder.addSubview(picture)
        tap.delegate = self
        pan.delegate = self
        addGestureRecognizer(tap)
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "tab-card"
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Close") { [weak self] _ in
            self?.thrown()
            return true
        }]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 0, y: 1, width: 30, height: 30)
        let room = max(0, min(bounds.width - 38, titleRoom))
        title.frame = CGRect(x: 38, y: 0, width: room, height: 32)
        let long = title.intrinsicContentSize.width > room + 0.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if long, room > 30 {
            title.lineBreakMode = .byClipping
            fade.frame = title.bounds
            fade.locations = [0, NSNumber(value: Double((room - 28) / room)), 1]
            if title.layer.mask !== fade { title.layer.mask = fade }
        } else {
            title.lineBreakMode = .byTruncatingTail
            if title.layer.mask != nil { title.layer.mask = nil }
        }
        let page = CGRect(x: 0, y: CardDeck.label, width: bounds.width, height: max(0, bounds.height - CardDeck.label))
        if holder.frame != page {
            holder.frame = page
            picture.frame = holder.bounds
            standIn.frame = picture.bounds
            wash.frame = standIn.bounds
            bigIcon.frame = CGRect(x: (page.width - 64) / 2, y: (page.height - 64) / 2, width: 64, height: 64)
            letter.frame = standIn.bounds
        }
        let shadow = CGRect(origin: CGPoint(x: corner, y: 0), size: page.size)
        if shadow != shadowFor {
            shadowFor = shadow
            holder.layer.shadowPath = UIBezierPath(roundedRect: holder.bounds, cornerRadius: corner).cgPath
        }
        CATransaction.commit()
    }

    /// A picture lent for the zoom, in place of its own, or nil for its own.
    func lend(_ shown: UIImage?) {
        lent = shown
        let image = lent ?? own
        if picture.image !== image { picture.image = image }
        standIn.isHidden = image != nil
    }

    private func label() {
        let icons = labels
        if icon.alpha != icons { icon.alpha = icons }
        let named = naming * labels
        if title.alpha != named { title.alpha = named }
    }

    func show(_ item: DeckItem) {
        own = item.picture
        let image = lent ?? own
        if picture.image !== image { picture.image = image }
        standIn.isHidden = image != nil
        if item.picture == nil {
            let colour = item.accent ?? (item.isPrivate ? .systemPurple : .systemGray)
            wash.colors = [colour.withAlphaComponent(0.5).cgColor, colour.withAlphaComponent(0.12).cgColor]
            bigIcon.image = item.icon
            bigIcon.isHidden = item.icon == nil
            letter.text = item.icon == nil ? (item.letter ?? "") : nil
        }
        let mark = item.icon ?? UIImage(systemName: item.isPrivate ? "eye.slash" : "globe")
        if icon.image !== mark {
            icon.image = mark
            icon.contentMode = item.icon == nil ? .center : .scaleAspectFit
        }
        if title.text != item.title { title.text = item.title }
        accessibilityLabel = item.title
    }

    @objc private func tapped() {
        guard !leaving else { return }
        open()
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // A touch that stops the deck sliding is only that, as in iOS.
        recognizer === tap ? canTap() : true
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === pan else { return super.gestureRecognizerShouldBegin(recognizer) }
        let travel = pan.translation(in: self), speed = pan.velocity(in: self)
        return travel == .zero ? abs(speed.y) > abs(speed.x) : abs(travel.y) > abs(travel.x)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let travel = pan.translation(in: superview).y, speed = pan.velocity(in: superview).y
        switch pan.state {
        case .began, .changed:
            settling?.stopAnimation(true)
            settling = nil
            // Up follows the finger; down gives only a little.
            let lift = travel < 0 ? travel : 60 * (1 - 1 / (travel / 120 + 1))
            transform = CGAffineTransform(translationX: 0, y: lift)
        case .ended, .cancelled:
            let lift = transform.ty
            if pan.state == .ended, lift < -bounds.height * 0.2 || (speed < -700 && lift < 0) {
                leaving = true
                let away = -(window?.bounds.height ?? 900) - bounds.height
                let flight = UIViewPropertyAnimator(duration: 0.42, timingParameters: UISpringTimingParameters(
                    dampingRatio: 1, initialVelocity: CGVector(dx: 0, dy: away != lift ? speed / (away - lift) : 0)))
                flight.addAnimations { self.transform = CGAffineTransform(translationX: 0, y: away) }
                flight.addCompletion { _ in
                    self.removeFromSuperview()
                    self.gone()
                }
                flight.startAnimation()
                // The rest close up now, as it flies, not once it has gone.
                thrown()
            } else {
                let back = UIViewPropertyAnimator(duration: 0.45, timingParameters: UISpringTimingParameters(
                    dampingRatio: 1, initialVelocity: CGVector(dx: 0, dy: lift != 0 ? speed / -lift : 0)))
                back.addAnimations { self.transform = .identity }
                back.startAnimation()
                settling = back
            }
        default:
            break
        }
    }
}

// MARK: - the room's light

/// A room's light: its space's colour, washed across the top and fading
/// down into a dusk; a deep violet dark for private; a soft grey with no
/// colour.
private struct RoomBackdrop: View {
    let tint: Color?
    let isPrivate: Bool

    var body: some View {
        let base = Color(.systemGroupedBackground)
        let light: Color = isPrivate ? Color(red: 0.36, green: 0.22, blue: 0.62) : (tint ?? Color(.systemGray3))
        let strength = isPrivate ? 0.6 : (tint == nil ? 0.4 : 0.5)
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.55],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                light.opacity(strength), light.opacity(strength * 0.75), light.opacity(strength * 0.9),
                light.opacity(strength * 0.35), light.opacity(strength * 0.15), light.opacity(strength * 0.3),
                light.opacity(strength * 0.2), base.opacity(0), light.opacity(strength * 0.15),
            ]
        )
        .background(base)
    }
}

// MARK: - your other devices

/// Your other devices' pages: what you were just reading on one, and each
/// device's tabs as cards.
private struct DevicesSheet: View {
    let browser: Browser
    let opened: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let offer = Elsewhere.continuing(from: browser.elsewhere, now: Date().timeIntervalSince1970,
                                                        frontHere: nil) {
                        ContinueCard(offer: offer) {
                            browser.open(offer)
                            opened()
                        }
                    }
                    ForEach(browser.elsewhere.filter(\.hasTabs), id: \.device) { device in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(device.name, systemImage: device.kind.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                                      spacing: 10) {
                                ForEach(Array(device.tabs.enumerated()), id: \.offset) { _, page in
                                    ElsewhereCard(page: page, openHere: browser.isOpenHere(page)) {
                                        browser.open(Elsewhere.Offer(device: device, page: page))
                                        opened()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("On Your Other Devices")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

/// The page you were just on, on another device: from there, as far as you
/// had read it.
private struct ContinueCard: View {
    let offer: Elsewhere.Offer
    let open: () -> Void

    var body: some View {
        let icon = SiteIcons.shared.icon(for: offer.page.address)
        Button(action: open) {
            HStack(spacing: 14) {
                Group {
                    if let icon {
                        Image(uiImage: icon).resizable().interpolation(.high).scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Image(systemName: offer.kind.symbol).font(.title2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Label("Continue from \(offer.deviceName)", systemImage: offer.kind.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(offer.page.shownTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let read = offer.page.scroll, read > 0.02 {
                        ProgressView(value: min(1, read))
                            .tint(icon.flatMap(SiteIcons.shared.accent(of:)) ?? .accentColor)
                            .accessibilityLabel("Read \(Int(read * 100)) percent")
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .accessibilityIdentifier("continue-card")
    }
}

/// One of another device's pages: its site's icon on a wash of its colour,
/// and its name.
private struct ElsewhereCard: View {
    let page: DeviceTabs.Page
    let openHere: Bool
    let open: () -> Void

    var body: some View {
        let icon = SiteIcons.shared.icon(for: page.address)
        let accent = icon.flatMap(SiteIcons.shared.accent(of:))
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Group {
                        if let icon {
                            Image(uiImage: icon).resizable().interpolation(.high).scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            Image(systemName: "globe").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    Spacer(minLength: 0)
                    if openHere {
                        Text("Open").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Text(page.shownTitle).font(.footnote.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(page.address?.host().map(Address.withoutWWW) ?? page.url)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background {
                LinearGradient(colors: [(accent ?? .gray).opacity(0.35), (accent ?? .gray).opacity(0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(openHere ? "Switches to it here" : "Opens it here")
        .accessibilityIdentifier("other-tab")
    }
}
