import Foundation

// The merge behind sync through iCloud (CloudSync.swift): plain values in,
// plain values out, nothing read or written here, so every rule can be
// tested on its own. It began as the Mac's sync through a shared folder,
// one file per Mac, which is why some of it still speaks of files: in
// iCloud, "the other Macs' files" are the server's items.
//
// What is synced is a flat map of items, key → a small JSON text. Each
// device keeps, for every item, the value it last agreed on with a stamp
// (when it was set, in seconds) and the device that set it; a deletion is
// the same entry with no value, a tombstone, so "gone" travels as surely as
// "changed".
//
// A pass on one device:
//   1. stamp: the items as this device has them now, compared with what it
//      last agreed (its base). What differs is an edit made here since,
//      stamped later than anything it has seen (so a device whose clock runs
//      behind still wins over a value it already saw); what it agreed on and
//      no longer has is a tombstone. A first pass (no base: joining) stamps
//      0, so what the other devices already hold wins where both have the
//      same item and nothing here is lost where only this device has it.
//   2. merge: this map and the others', item by item, the latest stamp
//      winning, then the device id, then a tombstone, then the larger text —
//      the same answer on every device whatever order it reads them in.
//   3. what changed is applied here, and the merged map is the new base and
//      what this device holds on the server.
//
// Items this build can't read (a newer Eden's, a damaged one) are carried
// along untouched and never turned into tombstones.

public struct SyncEntry: Codable, Equatable, Sendable {
    /// The item's JSON; nil for one deleted.
    public var v: String?
    /// When it was set, seconds since 1970 — or later, see `SyncMerge.stamp`.
    public var t: Double
    /// The device that set it.
    public var d: String

    public init(v: String?, t: Double, d: String) {
        self.v = v
        self.t = t
        self.d = d
    }
}

/// One Mac's file in one scope's folder: only that Mac writes it.
public struct SyncFile: Codable, Equatable, Sendable {
    public var format: Int
    public var device: String
    /// The Mac's name, for Settings to say who was last seen.
    public var name: String?
    /// "app", or "profile-<id>": a file in the wrong folder is not read.
    public var scope: String
    public var written: Double
    public var items: [String: SyncEntry]

    public init(format: Int, device: String, name: String?, scope: String, written: Double, items: [String: SyncEntry]) {
        self.format = format
        self.device = device
        self.name = name
        self.scope = scope
        self.written = written
        self.items = items
    }
}

public enum SyncMerge {
    /// The file format. A file of another is passed over, not misread.
    public static let format = 1
    /// How long a deletion is remembered: a Mac away longer than this may
    /// bring back what was deleted meanwhile, and nothing worse.
    public static let tombstoneLife: Double = 365 * 24 * 60 * 60

    /// Whether `a` beats `b` for the same item. Total and the same on every
    /// Mac: two Macs that read the same files agree.
    public static func wins(_ a: SyncEntry, over b: SyncEntry) -> Bool {
        if a.t != b.t { return a.t > b.t }
        if a.d != b.d { return a.d > b.d }
        switch (a.v, b.v) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?): return x > y
        }
    }

    /// Every map's items, the winner of each.
    public static func merge(_ maps: [[String: SyncEntry]]) -> [String: SyncEntry] {
        var out: [String: SyncEntry] = [:]
        for map in maps {
            for (key, entry) in map {
                if let held = out[key], !wins(entry, over: held) { continue }
                out[key] = entry
            }
        }
        return out
    }

    /// The items as this Mac has them now (`current`), written over what it
    /// last agreed (`base`). `understood` says which of base's items this
    /// build can read: only those can be found missing and deleted.
    /// `joining`: this device's first pass where others already sync — its
    /// items are stamped 0, so theirs win where both have one.
    /// `seen`: the latest stamp this device has seen elsewhere (the server's
    /// items, its own edits not yet sent), which an edit made now must beat
    /// as surely as the base's.
    public static func stamp(current: [String: String], base: [String: SyncEntry], device: String, now: Double,
                      joining: Bool = false, seen: Double = 0,
                      understood: (String, String) -> Bool = { _, _ in true }) -> [String: SyncEntry] {
        // Later than anything seen, whatever this device's clock says.
        let clock = joining ? 0 : max(now, max(base.values.map(\.t).max() ?? 0, seen) + 0.001)
        var out = base
        for (key, value) in current where base[key]?.v != value {
            out[key] = SyncEntry(v: value, t: clock, d: device)
        }
        // A whole kind gone at once — every bookmark, every pin — is a file
        // that didn't read or a browser reset, far likelier than a choice:
        // those are not deleted everywhere, they come back from the folder.
        let lost = Set(wholeKinds.filter { kind in
            !current.keys.contains { $0.hasPrefix(kind) }
                && base.filter { $0.key.hasPrefix(kind) && $0.value.v != nil }.count >= wholeKindFloor
        })
        for (key, entry) in base {
            guard let value = entry.v, current[key] == nil, understood(key, value),
                  !lost.contains(where: { key.hasPrefix($0) }) else { continue }
            out[key] = SyncEntry(v: nil, t: clock, d: device)
        }
        return out
    }

    /// One pass, as every Mac runs it: this Mac's items stamped over its
    /// base (nil before its first pass), merged with the other Macs' maps,
    /// old deletions forgotten. What comes back is the new base, this Mac's
    /// file, and — its live items — what this Mac should now have.
    public static func pass(current: [String: String], base: [String: SyncEntry]?, theirs: [[String: SyncEntry]],
                     device: String, now: Double,
                     understood: (String, String) -> Bool = { _, _ in true }) -> [String: SyncEntry] {
        let mine = stamp(current: current, base: base ?? [:], device: device, now: now,
                         joining: base == nil && !theirs.isEmpty, understood: understood)
        // A deletion past its life counts for nothing, coming in as going out:
        // it stays on the iCloud server (CloudSync), and must not delete what a
        // device joining now brings.
        return prune(merge([mine] + theirs.map { prune($0, now: now) }), now: now)
    }

    /// The kinds of item whose vanishing all at once is not taken as their
    /// deletion (see `stamp`), and how many there must have been.
    public static let wholeKinds = ["bm:", "kids:", "pin:", "order:pins:", "title:pin:", "space:"]
    public static let wholeKindFloor = 5

    /// The items that are there, without the tombstones.
    public static func live(_ map: [String: SyncEntry]) -> [String: String] {
        map.compactMapValues(\.v)
    }

    /// The keys deleted.
    public static func tombstoned(_ map: [String: SyncEntry]) -> Set<String> {
        Set(map.filter { $0.value.v == nil }.keys)
    }

    /// Deletions older than `tombstoneLife` forgotten.
    public static func prune(_ map: [String: SyncEntry], now: Double) -> [String: SyncEntry] {
        map.filter { $0.value.v != nil || $0.value.t >= now - tombstoneLife }
    }

    /// Another Mac's file, if it is one this build can read for this scope:
    /// damaged, foreign, other-format and wrong-folder files are nil, and an
    /// entry with a stamp that is not a number is left out.
    public static func decode(_ data: Data, scope: String) -> SyncFile? {
        guard var file = try? JSONDecoder().decode(SyncFile.self, from: data),
              file.format == format, file.scope == scope, !file.device.isEmpty
        else { return nil }
        file.items = file.items.filter { $0.value.t.isFinite && $0.value.t >= 0 && !$0.value.d.isEmpty }
        return file
    }

    public static func encode(_ file: SyncFile) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(file)
    }

    /// A value as an item's text: sorted keys, so the same value is always
    /// the same text and "changed" means changed.
    public static func text<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func value<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }

    /// A list's order applied to the ids that are there: the order's first,
    /// as it has them, then the rest in `fallback`'s order, then any left by
    /// id — so an item added on one Mac while another reordered is kept, at
    /// the end, and every Mac ends with the same list.
    public static func ordered(_ ids: Set<String>, order: [String], fallback: [String] = []) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for id in order + fallback where ids.contains(id) && !seen.contains(id) {
            out.append(id)
            seen.insert(id)
        }
        return out + ids.subtracting(seen).sorted()
    }
}

// MARK: - what each kind of thing is, as items

/// The parts of a space that sync: what it is called and looks like, and
/// whether it has sign-ins of its own. Never its cookies, sign-ins, tabs
/// or downloads folder.
public struct SyncedSpace: Codable, Equatable {
    public var name: String
    public var colour: Int
    public var icon: String?
    public var sharesSignIns: Bool?
}

/// The parts of a pin that sync. Its title is the page's, which changes as
/// you browse; it goes once, beside it, for a Mac that makes the pin anew.
public struct SyncedPin: Codable, Equatable {
    public var letter: String
    public var home: String
    public var name: String?
    public var listed: Bool?
}

/// A bookmark or a folder (no url), without its place: the folder that
/// holds it lists it.
public struct SyncedBookmark: Codable, Equatable {
    public var title: String
    public var url: String?
}

public enum SyncItems {
    // MARK: spaces

    public static let spacesOrder = "order:spaces"

    public static func spaceKey(_ id: UUID) -> String { "space:" + id.uuidString }

    /// One profile's spaces, as items. Whether a space has sign-ins of its
    /// own is what was agreed when it was first synced (`base`), never
    /// changed after: a store can't change under a space's open tabs.
    public static func spaces(_ list: [Space], base: [String: String] = [:]) -> [String: String] {
        var out: [String: String] = [:]
        for space in list {
            let agreed = base[spaceKey(space.id)].flatMap { SyncMerge.value(SyncedSpace.self, $0) }
            let synced = SyncedSpace(name: space.name, colour: space.colour, icon: space.icon,
                                     sharesSignIns: agreed.map(\.sharesSignIns) ?? space.sharesSignIns)
            out[spaceKey(space.id)] = SyncMerge.text(synced)
        }
        if !list.isEmpty { out[spacesOrder] = SyncMerge.text(list.map(\.id.uuidString)) }
        return out
    }

    /// The spaces the merged items say there are: names, colours and icons
    /// as merged, in the merged order; what is only this Mac's — the
    /// downloads folder — kept; whether one has its own sign-ins is never
    /// changed once it is made. `home` is never taken away.
    public static func applySpaces(_ live: [String: String], to local: [Space], profile: UUID, home: UUID) -> [Space] {
        var found: [String: SyncedSpace] = [:]
        for (key, text) in live where key.hasPrefix("space:") {
            guard UUID(uuidString: String(key.dropFirst(6))) != nil, let space = SyncMerge.value(SyncedSpace.self, text) else { continue }
            found[String(key.dropFirst(6))] = space
        }
        var ids = Set(found.keys)
        // A space this Mac has that the items don't read (never: the stamp
        // put each in) stays; the home always does.
        for space in local where space.id == home || live[spaceKey(space.id)].map({ SyncMerge.value(SyncedSpace.self, $0) == nil }) == true {
            ids.insert(space.id.uuidString)
        }
        let order = live[spacesOrder].flatMap { SyncMerge.value([String].self, $0) } ?? []
        let ordered = SyncMerge.ordered(ids, order: order, fallback: local.map(\.id.uuidString))
        return ordered.compactMap { text -> Space? in
            guard let id = UUID(uuidString: text) else { return nil }
            var space = local.first { $0.id == id }
                ?? Space(id: id, name: "", colour: 0, profile: profile == Space.personalProfileID ? nil : profile)
            if let synced = found[text] {
                space.name = synced.name
                space.colour = synced.colour
                space.icon = synced.icon
                if !local.contains(where: { $0.id == id }) { space.sharesSignIns = synced.sharesSignIns }
            }
            if space.name.isEmpty { space.name = "Space" }
            return space
        }
    }

    // MARK: pins

    public static let sharedSpace = "shared"

    public static func pinKey(_ space: String, _ id: UUID) -> String { "pin:\(space):\(id.uuidString)" }
    public static func pinOrder(_ space: String) -> String { "order:pins:\(space)" }
    public static func pinTitle(_ id: UUID) -> String { "title:pin:\(id.uuidString)" }

    /// A profile's pins as items: each space's own, and the ones every space
    /// shows. A pin's title is the one already agreed, if there is one.
    public static func pins(bySpace: [UUID: [PinDef]], shared: [PinDef], base: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        func add(_ defs: [PinDef], _ space: String) {
            for def in defs {
                out[pinKey(space, def.id)] = SyncMerge.text(SyncedPin(letter: def.letter, home: def.home, name: def.name, listed: def.listed))
                out[pinTitle(def.id)] = base[pinTitle(def.id)] ?? SyncMerge.text(def.title)
            }
            if !defs.isEmpty { out[pinOrder(space)] = SyncMerge.text(defs.map(\.id.uuidString)) }
        }
        for (space, defs) in bySpace { add(defs, space.uuidString) }
        add(shared, sharedSpace)
        return out
    }

    /// The pins the merged items say each of `spaces` has, and the shared
    /// ones. A pin in both the shared list and a space's (shared on one Mac
    /// while edited on another) is shared. Titles: the one agreed, else the
    /// one this Mac had, else the page's address.
    public static func applyPins(_ live: [String: String], spaces: [UUID], local: [UUID: [PinDef]], localShared: [PinDef])
        -> (bySpace: [UUID: [PinDef]], shared: [PinDef]) {
        let known = (Array(local.values).flatMap { $0 } + localShared)
        func defs(_ space: String, fallback: [PinDef]) -> [PinDef] {
            let prefix = "pin:\(space):"
            var found: [String: SyncedPin] = [:]
            for (key, text) in live where key.hasPrefix(prefix) {
                let id = String(key.dropFirst(prefix.count))
                guard UUID(uuidString: id) != nil, let pin = SyncMerge.value(SyncedPin.self, text) else { continue }
                found[id] = pin
            }
            let order = live[pinOrder(space)].flatMap { SyncMerge.value([String].self, $0) } ?? []
            return SyncMerge.ordered(Set(found.keys), order: order, fallback: fallback.map(\.id.uuidString)).compactMap { text in
                guard let id = UUID(uuidString: text), let pin = found[text] else { return nil }
                let title = live[pinTitle(id)].flatMap { SyncMerge.value(String.self, $0) }
                    ?? known.first { $0.id == id }?.title ?? pin.home
                return PinDef(id: id, letter: pin.letter, home: pin.home, title: title, name: pin.name, listed: pin.listed)
            }
        }
        let shared = defs(sharedSpace, fallback: localShared)
        let sharedIDs = Set(shared.map(\.id))
        var bySpace: [UUID: [PinDef]] = [:]
        for space in spaces {
            let own = defs(space.uuidString, fallback: local[space] ?? []).filter { !sharedIDs.contains($0.id) }
            if !own.isEmpty { bySpace[space] = own }
        }
        return (bySpace, shared)
    }

    // MARK: bookmarks

    public static let rootFolder = "root"

    public static func bookmarkKey(_ id: UUID) -> String { "bm:" + id.uuidString }
    public static func childrenKey(_ folder: String) -> String { "kids:" + folder }

    /// A bookmarks tree as items: each bookmark and folder, and each
    /// folder's list of what it holds, the top level under "root".
    public static func bookmarks(_ roots: [Bookmark]) -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ nodes: [Bookmark], in folder: String) {
            if !nodes.isEmpty { out[childrenKey(folder)] = SyncMerge.text(nodes.map(\.id.uuidString)) }
            for node in nodes {
                out[bookmarkKey(node.id)] = SyncMerge.text(SyncedBookmark(title: node.title, url: node.url))
                if node.isFolder { walk(node.children ?? [], in: node.id.uuidString) }
            }
        }
        walk(roots, in: rootFolder)
        return out
    }

    /// The tree the merged items say there is. A bookmark no folder lists
    /// any more — its folder deleted on one Mac while it was added there on
    /// another, or two folders moved into each other — goes at the end of
    /// the top level rather than being lost.
    public static func applyBookmarks(_ live: [String: String]) -> [Bookmark] {
        var nodes: [String: SyncedBookmark] = [:]
        for (key, text) in live where key.hasPrefix("bm:") {
            let id = String(key.dropFirst(3))
            guard UUID(uuidString: id) != nil, let node = SyncMerge.value(SyncedBookmark.self, text) else { continue }
            nodes[id] = node
        }
        func kids(_ folder: String) -> [String] {
            live[childrenKey(folder)].flatMap { SyncMerge.value([String].self, $0) } ?? []
        }
        var placed = Set<String>()
        func build(_ folder: String) -> [Bookmark] {
            kids(folder).compactMap { id -> Bookmark? in
                guard let node = nodes[id], !placed.contains(id), let uuid = UUID(uuidString: id) else { return nil }
                placed.insert(id)
                let children = node.url == nil ? build(id) : nil
                return Bookmark(id: uuid, title: node.title, url: node.url, children: children)
            }
        }
        var roots = build(rootFolder)
        // What no folder reached: each, with what it holds, at the end.
        for id in nodes.keys.sorted() where !placed.contains(id) {
            guard let node = nodes[id], let uuid = UUID(uuidString: id) else { continue }
            placed.insert(id)
            roots.append(Bookmark(id: uuid, title: node.title, url: node.url, children: node.url == nil ? build(id) : nil))
        }
        return roots
    }

    /// The keys of the settings that sync, as "set:<key>" items: the Mac's
    /// SyncSettings writes them, and any device reads them.
    public static let knownSettings: Set<String> = [
        "look", "glyph", "search.engine", "search.custom", "search.suggest", "search.keywords", "spaces",
        "pins.list", "pins.home", "tabs.close.after", "tabs.newPlace", "tabs.shortcuts", "shield",
        "privacy.clickIDs", "privacy.gpc", "bookmarks.bar", "quit.confirm",
    ]

    /// Whether this build can read an item: only those can be found missing
    /// here and so deleted everywhere.
    public static func understood(_ key: String, _ text: String) -> Bool {
        if key.hasPrefix("space:") { return SyncMerge.value(SyncedSpace.self, text) != nil }
        if key.hasPrefix("pin:") { return SyncMerge.value(SyncedPin.self, text) != nil }
        if key.hasPrefix("bm:") { return SyncMerge.value(SyncedBookmark.self, text) != nil }
        if key.hasPrefix("order:") || key.hasPrefix("kids:") { return SyncMerge.value([String].self, text) != nil }
        if key.hasPrefix("title:pin:") { return SyncMerge.value(String.self, text) != nil }
        if key.hasPrefix("set:") { return knownSettings.contains(String(key.dropFirst(4))) }
        return false
    }
}
