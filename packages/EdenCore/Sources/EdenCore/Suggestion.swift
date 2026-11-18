import Foundation

// A row under the address field: a page, a search, or something the app
// itself does. History and the field's other sources make them; each app
// draws them.

public struct Suggestion: Identifiable, Equatable, Sendable {
    /// What you could type to get here, kept reversible for completion.
    public let key: String
    public let title: String
    public let url: URL
    public let kind: Kind
    /// Set when this is a page you already have open somewhere.
    public var tab: UUID?

    public init(key: String, title: String, url: URL, kind: Kind, tab: UUID? = nil) {
        self.key = key
        self.title = title
        self.url = url
        self.kind = kind
        self.tab = tab
    }

    /// Something an app does from its address field, by an identifier of the
    /// app's own: the Mac's AddressCommand writes and reads it.
    public struct Command: Hashable, Sendable {
        public let id: String
        public init(_ id: String) { self.id = id }
    }

    public enum Kind: Equatable, Sendable {
        /// A page that is open right now.
        case open
        /// Somewhere you have actually been.
        case visited
        /// One of your bookmarks, the window's profile's.
        case bookmark
        /// One of the well-known addresses the field knows from the start.
        case known
        /// Not a place at all — words, and an engine to ask.
        case search
        /// Words the engine itself suggested, from what was typed so far
        /// (Settings › General › Suggestions from your search engine).
        case suggested
        /// Words you searched a site in the field for before, read from
        /// this window's history (SiteSearch.pastSearches).
        case searched
        /// Not a place either: something the app itself does.
        case command(Command)

        public var isCommand: Bool { if case .command = self { return true }; return false }
    }

    /// A command's row can read the same as the search for the same word
    /// ("Settings" typed with its capital), and two rows can't share a name.
    public var id: String {
        if kind.isCommand { return "command " + key }
        if case .suggested = kind { return "suggested " + key }
        // By the page: the same words searched on two sites are two rows.
        if case .searched = kind { return "searched " + History.identity(for: url) }
        if case .visited = kind { return History.identity(for: url) }
        if case .bookmark = kind { return History.identity(for: url) }
        return key
    }
}
