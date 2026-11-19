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
