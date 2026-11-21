import EdenCore
import Foundation

// The bookmarks list, kept out of sight. Pins are where the Mac keeps pages
// (#6): the list was brought into pinned rows once (PinShelf.bringBookmarks)
// and nothing on the Mac shows it or changes it now. It is still kept, in
// its small file, for two reasons: the iPhone still has its bookmarks, and
// sync carries them through this Mac rather than finding them missing here
// and deleting them everywhere (Sync.swift); and the file is the backup of
// what was brought over.

@MainActor
final class Bookmarks {
    /// The list as sync last left it.
    private(set) var roots: [Bookmark] = []

    /// Its file: bookmarks.json for Personal, one of its own for each other
    /// profile (see Profiles.swift).
    private let fileName: String
    /// Its profile deleted: nothing more is written.
    private var retired = false

    init(file: String = "bookmarks.json") {
        fileName = file
        load()
    }

    /// Its profile deleted: its file removed, and nothing written again.
    func retire() {
        retired = true
        Disk.remove(file)
    }

    /// How many sites, folders included.
    nonisolated static func count(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + ($1.isFolder ? count($1.children ?? []) : 1) }
    }

    /// Every site in the list, in order, folders opened.
    nonisolated static func urls(_ nodes: [Bookmark]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            if node.isFolder { return urls(node.children ?? []) }
            return node.url.flatMap(URL.init(string:)).map { [$0] } ?? []
        }
    }

    /// Every folder in the tree, each with how deep it sits.
    static func folders(_ nodes: [Bookmark], depth: Int = 0) -> [(node: Bookmark, depth: Int)] {
        nodes.flatMap { node -> [(Bookmark, Int)] in
            guard node.isFolder else { return [] }
            return [(node, depth)] + folders(node.children ?? [], depth: depth + 1)
        }
    }

    // MARK: - the file

    private var file: URL { Store.file(fileName) }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let list = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            Store.quarantine(file)
            return
        }
        roots = list
    }

    private func save() {
        guard !retired else { return }
        let snapshot = roots
        // One after another, the newest last (see Disk).
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
        NotificationCenter.default.post(name: Bookmarks.saved, object: self)
    }

    /// The list was saved: Sync takes it to your other devices.
    static let saved = Notification.Name("EdenBookmarksSaved")

    /// The list as your other devices left it (see Sync.swift).
    func adopt(_ nodes: [Bookmark]) {
        guard nodes != roots else { return }
        roots = nodes
        save()
    }
}
