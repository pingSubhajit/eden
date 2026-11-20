import EdenCore
import UIKit
import WebKit

// Pictures of pages for the tab overview's cards. A tab whose page has been
// seen has its own (Tab.capture), and an ordinary one's is kept on disk by
// its page (PagePictures, as the Mac's hover cards keep theirs), so a tab
// brought back at the next launch shows its page at once.
// One with none at all has its page loaded out of sight, behind the app, and
// photographed there, the tabs nearest the one in front first, one at a
// time, while the overview is open. Never on disk for a private tab, and
// Clear History takes them all.

@MainActor
final class CardPictures {
    static let shared = CardPictures()

    /// Tabs still to have a picture, nearest the one in front first.
    private var waiting: [Tab] = []
    private var working = false
    /// Where a page is loaded and photographed out of sight: behind the
    /// app's own view, in its window.
    private var stage: UIView?

    /// The longest a page has to load before it is photographed as it is.
    private static let patience: TimeInterval = 10

    /// An ordinary tab's picture of `url`, drawn with the website store
    /// `store`, kept for the next launch; `ticket` taken before it was drawn.
    func keep(_ picture: UIImage, for url: URL, store: UUID?, ticket: PagePictures.Ticket) {
        guard let data = picture.jpegData(compressionQuality: 0.72) else { return }
        PagePictures.shared.keep(data, for: url, store: store, ticket: ticket)
    }

    /// Pictures for `tabs`, in their order: those kept on disk first, then
    /// the rest by loading their pages out of sight.
    func want(_ tabs: [Tab]) {
        waiting = tabs.filter { $0.snapshot == nil && $0.url != nil }
        guard !working, !waiting.isEmpty else { return }
        working = true
        Task {
            await work()
            working = false
        }
    }

    /// The overview gone: no more pages loaded for it.
    func stop() {
        waiting = []
    }

    /// Clear History: every picture kept goes.
    func forgetAll() {
        PagePictures.shared.forgetAll()
    }

    private func work() async {
        // Those kept on disk: quick, so all of them first.
        for tab in waiting where !tab.isPrivate {
            guard tab.snapshot == nil, let url = tab.url else { continue }
            let data = await PagePictures.shared.kept(for: url, store: tab.storeID)
            if let data, let picture = UIImage(data: data) { tab.adopt(snapshot: picture) }
        }
        // The rest, one page at a time.
        while !waiting.isEmpty {
            let tab = waiting.removeFirst()
            guard tab.snapshot == nil, tab.url != nil else { continue }
            await photograph(tab)
        }
    }

    /// `tab`'s page, made and loaded if it wasn't, behind the app where it
    /// can't be seen, and photographed once it has drawn.
    private func photograph(_ tab: Tab) async {
        guard let stage = stageInWindow() else { return }
        let page = tab.webView
        // Shown somewhere already: its own picture comes from there.
        guard page.superview == nil else { return }
        page.translatesAutoresizingMaskIntoConstraints = true
        page.frame = stage.bounds
        stage.addSubview(page)
        defer { if page.superview === stage { page.removeFromSuperview() } }
        let deadline = Date().addingTimeInterval(Self.patience)
        try? await Task.sleep(for: .milliseconds(300))
        while page.superview === stage, page.isLoading || page.estimatedProgress < 1, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        // A moment to draw what it has loaded.
        try? await Task.sleep(for: .milliseconds(350))
        guard page.superview === stage else { return }
        _ = await tab.capture()
    }

    private func stageInWindow() -> UIView? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        guard let window else { return nil }
        if let stage, stage.window === window {
            stage.frame = window.bounds
            return stage
        }
        let made = UIView(frame: window.bounds)
        made.isUserInteractionEnabled = false
        made.accessibilityElementsHidden = true
        made.clipsToBounds = true
        // Under the app's own view, which covers it.
        window.insertSubview(made, at: 0)
        stage = made
        return made
    }
}
