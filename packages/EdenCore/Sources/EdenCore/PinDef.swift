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
