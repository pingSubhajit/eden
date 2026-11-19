import Foundation

// A pin: what makes a pinned tab a pin, the same in every window — its
// letter, its name, the page it was pinned at, its place. The pins of each
// space are each app's own to keep (Pins.swift on the Mac); this is what
// they keep, and what syncs (SyncMerge).

public struct PinDef: Codable, Equatable, Sendable {
    public var id: UUID
    public var letter: String
    /// The page it was pinned at (see Browser.goHome).
    public var home: String
    public var title: String
    public var name: String?
    /// A row, not a square (see Tab.listed). Nil rather than false, so a
    /// pins file with no rows in it is written as it always was.
    public var listed: Bool? = nil
    /// The folder among the pinned rows that holds it (see PinFolders.swift),
    /// nil at the top of them. Written only when it is in one, so the file
    /// is unchanged for anyone with no folders.
    public var folder: UUID? = nil

    public init(id: UUID, letter: String, home: String, title: String, name: String? = nil,
                listed: Bool? = nil, folder: UUID? = nil) {
        self.id = id
        self.letter = letter
        self.home = home
        self.title = title
        self.name = name
        self.listed = listed
        self.folder = folder
    }
}

extension PinDef {
    /// The same page, give or take a trailing slash on its path: a pin's tab
    /// at its home, two pins of one page (SyncItems.applyPins), a tab open
    /// already. Its query and fragment are its own: `?q=/` is not `?q=`.
    public static func samePage(_ one: URL?, _ other: URL?) -> Bool {
        guard let one, let other else { return false }
        func bare(_ url: URL) -> String {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
            while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
            return parts.string ?? url.absoluteString
        }
        return bare(one) == bare(other)
    }

    /// Whether a pin's tab showing `page` is at its home: then it is the pin,
    /// which every device has already, rather than one of this device's open
    /// tabs to offer the others. Gone on to another page, it is that page.
    public static func atHome(_ home: URL?, showing page: URL?) -> Bool {
        samePage(home, page)
    }
}
