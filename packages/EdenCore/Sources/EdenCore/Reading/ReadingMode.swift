import Foundation
import WebKit

/// A page turned into its article, in the web view showing it: the site's
/// Markdown twin when asked for and there is one (Reader.twin, drawn by
/// Markdown), else the guess (Reader.script). The same on the Mac, iPhone and
/// iPad; each app keeps whether a tab is reading, and leaves reading mode by
/// reloading — putting the old markup back would give a page that looks right
/// and does nothing, its listeners gone with it.
@MainActor
public enum ReadingMode {
    /// How it went.
    public enum Outcome: Equatable, Sendable {
        /// The page is its article now.
        case read
        /// The page has no article to read.
        case nothing
        /// The page asked about went away meanwhile: nothing was done, and
        /// nothing should be said about it.
        case gone
    }

    /// The page in `web`, as its article. `twins`: ask the site for its
    /// Markdown copy first. `world`: the app's own content world, where the
    /// twin is fetched (the guess runs in the page's, which it rewrites).
    /// `current`: whether the page asked about is still the one showing,
    /// asked after every wait, before anything is done with what came back.
    public static func enter(_ web: WKWebView, twins: Bool, look: ReadingLook, world: WKContentWorld,
                             current: () -> Bool) async -> Outcome {
        if twins {
            let found = await fetchTwin(in: web, world: world)
            guard current() else { return .gone }
            // Drawn only once it is known to be for the page still showing.
            if let found, let drawn = draw(found) {
                let shown = await show(drawn, in: web, look: look, world: world)
                guard current() else { return .gone }
                if shown { return .read }
            }
        }
        guard current() else { return .gone }
        let arguments: [String: Any] = ["sheet": Reader.sheet, "readerLook": look.rawValue]
        let answer = try? await web.callAsyncJavaScript(Reader.script, arguments: arguments, contentWorld: .page)
        guard current() else { return .gone }
        return answer as? String == "read" ? .read : .nothing
    }

    /// The site's Markdown copy of the page, as fetched; nil when it has none.
    private static func fetchTwin(in web: WKWebView, world: WKContentWorld) async -> [String: Any]? {
        (try? await web.callAsyncJavaScript(Reader.twin, contentWorld: world)) as? [String: Any]
    }

    /// The copy drawn as HTML, and where it came from.
    private static func draw(_ found: [String: Any]) -> (page: Markdown.Page, from: String)? {
        guard let text = found["text"] as? String,
              let address = (found["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        var page = Markdown.page(text, base: address)
        guard !page.html.isEmpty else { return nil }
        if page.title == nil { page.title = found["title"] as? String }
        let from = (found["from"] as? String).map { $0.isEmpty ? "markdown" : "\($0) · markdown" } ?? "markdown"
        return (page, from)
    }

    private static func show(_ twin: (page: Markdown.Page, from: String), in web: WKWebView, look: ReadingLook,
                             world: WKContentWorld) async -> Bool {
        let arguments: [String: Any] = [
            "html": twin.page.html,
            "title": twin.page.title ?? "",
            "from": twin.from,
            "sheet": Reader.sheet,
            "readerLook": look.rawValue,
        ]
        return (try? await web.callAsyncJavaScript(Reader.show, arguments: arguments, contentWorld: world)) as? String == "read"
    }
}
