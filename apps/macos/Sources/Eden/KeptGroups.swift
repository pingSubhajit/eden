import EdenCore
import Foundation

// The kept area's groups on disk (see Column.swift). They are kept with the
// pins, by the pins store (Pins.groups), per space and shared by every
// window, and written and passed on as the pins are (Pins.changed); which
// group a row is in is the row's own (PinDef.group, in pins.json).
//
// They have a file of their own, kept-groups.json, beside pins.json rather
// than in it: an Eden from before reads pins.json as nothing but lists of
// pins, and a file it can't read is one it starts again from its sessions
// and writes over, every row's group with it.
//
// Before, the same groups were folders of pinned rows, in pin-folders.json.
// That file is read once (Pins.readGroups) and taken in whole: each folder
// becomes the kept group of the same id, so every row stays in it, with its
// name, colour, icon and whether it was folded; folders an Eden before that
// kept inside others are flattened as they always were (LegacyPinFolders).
// It goes only once kept-groups.json is on disk.

/// kept-groups.json: each space's kept groups under its id, in order, and,
/// under `movedKey`, where the rows of each folder flattened on the way in
/// go, while those rows may not be on disk in it yet (see Pins.readGroups).
enum KeptGroupsFile {
    static let name = "kept-groups.json"

    /// The key the moves wait under, beside the spaces': not a space's id,
    /// so a reader that doesn't know it passes it by.
    static let movedKey = "moved"

    /// The file as read: each space's groups, and, by space, the group each
    /// flattened folder's rows go into.
    struct Read: Equatable {
        var bySpace: [UUID: [TabGroup]] = [:]
        var moved: [UUID: [UUID: UUID]] = [:]
    }

    /// Leniently: a space whose list won't read is a space with no groups,
    /// never a file that loses every other space's. Nil only for a file
    /// that isn't one at all, to be set aside rather than written over.
    static func decode(_ data: Data) -> Read? {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out = Read(moved: moves(top[movedKey]))
        for (key, value) in top {
            guard let space = UUID(uuidString: key),
                  let raw = try? JSONSerialization.data(withJSONObject: value),
                  let read = try? JSONDecoder().decode([TabGroup].self, from: raw), !read.isEmpty
            else { continue }
            var seen = Set<UUID>()
            out.bySpace[space] = read.filter { seen.insert($0.id).inserted }
        }
        return out
    }

    /// Every space's groups, an empty list never written. Always a file, an
    /// empty one too: that it is there says pin-folders.json was taken in.
    static func encode(_ read: Read) -> Data? {
        var out: [String: Any] = [:]
        for (space, groups) in read.bySpace where !groups.isEmpty {
            guard let raw = try? JSONEncoder().encode(groups),
                  let list = try? JSONSerialization.jsonObject(with: raw) else { return nil }
            out[space.uuidString] = list
        }
        let moves = read.moved.filter { !$0.value.isEmpty }
        if !moves.isEmpty {
            out[movedKey] = Dictionary(uniqueKeysWithValues: moves.map { space, into in
                (space.uuidString, Dictionary(uniqueKeysWithValues: into.map { ($0.key.uuidString, $0.value.uuidString) }))
            })
        }
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    /// The moves as written, by space: anything that doesn't read is passed by.
    static func moves(_ value: Any?) -> [UUID: [UUID: UUID]] {
        var out: [UUID: [UUID: UUID]] = [:]
        for (key, value) in value as? [String: [String: String]] ?? [:] {
            guard let space = UUID(uuidString: key) else { continue }
            for (from, to) in value {
                guard let from = UUID(uuidString: from), let to = UUID(uuidString: to) else { continue }
                out[space, default: [:]][from] = to
            }
        }
        return out
    }
}

/// pin-folders.json, as the Edens before kept groups wrote it: each space's
/// folders of pinned rows, and the moves a flattening was still waiting on.
/// Only read, once, into kept-groups.json (Pins.readGroups).
enum LegacyPinFolders {
    static let name = "pin-folders.json"

    /// A folder as it was written: a kept group's fields under the same
    /// keys, read as leniently (TabGroup's decoding), and, from an Eden
    /// before folders were one level deep, the folder it was in.
    private struct Nesting: Decodable {
        let id: UUID
        let parent: UUID?

        private enum Keys: String, CodingKey { case id, parent }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decode(UUID.self, forKey: .id)
            parent = try? c.decodeIfPresent(UUID.self, forKey: .parent)
        }
    }

    /// The file as kept groups: each folder the group of its id, one level
    /// deep, and where the rows of every folder that was inside another
    /// go, the moves the file was already waiting on among them. Leniently,
    /// as the file was always read; nil for a file that isn't one at all.
    static func decode(_ data: Data) -> KeptGroupsFile.Read? {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out = KeptGroupsFile.Read(moved: KeptGroupsFile.moves(top[KeptGroupsFile.movedKey]))
        for (key, value) in top {
            guard let space = UUID(uuidString: key),
                  let raw = try? JSONSerialization.data(withJSONObject: value),
                  let read = try? JSONDecoder().decode([TabGroup].self, from: raw), !read.isEmpty
            else { continue }
            var seen = Set<UUID>()
            let groups = read.filter { seen.insert($0.id).inserted }
            let nesting = (try? JSONDecoder().decode([Nesting].self, from: raw)) ?? []
            let parents = Dictionary(nesting.compactMap { nest in nest.parent.map { (nest.id, $0) } },
                                     uniquingKeysWith: { first, _ in first })
            let flat = flattened(groups, parents: parents)
            out.bySpace[space] = flat.groups
            out.moved[space, default: [:]].merge(flat.into) { _, nested in nested }
            if out.moved[space]?.isEmpty == true { out.moved[space] = nil }
        }
        return out
    }

    /// The folders an Eden from before kept, some inside others by
    /// `parents`, one level deep: each folder inside another goes, and what
    /// it held belongs to the folder at the top it was in (`into`, by the
    /// folder that went). Past a parent that is gone, a folder is at the
    /// top already; round a loop, the one of it listed first is the top.
    static func flattened(_ groups: [TabGroup], parents: [UUID: UUID]) -> (groups: [TabGroup], into: [UUID: UUID]) {
        let place = Dictionary(groups.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var into: [UUID: UUID] = [:]
        for group in groups {
            var chain = [group.id]
            var top = group.id
            while let current = chain.last, let parent = parents[current], place[parent] != nil {
                if let looped = chain.firstIndex(of: parent) {
                    top = chain[looped...].min { (place[$0] ?? 0) < (place[$1] ?? 0) } ?? parent
                    break
                }
                chain.append(parent)
                top = parent
            }
            if top != group.id { into[group.id] = top }
        }
        return (groups.filter { into[$0.id] == nil }, into)
    }

    /// The rows of a folder that went (`into`, see flattened) in the group
    /// at the top it was in.
    static func refiled(_ pins: [PinDef], into: [UUID: UUID]) -> [PinDef] {
        pins.map { pin in
            guard let group = pin.group, let top = into[group] else { return pin }
            var pin = pin
            pin.group = top
            return pin
        }
    }
}
