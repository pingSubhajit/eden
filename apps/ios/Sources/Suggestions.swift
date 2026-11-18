import EdenCore
import Foundation

/// The rows under the address field for what has been typed: where Return
/// goes first — the address, or a search — then a page already open in a
/// tab, your bookmarks, and where you have been. Each page once.
enum Suggestions {
    static func offers(for typed: String, in browser: Browser, limit: Int = 8) -> [Suggestion] {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var rows: [Suggestion] = []
        var seen: Set<String> = []
        func add(_ row: Suggestion) {
            guard rows.count < limit, seen.insert(History.identity(for: row.url)).inserted || row.kind == .search else { return }
            rows.append(row)
        }

        // Where Return goes.
        if let url = Address.url(from: text) {
            add(Suggestion(key: Address.editable(url), title: "", url: url, kind: .known))
        } else if let url = browser.destination(for: text) {
            add(Suggestion(key: text, title: browser.settings.engine.title, url: url, kind: .search))
        }

        // A page already open in another tab: switching to it beats opening
        // it twice. Not the tab in front, which is where you already are.
        let lowered = text.lowercased()
        for tab in browser.spaceTabs where tab.id != browser.activeID {
            guard let url = tab.url, Continuity.page(url) != nil else { continue }
            let haystack = (tab.title + " " + url.absoluteString).lowercased()
            if haystack.contains(lowered) {
                add(Suggestion(key: Address.editable(url), title: tab.title, url: url, kind: .open, tab: tab.id))
            }
        }

        // A page open on another of your devices, and not here.
        for offer in Elsewhere.matching(text, in: browser.elsewhere, openHere: browser.openHere) { add(Suggestion(offer)) }

        for bookmark in browser.bookmarks.matching(text) {
            guard let url = bookmark.address else { continue }
            add(Suggestion(key: Address.editable(url), title: bookmark.title, url: url, kind: .bookmark))
        }

        for row in browser.history.suggestions(for: text, limit: limit) { add(row) }
        return rows
    }
}
