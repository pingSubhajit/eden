import Foundation

// Kinds of item that sync through iCloud (CloudSync) besides the ones the
// Mac's folder sync always carried (SyncItems in SyncMerge.swift): each
// device's open tabs, and history (History.syncItems).

/// A device's open tabs, as its other devices show them. Written by that
/// device alone, under its own key; never a private tab.
public struct DeviceTabs: Codable, Equatable, Sendable {
    public struct Page: Codable, Equatable, Sendable {
        public var url: String
        public var title: String

        public init(url: String, title: String) {
            self.url = url
            self.title = title
        }
    }

    /// The device's id (the key it syncs under), name and kind.
    public var device: String
    public var name: String
    public var kind: Kind
    public var tabs: [Page]
    /// When it last wrote them, seconds since 1970.
    public var at: Double

    public enum Kind: String, Codable, Sendable {
        case mac, iphone, ipad
    }

    public init(device: String, name: String, kind: Kind, tabs: [Page], at: Double) {
        self.device = device
        self.name = name
        self.kind = kind
        self.tabs = tabs
        self.at = at
    }
}

extension SyncItems {
    /// The key a device's open tabs sync under.
    public static func tabsKey(_ device: String) -> String { "tabs:" + device }

    /// This device's open tabs as its one item.
    public static func tabs(_ mine: DeviceTabs) -> [String: String] {
        SyncMerge.text(mine).map { [tabsKey(mine.device): $0] } ?? [:]
    }

    /// The other devices' open tabs, newest first: the ones heard from in
    /// the last 30 days, with at least one tab.
    public static func otherTabs(_ live: [String: String], except device: String, now: Double,
                                 within: Double = 30 * 24 * 60 * 60) -> [DeviceTabs] {
        live.compactMap { key, text -> DeviceTabs? in
            guard key.hasPrefix("tabs:"), key != tabsKey(device),
                  let tabs = SyncMerge.value(DeviceTabs.self, text),
                  now - tabs.at <= within, !tabs.tabs.isEmpty else { return nil }
            return tabs
        }
        .sorted { $0.at > $1.at }
    }
}
