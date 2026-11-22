import SwiftUI

/// Back, forward, reload. They watch the live tab, not the window: whether
/// there is anywhere to go back to is the tab's to say, and it changes with
/// every page. Beside the traffic lights, at the column's top.
struct Helm: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if let tab = browser.active {
            Wheel(browser: browser, tab: tab)
        } else {
            // Nowhere to go and nothing to reload: the doors stay in place,
            // greyed, so the row doesn't shift when a tab arrives.
            HStack(spacing: 4) {
                Door(icon: "chevron.left") {}
                Door(icon: "chevron.right") {}
                Door(icon: "arrow.clockwise") {}
            }
            .opacity(0.3)
            .allowsHitTesting(false)
        }
    }

    private struct Wheel: View {
        let browser: Browser
        @ObservedObject var tab: Tab

        var body: some View {
            let back = !tab.isBlank && tab.canGoBack
            let forward = !tab.isBlank && tab.canGoForward
            HStack(spacing: 4) {
                Door(icon: "chevron.left", help: "Back   ⌘[", held: { Rewind.menu(tab, back: true) }) { browser.back() }
                    .disabled(!back)
                    .opacity(back ? 1 : 0.3)
                Door(icon: "chevron.right", help: "Forward   ⌘]", held: { Rewind.menu(tab, back: false) }) { browser.forward() }
                    .disabled(!forward)
                    .opacity(forward ? 1 : 0.3)
                // Reload, or stop while it is still coming.
                Door(
                    icon: tab.loading ? "xmark" : "arrow.clockwise",
                    help: tab.loading ? "Stop   ⌘." : "Reload   ⌘R"
                ) {
                    if tab.loading { tab.stop() } else { browser.reload() }
                }
                .disabled(!tab.isWeb)
                .opacity(tab.isWeb ? 1 : 0.3)
                // The menu's second item is the reason for it: ⌥⌘R has no
                // button. Nothing to offer while the door is Stop.
                .contextMenu {
                    if !tab.loading && tab.isWeb {
                        Button("Reload Page") { browser.reload() }
                            .shortcut("view.reload")
                        Button("Reload Page From Origin") { browser.reload(fromOrigin: true) }
                            .shortcut("view.reloadOrigin")
                    }
                }
            }
            .animation(Motion.quick, value: back)
            .animation(Motion.quick, value: forward)
            .animation(Motion.quick, value: tab.loading)
        }
    }
}

/// Back or Forward held: every page that way, nearest at the top, each with
/// its site's mark, as Safari and Chrome list them. Picking one goes straight
/// there, however many steps away. Read when the menu opens, so it is never
/// a page behind.
@MainActor
enum Rewind {
    static func menu(_ tab: Tab, back: Bool) -> NSMenu? {
        let pages = tab.pages(back: back)
        guard !pages.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for page in pages {
            let title = page.title.flatMap { $0.isEmpty ? nil : $0 } ?? page.url.host() ?? page.url.absoluteString
            let item = Pick(title: title) { [weak tab] in tab?.go(to: page) }
            item.toolTip = page.url.absoluteString
            if let image = Favicons.shared.cached(for: page.url, shy: tab.shy)?.copy() as? NSImage {
                image.size = NSSize(width: 16, height: 16)
                item.image = image
            } else {
                item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        return menu
    }

    /// A menu row that runs its own closure, its own target.
    private final class Pick: NSMenuItem {
        private let run: () -> Void

        init(title: String, run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) { fatalError() }

        @objc private func fire() { run() }
    }
}
