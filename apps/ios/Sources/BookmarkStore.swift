import EdenCore
import Foundation
import Observation

/// Your bookmarks on this iPhone or iPad, in a small file of their own: the
/// same tree of sites and folders the Mac keeps (EdenCore's Bookmark), so
/// the two sync through iCloud (Syncing). Shown here as one list of sites,
/// folders flattened; a site added here goes at the end of the top level.
@Observable
final class BookmarkStore {
    /// The whole tree, as it is kept and as it syncs.
    private(set) var roots: [Bookmark] = []

    /// Told after a change made here is kept, so sync takes it to your other
    /// devices; not after one that came from them.
    @ObservationIgnored var saved: (() -> Void)?
    @ObservationIgnored private let file: URL

    /// `file` is where they're kept; tests hand one of their own.
    init(file: URL = Store.file("bookmarks.json")) {
        self.file = file
        load()
    }

    /// Every site, top to bottom, the ones in folders where their folder is.
    var items: [Bookmark] { BookmarkStore.sites(in: roots) }

    private static func sites(in nodes: [Bookmark]) -> [Bookmark] {
        nodes.flatMap { node in node.isFolder ? sites(in: node.children ?? []) : [node] }
    }

    /// Whether the page is one of them, by its address as it was kept.
    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return items.contains { $0.url == url.absoluteString }
    }

    /// The page kept, unless it already is.
    func add(_ url: URL, title: String) {
        guard !contains(url) else { return }
        roots.append(.site(title, url))
        save()
    }

    /// The page no longer kept, wherever it is.
    func remove(_ url: URL) {
        let address = url.absoluteString
        roots = BookmarkStore.pruned(roots) { $0.url == address }
        save()
    }

    /// The sites at these places in `items`, no longer kept.
    func remove(at offsets: IndexSet) {
        let shown = items
        let ids = Set(offsets.compactMap { shown.indices.contains($0) ? shown[$0].id : nil })
        roots = BookmarkStore.pruned(roots) { ids.contains($0.id) }
        save()
    }

    private static func pruned(_ nodes: [Bookmark], dropping drop: (Bookmark) -> Bool) -> [Bookmark] {
        nodes.compactMap { node in
            if !node.isFolder { return drop(node) ? nil : node }
            var folder = node
            folder.children = pruned(node.children ?? [], dropping: drop)
            return folder
        }
    }

    /// Kept if it wasn't, let go if it was. Whether it is kept now.
    @discardableResult
    func toggle(_ url: URL, title: String) -> Bool {
        if contains(url) {
            remove(url)
            return false
        }
        add(url, title: title)
        return true
    }

    /// The sites whose name or address has every word typed, for the
    /// address field's suggestions.
    func matching(_ typed: String, limit: Int = 3) -> [Bookmark] {
        let words = typed.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return Array(items.filter { bookmark in
            let text = (bookmark.title + " " + (bookmark.url ?? "")).lowercased()
            return words.allSatisfy(text.contains)
        }.prefix(limit))
    }

    /// The tree as your devices now agree on it (Syncing).
    func adopt(_ tree: [Bookmark]) {
        guard tree != roots else { return }
        roots = tree
        write()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let read = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            // Set aside rather than written over, as on the Mac.
            Store.quarantine(file)
            return
        }
        roots = read
    }

    private func save() {
        write()
        saved?()
    }

    private func write() {
        let snapshot = roots
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }
}
