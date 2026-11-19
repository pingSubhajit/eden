import Foundation

/// A named section of ordinary tabs in one space's tab layout.
/// Its tabs remain ordinary tabs; their own group IDs describe membership.
struct TabGroup: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var collapsed: Bool
    /// The colour it wears (GroupLook.swift): Stone, the neutral, until one
    /// is chosen.
    var colour: GroupColour = .stone
    /// Its own icon; none shows its first tab's site icon.
    var icon: GroupIcon? = nil
}

extension TabGroup {
    private enum Keys: String, CodingKey { case id, name, collapsed, colour, icon }

    /// A group saved without its folded state is an open one; without a
    /// colour, or with one a newer Eden added, Stone; without an icon, or
    /// with one that doesn't read, none.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
        colour = (try? c.decodeIfPresent(GroupColour.self, forKey: .colour)) ?? .stone
        icon = try? c.decodeIfPresent(GroupIcon.self, forKey: .icon)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(collapsed, forKey: .collapsed)
        // Only once chosen: a file with no colours in it reads as it always did.
        if colour != .stone { try c.encode(colour, forKey: .colour) }
        try c.encodeIfPresent(icon, forKey: .icon)
    }
}

extension TabGroup {
    /// The number an extension knows the group by, as Chrome numbers its
    /// groups. Taken from the identifier, so it stays the same for as long
    /// as the group lasts, across launches too, with nothing to keep.
    static func number(_ id: UUID) -> Int {
        let u = id.uuid
        let n = Int(u.0 & 0x7F) << 24 | Int(u.1) << 16 | Int(u.2) << 8 | Int(u.3)
        return n == 0 ? 1 : n
    }
}

/// The colours a group can wear: Eden's eight, taken from the landscape
/// paintings it is made around, in the order the menu shows them. Kept by
/// name, so a colour can be retuned without a group changing.
enum GroupColour: String, Codable, CaseIterable, Identifiable {
    case stone, sage, sky, heather, ochre, rose, madder, umber

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}

/// A group's own icon: an emoji, or one of the symbols the picker offers.
/// Kept as one string, "emoji:🌿" or "symbol:leaf.fill".
enum GroupIcon: Codable, Equatable {
    case emoji(String)
    case symbol(String)

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        if text.hasPrefix("emoji:"), text.count > 6 {
            self = .emoji(String(text.dropFirst(6)))
        } else if text.hasPrefix("symbol:"), text.count > 7 {
            self = .symbol(String(text.dropFirst(7)))
        } else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                   debugDescription: "An icon this Eden doesn't know")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .emoji(let text): try c.encode("emoji:" + text)
        case .symbol(let name): try c.encode("symbol:" + name)
        }
    }
}
