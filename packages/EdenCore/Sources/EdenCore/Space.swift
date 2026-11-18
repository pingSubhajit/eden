import Foundation

// A space: a set of tabs of its own, with its name, colour and icon, and
// whether it shares the first space's sign-ins. How it is drawn is each
// app's own (Spaces.swift on the Mac); this is what it is, and what syncs
// (SyncMerge).

public struct Space: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Which of the app's colours its icon wears, so a glance at the dot
    /// says which space this is. 0 is none, the grey every space had: the
    /// field dates from before icons, and every list from then reads 0.
    public var colour: Int
    /// Its icon, one of the app's symbols.
    public var icon: String?
    /// Signed in wherever the first space is — the same cookies and
    /// sign-ins, only the tabs its own — rather than a store of its own.
    /// Chosen when it is made; nil, for a space from before the choice, is
    /// a store of its own.
    public var sharesSignIns: Bool?
    /// Where this space's downloads go; nil for the folder in Settings.
    public var downloads: String?
    /// The profile it belongs to; nil for Personal, which every space from
    /// before profiles is in.
    public var profile: UUID?

    public init(id: UUID, name: String, colour: Int, icon: String? = nil, sharesSignIns: Bool? = nil,
                downloads: String? = nil, profile: UUID? = nil) {
        self.id = id
        self.name = name
        self.colour = colour
        self.icon = icon
        self.sharesSignIns = sharesSignIns
        self.downloads = downloads
        self.profile = profile
    }

    /// The Personal profile's id, the profile every space from before
    /// profiles is in (Profiles.swift on the Mac).
    public static let personalProfileID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1") ?? UUID()

    /// The first space: the session and the store there were before spaces.
    public static let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    public var isFirst: Bool { id == Space.firstID }
    public static func first() -> Space { Space(id: firstID, name: "Personal", colour: 0) }
}
