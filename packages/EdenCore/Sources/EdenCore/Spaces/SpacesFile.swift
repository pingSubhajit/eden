import Foundation

/// spaces.json: every space of every profile, in the order the user
/// arranged them. Each profile's home — Personal's first space, or the one a
/// profile was made with — need not lead its block: it can be moved.
///
/// The repairs are the same on every device: the first space appears once,
/// in Personal, where it was put; a file without it gets it back at the
/// front; and a file from before spaces could be moved reads each profile's
/// home first.
public enum SpacesFile {
    public static func decode(_ data: Data) throws -> [Space] {
        try JSONDecoder().decode([Space].self, from: data)
    }

    public static func encode(_ spaces: [Space]) throws -> Data {
        try JSONEncoder().encode(spaces)
    }

    /// Every space, as `saved` has them, repaired. `orderKept`: the user has
    /// moved one (the order is theirs, whatever it looks like). `home`: each
    /// profile's home space, Personal's being Space.firstID.
    public static func spaces(from saved: [Space], orderKept: Bool, home: (UUID) -> UUID?) -> [Space] {
        guard !saved.isEmpty else { return [Space.first()] }
        var foundFirst = false
        var spaces = saved.compactMap { space -> Space? in
            guard space.isFirst else { return space }
            // Once, and in Personal, without moving it from where it was put.
            guard !foundFirst else { return nil }
            foundFirst = true
            var space = space
            space.profile = nil
            return space
        }
        if !spaces.contains(where: \.isFirst) { spaces.insert(Space.first(), at: 0) }
        if keepsOrder(saved, orderKept: orderKept, home: home) { return spaces }
        return spaces.filter(\.isFirst) + spaces.filter { !$0.isFirst }
    }

    /// One profile's spaces, in their order: home first unless the order is
    /// the user's. `all`: every space, repaired (spaces(from:)).
    public static func spaces(of profile: UUID, in all: [Space], saved: [Space], orderKept: Bool,
                              home: (UUID) -> UUID?) -> [Space] {
        let mine = all.filter { $0.profileID == profile }
        guard !keepsOrder(saved, orderKept: orderKept, home: home) else { return mine }
        let first = homeID(of: profile, home: home) ?? mine.first?.id ?? Space.firstID
        return mine.filter { $0.id == first } + mine.filter { $0.id != first }
    }

    /// The whole list with one profile's spaces as `spaces` now has them, in
    /// that order, after every other profile's, which are kept as they were.
    public static func replacing(profile: UUID, in all: [Space], with spaces: [Space]) -> [Space] {
        let mine = spaces.map { space -> Space in
            var space = space
            space.profile = profile == Space.personalProfileID ? nil : profile
            return space
        }
        return all.filter { $0.profileID != profile } + mine
    }

    /// Whether a list carries the user's order: they said so, or a profile's
    /// home is away from the front of its block, as only a move could have
    /// put it (an older Eden's move left no other mark).
    static func keepsOrder(_ spaces: [Space], orderKept: Bool, home: (UUID) -> UUID?) -> Bool {
        if orderKept { return true }
        for profile in Set(spaces.map(\.profileID)) {
            guard let first = spaces.first(where: { $0.profileID == profile }) else { continue }
            if first.id != (homeID(of: profile, home: home) ?? first.id) { return true }
        }
        return false
    }

    private static func homeID(of profile: UUID, home: (UUID) -> UUID?) -> UUID? {
        profile == Space.personalProfileID ? Space.firstID : home(profile)
    }
}

/// Where each space's tabs are kept between launches: the first space's in
/// the file there always was, each other's beside it, by its id.
public enum SpaceSessionFile {
    /// `stem`: the app's own name for the file ("session" on the Mac,
    /// "tabs" on iPhone and iPad).
    public static func name(for space: UUID, stem: String) -> String {
        space == Space.firstID ? "\(stem).json" : "\(stem)-\(space.uuidString).json"
    }
}
