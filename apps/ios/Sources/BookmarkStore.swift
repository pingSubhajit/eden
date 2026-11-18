import EdenCore
import Foundation
import Observation

/// Your bookmarks on this iPhone or iPad: sites, newest last, in a small
/// file of their own. The same Bookmark the Mac keeps (EdenCore), so the
/// two can sync in Phase 4; folders come with that.
@Observable
final class BookmarkStore {
    private(set) var items: [Bookmark] = []

    @ObservationIgnored private let file: URL

    /// `file` is where they're kept; tests hand one of their own.
    init(file: URL = Store.file("bookmarks.json")) {
        self.file = file
        load()
    }

    /// Whether the page is one of them, by its address as it was kept.
    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return items.contains { $0.url == url.absoluteString }
    }

    /// The page kept, unless it already is.
    func add(_ url: URL, title: String) {
        guard !contains(url) else { return }
        items.append(.site(title, url))
        save()
    }

    /// The page no longer kept.
    func remove(_ url: URL) {
        items.removeAll { $0.url == url.absoluteString }
        save()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where items.indices.contains(index) { items.remove(at: index) }
        save()
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

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let read = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            // Set aside rather than written over, as on the Mac.
            Store.quarantine(file)
            return
        }
        // Only sites for now; a folder from a newer build is kept as it is.
        items = read
    }

    private func save() {
        let snapshot = items
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }
}
