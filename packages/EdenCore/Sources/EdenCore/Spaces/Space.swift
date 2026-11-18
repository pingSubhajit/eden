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

extension Space {
    /// The profile it is in: Personal for a space from before profiles.
    public var profileID: UUID { profile ?? Space.personalProfileID }

    /// The icon it shows: its own, while it is one the app knows, else a
    /// house for the first space and a briefcase for any other. What it
    /// keeps is never changed: a newer Eden's icon comes back with it.
    public var symbol: String {
        icon.flatMap { SpaceAppearance.icons.contains($0) ? $0 : nil } ?? (isFirst ? "house" : "briefcase")
    }

    /// Its colour's place in SpaceAppearance.colours, or nil for none — and
    /// for one out of range, from a newer Eden.
    public var tintIndex: Int? { colour > 0 && SpaceAppearance.colours.indices.contains(colour) ? colour : nil }

    /// The website store its tabs use. `profileHome`: its profile's home
    /// space, which uses the profile's store as Personal's first space does.
    public func storeKey(profileHome: UUID) -> SpaceStoreKey {
        id == Space.firstID || id == profileHome || sharesSignIns == true ? .profile(profileID) : .space(id)
    }
}

/// Whose cookies and sign-ins a space's tabs have: its profile's — for
/// Personal, the store there always was — or a store of its own, made by
/// the space's id. A space from before the choice (sharesSignIns nil) has
/// its own.
public enum SpaceStoreKey: Hashable, Sendable {
    case profile(UUID)
    case space(UUID)
}

/// What a space can look like: the icons and colours to choose from, the
/// same on every device, by their place in these lists — which is what
/// syncs, so they only ever grow at the end.
public enum SpaceAppearance {
    public struct Colour: Equatable, Sendable {
        public let red, green, blue: Double
    }

    /// A handful, picked to read on the light ground and the dark one alike.
    /// The first stands for none and is never drawn.
    public static let colours: [Colour] = [
        Colour(red: 0.45, green: 0.47, blue: 0.52), // none
        Colour(red: 0.26, green: 0.52, blue: 0.96), // blue
        Colour(red: 0.20, green: 0.66, blue: 0.45), // green
        Colour(red: 0.96, green: 0.62, blue: 0.20), // orange
        Colour(red: 0.90, green: 0.33, blue: 0.40), // red
        Colour(red: 0.62, green: 0.40, blue: 0.90), // violet
    ]
    public static let colourNames = ["None", "Blue", "Green", "Orange", "Red", "Violet"]

    /// The icons a space can wear: Apple's own symbols, grouped as work,
    /// thinking, leisure and life.
    public static let icons = [
        "briefcase", "building.2", "desktopcomputer", "laptopcomputer", "chevron.left.forwardslash.chevron.right", "terminal",
        "sparkles", "brain.head.profile", "lightbulb", "gamecontroller", "beach.umbrella", "cup.and.saucer",
        "music.note", "film", "paintpalette", "camera", "house", "book",
        "graduationcap", "cart", "airplane", "dumbbell", "leaf", "heart",
    ]
    public static let iconNames = [
        "Work", "Office", "Desktop", "Laptop", "Code", "Terminal",
        "AI", "Thinking", "Ideas", "Games", "Leisure", "Café",
        "Music", "Film", "Art", "Photos", "Home", "Reading",
        "Studies", "Shopping", "Travel", "Sport", "Nature", "Personal",
    ]

    /// The icon a new space gets unless told: the first none of `spaces`
    /// wears yet.
    public static func freeIcon(among spaces: [Space]) -> String {
        let used = Set(spaces.map(\.symbol))
        return icons.first { !used.contains($0) } ?? "briefcase"
    }
}
