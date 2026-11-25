import AppKit
import SwiftUI

// The address bar at the top of the column, under the traffic lights and
// back, forward and reload: where the page you are on is, said as its site
// and nothing more. Under the pointer it shows the pinned extensions, a
// button that copies the address and one for the site's controls
// (SiteControls). A click on it raises the address field over it, reaching
// out over the page with the whole address selected (Browser.editFromBar);
// ⌘L and ⌘T keep theirs in the middle of the page.

struct AddressBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @Environment(\.greys) private var greys
    @State private var hovering = false
    /// The address just copied: the button wears a tick for a moment
    /// instead of a toast.
    @State private var copied = false
    /// Where the bar is in the window, for the field to come up over it.
    @State private var frame: CGRect = .zero
    /// How much of the bar its buttons take while they show.
    @State private var controlsWidth: CGFloat = 0

    private var tab: Tab? { browser.active }
    private var web: Bool { tab?.isWeb == true }
    /// The buttons show under the pointer, and stay while what they opened
    /// is open, or their tick is up. Whatever is in front, a website or
    /// not: the extensions are reached from here.
    private var showing: Bool { hovering || browser.siteControlsShown || copied }

    /// Drawn again as the tab in front changes, not only as another comes
    /// to the front: its address, a website or not, what a drag carries.
    var body: some View {
        Watching(tab: tab) { bar }
    }

    private var bar: some View {
        words
            .padding(.leading, 12)
            .padding(.trailing, showing ? controlsWidth + 4 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.bar)
            .overlay(alignment: .trailing) { controls }
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(greys.tile)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
            .onTapGesture { browser.editFromBar(at: frame) }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { moved in
                frame = moved
                browser.barMoved(to: moved)
            }
            .onHover { hovering = $0 }
            .contextMenu { if web, let tab { menu(tab) } }
            .modifier(Draggable(url: tab?.pageAddress))
            .task(id: copied) {
                // The tick says it is done, then the button is a button again.
                guard copied else { return }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
            .animation(Motion.quick, value: showing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Address")
            .accessibilityAction(named: "Edit Address") { browser.editFromBar(at: frame) }
    }

    /// The site, or for one of Eden's own pages its name; with nothing to
    /// show, what the bar is for.
    @ViewBuilder private var words: some View {
        if let tab, !tab.isBlank {
            Site(tab: tab, size: prefs.sideTitle)
        } else {
            Text("Enter a web address")
                .font(.system(size: prefs.sideTitle, weight: .medium))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }
    }

    private struct Site: View {
        @ObservedObject var tab: Tab
        let size: CGFloat

        private var words: String {
            if tab.page == nil, let url = tab.pageAddress { return SiteName.of(url) }
            return tab.label
        }

        var body: some View {
            Text(words)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Palette.ink.opacity(0.8))
                .lineLimit(1)
                .fadesOut(words)
                .accessibilityLabel(words)
        }
    }

    // MARK: - the buttons at its end

    /// The pinned extensions, as many as leave the site some room, then the
    /// address copied, on a website, then the site's controls. Laid out
    /// even while they don't show, so an extension's popup has its button
    /// to hang from.
    private var controls: some View {
        HStack(spacing: 2) {
            PinnedExtensions(browser: browser, room: room)
            if web, let tab {
                Door(icon: copied ? "checkmark" : "link", help: Self.help("Copy Address", "tabs.copyAddress")) {
                    browser.copyAddresses(of: [tab], quietly: true)
                    copied = true
                }
            }
            Door(icon: "slider.horizontal.3", on: browser.siteControlsShown, help: "Site Controls") {
                browser.siteControlsShown.toggle()
            }
            .background(ExtensionAnchor(id: ExtensionAnchor.controls, browser: browser))
            .popover(isPresented: $browser.siteControlsShown, arrowEdge: .bottom) {
                SiteControls(browser: browser, tab: tab) { browser.siteControlsShown = false }
                    .popoverGround()
            }
        }
        .padding(.trailing, 4)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { controlsWidth = $0 }
        .opacity(showing ? 1 : 0)
        .allowsHitTesting(showing)
    }

    /// How many pinned extensions fit beside the buttons that stay, leaving
    /// the site at least a short word's room. Every button is 26 points,
    /// with 2 between them.
    private var room: Int {
        let button: CGFloat = 26 + 2
        let free = frame.width - 12 - 64 - CGFloat(web ? 2 : 1) * button - 4
        return max(0, Int((free / button).rounded(.down)))
    }

    private static func help(_ title: String, _ command: String) -> String {
        ShortcutStore.shared.key(for: command).map { "\(title)   \($0.display)" } ?? title
    }

    // MARK: - its menu

    @ViewBuilder private func menu(_ tab: Tab) -> some View {
        Button("Copy Address") { browser.copyAddresses(of: [tab]) }
        Button("Copy as Markdown Link") { browser.copyMarkdownLinks(of: [tab]) }
        Button("Copy Clean Link") { browser.copyCleanLinks(of: [tab]) }
        Divider()
        Button("Share…") { browser.share() }
        if prefs.capturesPages {
            Button("Capture…") { browser.toggleSnap() }
        }
        Button("Hide Elements…") { browser.toggleHiding() }
        Divider()
        Button("Site Controls…") { browser.siteControlsShown = true }
    }
}

/// The site carried off the bar is its address, as a link: onto another
/// app, the page, or the column.
private struct Draggable: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            content.onDrag { NSItemProvider(object: url as NSURL) }
        } else {
            content
        }
    }
}
