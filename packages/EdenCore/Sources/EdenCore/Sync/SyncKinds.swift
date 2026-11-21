import Foundation

// Kinds of item that sync through iCloud (CloudSync) besides the ones the
// Mac's folder sync always carried (SyncItems in SyncMerge.swift): each
// device's open tabs, and history (History.syncItems).

/// A device's open tabs, as its other devices show them. Written by that
/// device alone, under its own key; never a private tab. Everything past the
/// tabs themselves is optional: an Eden from before reads the tabs and
/// passes over the rest, and one from before writes none of it.
public struct DeviceTabs: Codable, Equatable, Sendable {
    public struct Page: Codable, Equatable, Sendable {
        public var url: String
        public var title: String
        /// The space it is open in (Space.id); nil from an Eden from before.
        public var space: UUID?
        /// How far down it is read, nought to one, in twentieths: nought at
        /// the top; nil from an Eden from before, which didn't say.
        public var scroll: Double?
        /// Shown as its article (reading mode); nil when not.
        public var reading: Bool?

        public init(url: String, title: String, space: UUID? = nil, scroll: Double? = nil, reading: Bool? = nil) {
            self.url = url
            self.title = title
            self.space = space
            self.scroll = scroll
            self.reading = reading
        }

        /// A reading position as it is sent: in twentieths, so reading down a
        /// page changes it a few times rather than at every frame.
        public static func scroll(_ fraction: Double) -> Double {
            (min(1, max(0, fraction)) * 20).rounded() / 20
        }
    }

    /// A page closed on the device a moment ago.
    public struct Closed: Codable, Equatable, Sendable {
        public var url: String
        public var title: String
        public var space: UUID?
        /// When, seconds since 1970.
        public var at: Double

        public init(url: String, title: String, space: UUID? = nil, at: Double) {
            self.url = url
            self.title = title
            self.space = space
            self.at = at
        }
    }

    /// The device's id (the key it syncs under), name and kind.
    public var device: String
    public var name: String
    public var kind: Kind
    public var tabs: [Page]
    /// When it last wrote them, seconds since 1970.
    public var at: Double
    /// Which of `tabs` was in front.
    public var front: Int?
    /// When Eden was last in use on the device, seconds since 1970, to the
    /// minute.
    public var seen: Double?
    /// Pages closed there in the last few minutes (DeviceTabs.closedLife),
    /// newest last.
    public var closed: [Closed]?

    public enum Kind: String, Codable, Sendable {
        case mac, iphone, ipad
    }

    public init(device: String, name: String, kind: Kind, tabs: [Page], at: Double,
                front: Int? = nil, seen: Double? = nil, closed: [Closed]? = nil) {
        self.device = device
        self.name = name
        self.kind = kind
        self.tabs = tabs
        self.at = at
        self.front = front
        self.seen = seen
        self.closed = closed
    }

    /// How long a closed page is offered to the other devices.
    public static let closedLife: Double = 10 * 60
    /// How long after it was put down a device's page in front is offered to
    /// be continued.
    public static let continueLife: Double = 15 * 60

    /// Whether it has a tab open.
    public var hasTabs: Bool { !tabs.isEmpty }

    /// The page in front, if it said.
    public var frontPage: Page? { front.flatMap { tabs.indices.contains($0) ? tabs[$0] : nil } }

    /// Whether `other` says the same, whenever it was written: it is
    /// stamped afresh only when what it says changed.
    public func says(_ other: DeviceTabs) -> Bool {
        var same = other
        same.at = at
        return same == self
    }

    /// The pages closed in the last few minutes, the oldest gone: what a
    /// device keeps to send, at most `limit`.
    public static func recent(_ closed: [Closed], now: Double, limit: Int = 10) -> [Closed] {
        Array(closed.filter { now - $0.at < closedLife }.suffix(limit))
    }
}

/// Your other devices' pages as this one offers them: one to carry on with,
/// the ones just closed, and those answering to what is typed. Pure, so the
/// tests can hold it; each app draws them.
public enum Elsewhere {
    /// A page open on another device, and which.
    public struct Offer: Equatable, Sendable {
        public let device: String
        public let deviceName: String
        public let kind: DeviceTabs.Kind
        public let page: DeviceTabs.Page

        public init(device: DeviceTabs, page: DeviceTabs.Page) {
            self.init(device: device.device, deviceName: device.name, kind: device.kind, page: page)
        }

        /// `device`: its id as it syncs, empty when not known (a page handed
        /// over, Continuity.offer).
        public init(device: String, deviceName: String, kind: DeviceTabs.Kind, page: DeviceTabs.Page) {
            self.device = device
            self.deviceName = deviceName
            self.kind = kind
            self.page = page
        }
    }

    /// The page in front on the device put down most lately, in the last
    /// quarter of an hour — unless it is already the page in front here.
    /// `frontHere`: the page in front here, by History.identity.
    public static func continuing(from devices: [DeviceTabs], now: Double, frontHere: String?) -> Offer? {
        let lately = devices.filter { device in device.seen.map { now - $0 < DeviceTabs.continueLife } ?? false }
        guard let device = lately.max(by: { ($0.seen ?? 0) < ($1.seen ?? 0) }), let page = device.frontPage,
              let url = URL(string: page.url) else { return nil }
        return History.identity(for: url) == frontHere ? nil : Offer(device: device, page: page)
    }

    /// The pages closed on the other devices in the last few minutes, newest
    /// first, each once, none still open here. `openHere`: by History.identity.
    public static func closed(on devices: [DeviceTabs], now: Double, openHere: Set<String>, limit: Int = 3) -> [Offer] {
        var seen = openHere
        let all = devices.flatMap { device in
            (device.closed ?? []).filter { now - $0.at < DeviceTabs.closedLife }.map { (device, $0) }
        }
        return all.sorted { $0.1.at > $1.1.at }.compactMap { device, closed -> Offer? in
            guard let url = URL(string: closed.url), seen.insert(History.identity(for: url)).inserted else { return nil }
            return Offer(device: device, page: DeviceTabs.Page(url: closed.url, title: closed.title, space: closed.space))
        }
        .prefix(limit).map { $0 }
    }

    /// The other devices' open pages answering to what is typed, by title or
    /// address, none already open here: freshest device first.
    public static func matching(_ typed: String, in devices: [DeviceTabs], openHere: Set<String>, limit: Int = 3) -> [Offer] {
        let needle = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var seen = openHere
        var out: [Offer] = []
        for device in devices {
            for page in device.tabs where out.count < limit {
                guard let url = URL(string: page.url),
                      (page.title + " " + page.url).lowercased().contains(needle),
                      seen.insert(History.identity(for: url)).inserted else { continue }
                out.append(Offer(device: device, page: page))
            }
        }
        return out
    }

    /// A device's pages by the space they are open in, in `order` — the
    /// spaces this device has — and the rest (no space said, or one unknown
    /// here) last, under nil.
    public static func bySpace(_ pages: [DeviceTabs.Page], order: [UUID]) -> [(space: UUID?, pages: [DeviceTabs.Page])] {
        let known = Set(order)
        var groups: [(UUID?, [DeviceTabs.Page])] = order.compactMap { space in
            let mine = pages.filter { $0.space == space }
            return mine.isEmpty ? nil : (space, mine)
        }
        let rest = pages.filter { page in page.space.map { !known.contains($0) } ?? true }
        if !rest.isEmpty { groups.append((nil, rest)) }
        return groups
    }
}

extension SyncItems {
    /// The key a device's open tabs sync under.
    public static func tabsKey(_ device: String) -> String { "tabs:" + device }

    /// This device's open tabs as its one item.
    public static func tabs(_ mine: DeviceTabs) -> [String: String] {
        SyncMerge.text(mine).map { [tabsKey(mine.device): $0] } ?? [:]
    }

    /// The other devices' tabs, newest first: the ones heard from in the
    /// last 30 days with a tab open, or one closed a moment ago (lists of
    /// open tabs pass over the second: DeviceTabs.hasTabs).
    public static func otherTabs(_ live: [String: String], except device: String, now: Double,
                                 within: Double = 30 * 24 * 60 * 60) -> [DeviceTabs] {
        live.compactMap { key, text -> DeviceTabs? in
            guard key.hasPrefix("tabs:"), key != tabsKey(device),
                  let tabs = SyncMerge.value(DeviceTabs.self, text),
                  now - tabs.at <= within, tabs.hasTabs || !(tabs.closed ?? []).isEmpty else { return nil }
            return tabs
        }
        .sorted { $0.at > $1.at }
    }
}

/// Another device asked one of its pages closed here: sent from the list of
/// this device's tabs there, as Chrome's Tabs from Other Devices can close
/// one. Its own item, "close:<this device>:<id>", which only this device
/// speaks for: it closes the page and, never writing the item itself,
/// deletes it everywhere at its next pass. The device that asked writes it
/// once and then only carries it.
public struct CloseAsk: Codable, Equatable, Sendable {
    /// The page, as the asking device had it from this one's tabs.
    public var url: String
    /// When it was asked, seconds since 1970.
    public var at: Double

    public init(url: String, at: Double) {
        self.url = url
        self.at = at
    }

    /// How long an ask stands: a device away longer than this doesn't come
    /// back to find its tabs closing on their own.
    public static let life: Double = 3 * 24 * 60 * 60
}

/// Asks whose tabs didn't reach disk (SyncItems.answer), left a while
/// before they are tried again. Writing their tabs tells sync of a change,
/// which comes back as another pass; a file that couldn't be written then
/// failed again, and again, every moment. Each failure waits twice as long
/// as the last, from a few seconds to a few minutes, and the ask is tried
/// at the first pass after that.
public struct AskRetries: Sendable {
    private var waits: [String: (until: Double, wait: Double)] = [:]

    public static let first: Double = 5
    public static let longest: Double = 5 * 60

    public init() {}

    /// Whether `key` may be tried now.
    public func ready(_ key: String, now: Double) -> Bool {
        waits[key].map { now >= $0.until } ?? true
    }

    /// Tried, and their tabs didn't land: how long the longest of them
    /// now waits.
    @discardableResult
    public mutating func failed(_ keys: some Sequence<String>, now: Double) -> Double {
        var longest: Double = 0
        for key in keys {
            let wait = waits[key].map { min($0.wait * 2, Self.longest) } ?? Self.first
            waits[key] = (now + wait, wait)
            longest = max(longest, wait)
        }
        return longest
    }

    /// Done, or gone: nothing more to wait for.
    public mutating func forget(_ keys: some Sequence<String>) {
        for key in keys { waits[key] = nil }
    }

    /// Only the asks still standing (`keys`, those among the items): one
    /// gone or out of date waits for nothing, and isn't kept for as long
    /// as the app is open.
    public mutating func keep(_ keys: Set<String>) {
        waits = waits.filter { keys.contains($0.key) }
    }
}

/// Another device asked a page opened here: one of its tabs carried onto
/// this device's group in its list of your devices' tabs. The same life as
/// a CloseAsk: its own item, "open:<this device>:<id>", which only this
/// device speaks for — it opens the page, behind the one in front, and the
/// item goes everywhere at its next pass — written once by the device that
/// asked and then only carried.
public struct OpenAsk: Codable, Equatable, Sendable {
    /// The page, as it stood on the device that sent it: its address and
    /// title, and the space it was in, opened in that space here when this
    /// device has it.
    public var page: DeviceTabs.Page
    /// When it was asked, seconds since 1970.
    public var at: Double

    public init(page: DeviceTabs.Page, at: Double) {
        self.page = page
        self.at = at
    }
}

extension SyncItems {
    /// The key of an ask to open a page on `device`.
    public static func openKey(_ device: String, id: String) -> String { "open:" + device + ":" + id }

    /// Whether `key` asks a page opened on `device`: that device's own, to
    /// act on and delete.
    public static func asksToOpen(_ key: String, on device: String) -> Bool { key.hasPrefix("open:" + device + ":") }

    /// An ask to open `page` on `device`, as its one item.
    public static func ask(open page: DeviceTabs.Page, on device: String, now: Double,
                           id: String = UUID().uuidString) -> [String: String] {
        SyncMerge.text(OpenAsk(page: page, at: now)).map { [openKey(device, id: id): $0] } ?? [:]
    }

    /// The asks to open pages on `device` that still stand, by key.
    public static func openAsks(_ live: [String: String], on device: String, now: Double) -> [String: OpenAsk] {
        var out: [String: OpenAsk] = [:]
        for (key, text) in live where asksToOpen(key, on: device) {
            guard let ask = SyncMerge.value(OpenAsk.self, text), now - ask.at <= CloseAsk.life else { continue }
            out[key] = ask
        }
        return out
    }

    /// Whether `key` asks something of `device`, to close a page or to open
    /// one: its own, never written by it, deleted everywhere once acted on.
    public static func asks(_ key: String, of device: String) -> Bool {
        asksToClose(key, on: device) || asksToOpen(key, on: device)
    }

    /// Asks of this device done by `act` — tabs closed or opened — and only
    /// counted as done once they are on disk: `rewrite` writes again, whole,
    /// every store of tabs `act` may have changed, and the asks are done when
    /// every one of those writes landed (true), to go (`standingAsks`'s
    /// `answered`). Counted done with the tabs not yet on disk, a crash in
    /// between lost a page sent here, or brought back one closed. Written
    /// again each time, not only as `act` changes something: tried again
    /// after a write that failed, `act` finds the page already open, or
    /// gone, and changes nothing, and the tabs as they are must still land.
    /// False, and the asks stand, to be done again at the next pass. Only
    /// the files `rewrite` writes have a say: a file of something else that
    /// failed meanwhile — the pages closed a while ago, say, written as a tab
    /// closes — kept every ask standing for as long as it went on failing.
    @MainActor
    public static func answer(_ act: () -> Void, rewrite: () -> Void) -> Bool {
        let mark = Disk.mark()
        act()
        let rewritten = Disk.recording(rewrite)
        return Disk.drain(since: mark, only: rewritten)
    }

    /// An ask's key as the logs say it: what it asks and its id, never the
    /// device's id with it, nor the page.
    public static func askLabel(_ key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return key }
        return parts[0] + " " + parts[2]
    }

    /// Asks' keys as the logs say them, in one line.
    public static func askLabels(_ keys: some Sequence<String>) -> String {
        keys.map(askLabel).sorted().joined(separator: ", ")
    }

    /// The asks of `device` among `agreed` that it has done (`answered`):
    /// the ones its snapshot leaves out, to go everywhere.
    public static func answeredAsks(_ agreed: [String: String], of device: String, answered: Set<String>) -> [String] {
        agreed.keys.filter { asks($0, of: device) && answered.contains($0) }.sorted()
    }

    /// Whether `key` asks something of any device.
    public static func isAsk(_ key: String) -> Bool {
        key.hasPrefix("close:") || key.hasPrefix("open:")
    }

    /// The asks of `device` it hasn't acted on yet, as `agreed` has them:
    /// its snapshot says them back unchanged, so they stand until what they
    /// ask is done — closed or opened, and written down — rather than going
    /// at the next pass with the work still to do, lost if the app quit in
    /// between. Acted on (`answered`), or older than they stand, it leaves
    /// them out, and they go everywhere. Acted on again after a relaunch,
    /// nothing changes twice: a page closed is gone, one open isn't opened
    /// again.
    public static func standingAsks(_ agreed: [String: String], of device: String,
                                    answered: Set<String>, now: Double) -> [String: String] {
        agreed.filter { key, text in
            guard asks(key, of: device), !answered.contains(key) else { return false }
            if asksToClose(key, on: device) {
                return SyncMerge.value(CloseAsk.self, text).map { now - $0.at <= CloseAsk.life } ?? false
            }
            return SyncMerge.value(OpenAsk.self, text).map { now - $0.at <= CloseAsk.life } ?? false
        }
    }
}

extension SyncItems {
    /// The rule every device keeps for asks about one device's pages, to
    /// close one or to open one: for each page (`page`, History.identity)
    /// only the newest ask decides. A close after an open leaves the page
    /// closed, an open after a close opens it; the older asks for that page
    /// count for nothing, and are answered along with the newest. Two asks
    /// of the same moment go to the greater key, so every device picks the
    /// same one. Each page's newest ask with the older ones for it, the
    /// pages in the order of their newest asks.
    public static func newestPerPage<Ask>(_ asks: [Ask], page: (Ask) -> String, at: (Ask) -> Double,
                                          key: (Ask) -> String) -> [(newest: Ask, older: [Ask])] {
        func newer(_ a: Ask, _ b: Ask) -> Bool { at(a) != at(b) ? at(a) > at(b) : key(a) > key(b) }
        let groups = Dictionary(grouping: asks, by: page).values.map { group -> (newest: Ask, older: [Ask]) in
            let sorted = group.sorted(by: newer)
            return (sorted[0], Array(sorted.dropFirst()))
        }
        return groups.sorted { newer($1.newest, $0.newest) }
    }

    /// What another device asked of `device` to do now, by the rule above:
    /// for each page, its newest ask standing, unless it is being done
    /// (`answering`), was done already (`answered`), or waits to be tried
    /// again (not `ready`); and with it, the older asks for that page not
    /// already done or being done, answered in the same step. A page whose
    /// newest ask was done already has nothing left to do: only its older
    /// asks, ones heard of since, which go with it.
    public static func dueAsks(_ live: [String: String], on device: String, now: Double,
                               answered: Set<String>, answering: Set<String>,
                               ready: (String) -> Bool) -> DueAsks {
        enum Asked {
            case close(CloseAsk)
            case open(OpenAsk)
        }
        struct Standing {
            let key: String
            let page: String
            let at: Double
            let ask: Asked
        }
        // A page whose address doesn't read is a page of its own.
        let page = { (url: String, key: String) in URL(string: url).map(History.identity(for:)) ?? key }
        let standing = closeAsks(live, on: device, now: now).map { key, ask in
            Standing(key: key, page: page(ask.url, key), at: ask.at, ask: .close(ask))
        } + openAsks(live, on: device, now: now).map { key, ask in
            Standing(key: key, page: page(ask.page.url, key), at: ask.at, ask: .open(ask))
        }
        var due = DueAsks()
        let open = { (key: String) in !answered.contains(key) && !answering.contains(key) }
        for (newest, older) in newestPerPage(standing, page: \.page, at: \.at, key: \.key) {
            guard !answering.contains(newest.key), ready(newest.key) else { continue }
            for ask in older where open(ask.key) { due.overtaken[ask.key] = newest.key }
            guard !answered.contains(newest.key) else { continue }
            switch newest.ask {
            case .close(let ask): due.closing[newest.key] = ask
            case .open(let ask): due.opening[newest.key] = ask
            }
        }
        return due
    }
}

/// The asks of a device to do now (SyncItems.dueAsks): the pages to close
/// and to open, each its page's newest ask, and the older asks they
/// overtake, done with them.
public struct DueAsks: Equatable, Sendable {
    public var closing: [String: CloseAsk] = [:]
    public var opening: [String: OpenAsk] = [:]
    /// Each older ask, with the newest ask for its page that overtakes it.
    public var overtaken: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool { closing.isEmpty && opening.isEmpty && overtaken.isEmpty }

    /// Every ask taken up, to close, to open or overtaken.
    public var keys: Set<String> { Set(closing.keys).union(opening.keys).union(overtaken.keys) }

    /// The asks done once the pages are closed and, if `opened`, opened:
    /// an open that waits (a Mac with no window to open it in) keeps the
    /// asks it overtakes standing with it, so none goes before what
    /// decides its page is done.
    public func done(opened: Bool) -> Set<String> {
        var out = Set(closing.keys)
        if opened { out.formUnion(opening.keys) }
        for (older, newest) in overtaken where opened || opening[newest] == nil { out.insert(older) }
        return out
    }

    /// The pages to close, by History.identity.
    public var pagesToClose: Set<String> {
        Set(closing.values.compactMap { URL(string: $0.url).map(History.identity(for:)) })
    }

    /// The pages to open, the ones asked first first.
    public var pagesToOpen: [DeviceTabs.Page] {
        opening.values.sorted { $0.at < $1.at }.map(\.page)
    }
}

extension SyncItems {
    /// When an ask about `page` (History.identity) of `device`, written
    /// now, says it was asked: now, or just after the newest ask about that
    /// page among `items` if that is later. The device that asks second
    /// has seen the first ask, so its ask stays the newer one even when
    /// the first came from a device whose clock runs ahead: the later
    /// choice is the one that counts (newestPerPage).
    public static func askTime(for page: String, of device: String, among items: [String: String],
                               now: Double) -> Double {
        let newest = (closeAsks(items, on: device, now: now).values.compactMap { ask -> Double? in
            URL(string: ask.url).map(History.identity(for:)) == page ? ask.at : nil
        } + openAsks(items, on: device, now: now).values.compactMap { ask -> Double? in
            URL(string: ask.page.url).map(History.identity(for:)) == page ? ask.at : nil
        }).max()
        return newest.map { max(now, $0 + 0.001) } ?? now
    }
}

extension SyncItems {
    /// The key of an ask to close a page on `device`.
    public static func closeKey(_ device: String, id: String) -> String { "close:" + device + ":" + id }

    /// Whether `key` asks a page closed on `device`: those are that device's
    /// own, to act on and delete.
    public static func asksToClose(_ key: String, on device: String) -> Bool { key.hasPrefix("close:" + device + ":") }

    /// An ask to close `url` on `device`, as its one item.
    public static func ask(close url: String, on device: String, now: Double,
                           id: String = UUID().uuidString) -> [String: String] {
        SyncMerge.text(CloseAsk(url: url, at: now)).map { [closeKey(device, id: id): $0] } ?? [:]
    }

    /// The asks to close pages on `device` that still stand, by key.
    public static func closeAsks(_ live: [String: String], on device: String, now: Double) -> [String: CloseAsk] {
        var out: [String: CloseAsk] = [:]
        for (key, text) in live where asksToClose(key, on: device) {
            guard let ask = SyncMerge.value(CloseAsk.self, text), now - ask.at <= CloseAsk.life else { continue }
            out[key] = ask
        }
        return out
    }
}

extension Elsewhere {
    /// A page asked closed on another device, or opened there, shown so in
    /// its list here for as long as the ask stands.
    public struct Asked: Equatable, Sendable {
        public let device: String
        /// The page, by History.identity.
        public let page: String
        public let at: Double
        /// The ask's item: the device deletes it once it has done what it
        /// asks, and that is its answer.
        public let key: String
        /// The page asked opened there; nil for one asked closed.
        public let opening: DeviceTabs.Page?

        public init(device: String, page: String, at: Double, key: String, opening: DeviceTabs.Page? = nil) {
            self.device = device
            self.page = page
            self.at = at
            self.key = key
            self.opening = opening
        }
    }

    /// `devices` as asked of them — without the pages asked closed there,
    /// with those asked opened at the end of the list — while each ask
    /// stands (`standing`: the asks among the items, and those written here
    /// and not yet sent); and the asks still waiting. For each page only
    /// its newest ask counts (SyncItems.newestPerPage), as on the device
    /// itself: a page sent there and then closed is gone, one closed and
    /// sent again is there. Its device deletes an ask in the same pass as
    /// it says the tabs that answer it, so the list never shows the page as
    /// it was in between. Not by when the device last said its tabs: that
    /// may be before the ask reached it, or by a clock that runs ahead.
    public static func asAsked(_ devices: [DeviceTabs], asked: [Asked], standing: Set<String>,
                               now: Double) -> (devices: [DeviceTabs], waiting: [Asked]) {
        let waiting = asked.filter { ask in now - ask.at <= CloseAsk.life && standing.contains(ask.key) }
        guard !waiting.isEmpty else { return (devices, []) }
        let shown = devices.map { device -> DeviceTabs in
            let mine = SyncItems.newestPerPage(waiting.filter { $0.device == device.device },
                                               page: \.page, at: \.at, key: \.key).map(\.newest)
            guard !mine.isEmpty else { return device }
            let gone = Set(mine.filter { $0.opening == nil }.map(\.page))
            var kept = device
            let front = device.frontPage
            kept.tabs = device.tabs.filter { page in
                URL(string: page.url).map { !gone.contains(History.identity(for: $0)) } ?? true
            }
            var there = Set(kept.tabs.compactMap { URL(string: $0.url).map(History.identity(for:)) })
            for ask in mine {
                guard let page = ask.opening, there.insert(ask.page).inserted else { continue }
                kept.tabs.append(page)
            }
            kept.front = front.flatMap { kept.tabs.firstIndex(of: $0) }
            return kept
        }
        return (shown, waiting)
    }
}
