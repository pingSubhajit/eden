import Foundation

// A bookmark: a site, or a folder of them. The list and its file are each
// app's own (Bookmarks.swift on the Mac); this is what they hold, and what
// syncs (SyncMerge).

public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    /// Nil for a folder.
    public var url: String?
    public var children: [Bookmark]?

    public init(id: UUID = UUID(), title: String, url: String?, children: [Bookmark]?) {
        self.id = id
        self.title = title
        self.url = url
        self.children = children
    }

    public var isFolder: Bool { url == nil }

    /// A bookmark whose name was emptied, as in Chrome and Safari: on the
    /// bar it is its icon alone. There is no setting; emptying it is the
    /// choice. A folder always has a name.
    public var unnamed: Bool {
        !isFolder && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What a list reads it as: its name, or for one without, its address
    /// as the address field shows it, so the list is still readable.
    public var label: String {
        guard unnamed else { return title }
        return url.flatMap { URL(string: $0) }.map(Address.pretty) ?? url ?? ""
    }

    public var host: String? {
        url.flatMap { URL(string: $0)?.host()?.lowercased() }
    }

    public var address: URL? {
        url.flatMap { URL(string: $0) }
    }

    public static func site(_ title: String, _ url: URL) -> Bookmark {
        Bookmark(title: title.isEmpty ? Address.pretty(url) : title, url: url.absoluteString, children: nil)
    }

    public static func folder(_ title: String, _ children: [Bookmark]) -> Bookmark {
        Bookmark(title: title, url: nil, children: children)
    }
}
