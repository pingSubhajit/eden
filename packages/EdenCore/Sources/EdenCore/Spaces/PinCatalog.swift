import Foundation

/// Every pin: each space's own, and the ones every space of a profile shows
/// before its own (Arc's favourites). In order, as the user arranged them.
public struct PinCatalog: Equatable, Sendable {
    public var bySpace: [UUID: [PinDef]]
    /// By profile; Personal's under Space.personalProfileID.
    public var sharedByProfile: [UUID: [PinDef]]

    public init(bySpace: [UUID: [PinDef]] = [:], sharedByProfile: [UUID: [PinDef]] = [:]) {
        self.bySpace = bySpace
        self.sharedByProfile = sharedByProfile
    }

    public func pins(of space: UUID) -> [PinDef] { bySpace[space] ?? [] }
    public func shared(by profile: UUID) -> [PinDef] { sharedByProfile[profile] ?? [] }
}

/// pins.json: each space's pins under its id; Personal's shared pins under
/// "shared", which an Eden from before them reads as no space and passes
/// over; another profile's under "shared:<profile id>". An empty list is
/// never written, so the file stays what it was for anyone who never used
/// one.
public enum PinsFile {
    public static let sharedKey = "shared"

    public static func decode(_ data: Data) throws -> PinCatalog {
        let saved = try JSONDecoder().decode([String: [PinDef]].self, from: data)
        var catalog = PinCatalog()
        for (key, defs) in saved where !defs.isEmpty {
            if let space = UUID(uuidString: key) {
                catalog.bySpace[space] = defs
            } else if key == sharedKey {
                catalog.sharedByProfile[Space.personalProfileID] = defs
            } else if key.hasPrefix(sharedKey + ":"), let profile = UUID(uuidString: String(key.dropFirst(sharedKey.count + 1))) {
                catalog.sharedByProfile[profile] = defs
            }
        }
        return catalog
    }

    public static func encode(_ catalog: PinCatalog) throws -> Data {
        var out: [String: [PinDef]] = [:]
        for (space, defs) in catalog.bySpace where !defs.isEmpty { out[space.uuidString] = defs }
        for (profile, defs) in catalog.sharedByProfile where !defs.isEmpty {
            out[profile == Space.personalProfileID ? sharedKey : sharedKey + ":" + profile.uuidString] = defs
        }
        return try JSONEncoder().encode(out)
    }
}

/// How a space's own pins and its profile's shared ones make one row, and
/// how a pin moves between them. The same on every device.
public enum PinLists {
    /// What a space's row holds: the shared pins, then its own, while the
    /// shared ones show — a pin in both is shared — its own alone otherwise.
    public static func row(own: [PinDef], shared: [PinDef], showing: Bool) -> [PinDef] {
        guard showing else { return own }
        let sharedIDs = Set(shared.map(\.id))
        return shared + own.filter { !sharedIDs.contains($0.id) }
    }

    /// A space's own pin, shown by every space from now on: at the end of
    /// the shared ones, in no group — kept groups are a space's own.
    public static func share(_ id: UUID, own: [PinDef], shared: [PinDef]) -> (own: [PinDef], shared: [PinDef]) {
        guard var pin = own.first(where: { $0.id == id }) else { return (own, shared) }
        pin.group = nil
        return (own.filter { $0.id != id }, shared + [pin])
    }

    /// A shared pin kept by one space only: first among its own.
    public static func keep(_ id: UUID, own: [PinDef], shared: [PinDef]) -> (own: [PinDef], shared: [PinDef]) {
        guard let pin = shared.first(where: { $0.id == id }) else { return (own, shared) }
        return ([pin] + own, shared.filter { $0.id != id })
    }

    /// A row's pins, as the row has them, into the space's own and the
    /// shared ones, each in the row's order.
    public static func split(_ defs: [PinDef], shared ids: Set<UUID>) -> (own: [PinDef], shared: [PinDef]) {
        (defs.filter { !ids.contains($0.id) }, defs.filter { ids.contains($0.id) })
    }

    /// What a row's shared pins say the shared list now is: nothing while
    /// they don't show, and nothing from a row that holds none — a row not
    /// yet given them must not wipe them. Taking the last one out is an
    /// unpin or a keep, which set the list themselves.
    public static func sharedToWrite(_ rowShared: [PinDef], showing: Bool) -> [PinDef]? {
        showing && !rowShared.isEmpty ? rowShared : nil
    }
}
