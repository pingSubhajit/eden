import EdenCore
import SwiftUI
import WebKit

// Hiding things on a page, by touch: the Mac's hidden elements (EdenCore's
// Curtain and Veiling), kept per site in the same hidden.json.
//
// "Hide Elements…" in the menu starts picking on the page in front. A tap —
// only a tap, so the page still scrolls — offers what it landed on, outlined
// and named in a bar over the page: Bigger widens it to what holds it, a
// finger usually landing on the innermost thing; Hide takes it off, now and
// every time the site is opened; Cancel lets it go. Links don't fire while
// picking, and a frame is offered whole. Picking ends when the page goes, or
// another tab comes to the front. "Hidden on This Site" lists what is hidden,
// half a sheet high so the page stays in view: tapping a row shows that thing
// again on the page, outlined and scrolled to, before it is restored or left.
//
// A private tab puts back what is kept, but its own changes — what it hides,
// what it restores — are its own, per site, for as long as it is open (and
// shared with the windows it opens, as its cookies are), and never touch
// what is kept.

/// A page as it showed in a tab, from the moment WebKit committed to it:
/// what is hidden, and picking, belong to the page showing — never to one
/// only being loaded, while the last is still in view.
struct ShownPage: Equatable {
    /// Counts the pages the tab has shown.
    let number: Int
    /// The site, as Curtain keys it.
    let host: String
}

/// Picking, while it is on: which page, in which tab. Everything the page
/// says carries `token`, so nothing said for an earlier session — or by a
/// page that has gone — is ever taken for this one's.
struct PickingSession: Equatable {
    let tab: Tab.ID
    let page: ShownPage
    let token = UUID().uuidString
}

/// A private tab's own changes to what is hidden, per site, for as long as it
/// is open: shared with the windows it opens, as its cookies are, and never
/// kept. One change per site and thing, merged over what is kept by selector.
@Observable
final class PrivateHiding {
    enum Change: Equatable {
        /// Hidden here, kept or not.
        case hidden(Veil)
        /// Kept, but shown here.
        case shown
    }

    /// By site, then selector.
    private(set) var changes: [String: [String: Change]] = [:]

    /// The sites with changes.
    var hosts: Set<String> { Set(changes.keys) }

    /// What is hidden on `host` here: what is kept, less what is shown here,
    /// and what is hidden here alone, in the order it was.
    func veils(over kept: [Veil], on host: String) -> [Veil] {
        guard let mine = changes[host] else { return kept }
        let keptSelectors = Set(kept.map(\.selector))
        let added = mine.values.compactMap { change -> Veil? in
            guard case .hidden(let veil) = change, !keptSelectors.contains(veil.selector) else { return nil }
            return veil
        }
        return kept.filter { mine[$0.selector] != .shown } + added.sorted { $0.date < $1.date }
    }

    func hide(_ veil: Veil, on host: String) {
        changes[host, default: [:]][veil.selector] = .hidden(veil)
    }

    /// One thing shown again here. `kept`: whether what is kept hides it — it
    /// then stays shown here, whatever is kept; otherwise it is simply no
    /// longer hidden here.
    func restore(_ selector: String, on host: String, kept: Bool) {
        changes[host, default: [:]][selector] = kept ? .shown : nil
        if changes[host]?.isEmpty == true { changes[host] = nil }
    }

    /// Everything shown again here: what is kept on `host` included.
    func restoreAll(on host: String, kept: [Veil]) {
        changes[host] = kept.isEmpty ? nil : Dictionary(kept.map { ($0.selector, .shown) }) { first, _ in first }
    }
}

extension Browser {
    // MARK: - what is hidden

    /// What is hidden on `host` for pages with `own` changes (a private tab's,
    /// or nil for an ordinary tab's): what is kept, and those changes.
    func veils(on host: String?, in own: PrivateHiding?) -> [Veil] {
        guard let host else { return [] }
        let kept = curtain.veils(on: host)
        return own?.veils(over: kept, on: host) ?? kept
    }

    /// What is hidden on the page a tab is showing.
    func veils(for tab: Tab) -> [Veil] { veils(on: tab.shown?.host, in: tab.privateHiding) }

    /// The stylesheet for the page a tab is showing, or without one thing.
    func css(for tab: Tab, without spared: String? = nil) -> String {
        Curtain.css(for: veils(for: tab), without: spared)
    }

    /// Every site's stylesheet for pages with `own` changes.
    func stylesheets(in own: PrivateHiding?) -> [String: String] {
        let hosts = Set(curtain.byHost.keys).union(own?.hosts ?? [])
        return Dictionary(uniqueKeysWithValues: hosts.map { ($0, Curtain.css(for: veils(on: $0, in: own))) })
    }

    // MARK: - the pages' scripts

    /// A page's content controller made ready, as its page is made: what the
    /// picker says heard through the one relay — a pop-up shares its opener's
    /// controller, so the relay is the browser's, never a tab's — and the
    /// scripts each page starts with. Hiding owns the controller's user
    /// scripts.
    func prepare(_ controller: WKUserContentController, for tab: Tab) {
        controller.removeScriptMessageHandler(forName: VeilRelay.name, contentWorld: Tab.world)
        controller.add(veilRelay, contentWorld: Tab.world, name: VeilRelay.name)
        install(style(in: tab.privateHiding), in: controller)
    }

    /// The picker, asleep until asked for, and the script putting on what is
    /// hidden — the same for every page of the controller, each page picking
    /// its own site's rules (Veiling.style(byHost:)).
    private func install(_ style: String?, in controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: Veiling.picker, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: Tab.world))
        guard let style else { return }
        controller.addUserScript(WKUserScript(source: style, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: Tab.world))
    }

    /// The script putting on what is hidden for pages with `own` changes, nil
    /// when nothing is hidden anywhere. What is kept is made once per change,
    /// whatever the number of tabs.
    private func style(in own: PrivateHiding?) -> String? {
        if own == nil, let keptStyle { return keptStyle.isEmpty ? nil : keptStyle }
        let sheets = stylesheets(in: own).filter { !$0.value.isEmpty }
        let made = sheets.isEmpty ? "" : Veiling.style(byHost: sheets)
        if own == nil { keptStyle = made }
        return made.isEmpty ? nil : made
    }

    /// What is hidden changed — what is kept (`own` nil), or one private
    /// tab's own: every page it reaches restyled now, and their controllers'
    /// scripts made again for the pages to come — each script made once, and
    /// each controller given it once.
    private func rulesChanged(in own: PrivateHiding?) {
        if own == nil { keptStyle = nil }
        var made: [ObjectIdentifier?: String?] = [:]
        var prepared = Set<ObjectIdentifier>()
        for tab in tabs where tab.isBuilt && (own == nil || tab.privateHiding === own) {
            let group = tab.privateHiding.map(ObjectIdentifier.init)
            let style = made[group] ?? style(in: tab.privateHiding)
            made[group] = style
            tab.run(style ?? Veiling.style(byHost: [:]))
            if prepared.insert(ObjectIdentifier(tab.contentController)).inserted {
                install(style, in: tab.contentController)
            }
        }
    }

    // MARK: - picking

    /// Picking on the page a tab is showing.
    func startHiding(_ tab: Tab) {
        stopHiding()
        guard let page = tab.shown else { return }
        let session = PickingSession(tab: tab.id, page: page)
        picking = session
        tab.run(Veiling.on(touch: true, session: session.token))
    }

    func stopHiding() {
        guard let session = picking else { return }
        tab(session.tab)?.run(Veiling.off(session: session.token))
        picking = nil
        offered = nil
    }

    /// Another page showing in `tab`. Picking on the last one is over — and
    /// switched off by its token, should the word to begin it have reached
    /// the new page instead. And the page is styled as what is hidden says
    /// now: one coming back from the back-forward cache never ran its scripts
    /// again, and may have been away while something changed.
    func pageChanged(in tab: Tab) {
        if picking?.tab == tab.id { stopHiding() }
        tab.run(style(in: tab.privateHiding) ?? Veiling.style(byHost: [:]))
    }

    /// What was offered, widened to what holds it.
    func widenOffer() { pickingTab?.run(Veiling.widen) }

    /// What was offered, hidden.
    func hideOffer() { pickingTab?.run(Veiling.confirm) }

    /// What was offered, let go.
    func clearOffer() {
        offered = nil
        pickingTab?.run(Veiling.clear)
    }

    private func tab(_ id: Tab.ID) -> Tab? { tabs.first { $0.id == id } }

    /// The tab being picked from, while it shows the page picking began on.
    private var pickingTab: Tab? {
        guard let session = picking, let tab = tab(session.tab), tab.shown == session.page else { return nil }
        return tab
    }

    func heard(_ said: VeilMessage, from origin: VeilRelay.Origin) {
        guard let session = picking, origin.session == session.token,
              let tab = pickingTab, tab.shows(origin.page) else { return }
        switch said {
        case .offered(let choice):
            offered = choice
        case .picked(let choice):
            offered = nil
            hide(choice, on: session.page.host, in: tab)
        case .withdrawn:
            offered = nil
            announce("That's gone from the page")
        case .ended:
            picking = nil
            offered = nil
        case .trouble:
            announce("That can't be hidden")
        }
    }

    // MARK: - changing what is hidden

    /// One thing hidden on `host`: kept, or a private tab's own.
    func hide(_ choice: VeilMessage.Choice, on host: String, in tab: Tab) {
        guard !veils(on: host, in: tab.privateHiding).contains(where: { $0.selector == choice.selector }) else { return }
        if let own = tab.privateHiding {
            own.hide(Veil(selector: choice.selector, label: choice.label, note: choice.note, date: Date()), on: host)
        } else {
            curtain.hide(choice.selector, label: choice.label, note: choice.note, on: host)
        }
        rulesChanged(in: tab.privateHiding)
        announce("Hidden")
    }

    func restore(_ veil: Veil, on host: String, in tab: Tab) {
        if let own = tab.privateHiding {
            own.restore(veil.selector, on: host, kept: curtain.veils(on: host).contains { $0.selector == veil.selector })
        } else {
            curtain.restore(veil, on: host)
        }
        rulesChanged(in: tab.privateHiding)
    }

    func restoreAll(on host: String, in tab: Tab) {
        if let own = tab.privateHiding {
            own.restoreAll(on: host, kept: curtain.veils(on: host))
        } else {
            curtain.restoreAll(on: host)
        }
        rulesChanged(in: tab.privateHiding)
    }

    /// One hidden thing shown again on the page, outlined and scrolled to.
    func peek(_ veil: Veil, on tab: Tab) {
        tab.run(Veiling.peek(veil.selector, keeping: css(for: tab, without: veil.selector)))
    }

    func unpeek(_ tab: Tab) { tab.run(Veiling.unpeek(css(for: tab))) }
}

/// The bar over a page being picked from: what a tap offered, and what to do
/// with it.
struct HidingBar: View {
    let browser: Browser

    var body: some View {
        VStack(spacing: 10) {
            if let offered = browser.offered {
                VStack(spacing: 2) {
                    Text(offered.label).font(.headline).lineLimit(1)
                    if !offered.note.isEmpty {
                        Text(offered.note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("hiding-offer")
                // Side by side while they fit; stacked at the larger text sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { choices }
                    VStack(spacing: 8) { choices }
                }
            } else {
                Text("Tap what to hide").font(.headline)
            }
            Button("Done") { browser.stopHiding() }
                .accessibilityIdentifier("hide-done")
        }
        .padding(16)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        // A container of its own, so its buttons keep their names.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hiding-bar")
    }

    @ViewBuilder private var choices: some View {
        Button("Cancel") { browser.clearOffer() }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("hide-cancel")
        Button("Bigger", systemImage: "arrow.up.left.and.arrow.down.right") { browser.widenOffer() }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("hide-widen")
        Button("Hide", systemImage: "eye.slash") { browser.hideOffer() }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("hide-confirm")
    }
}

/// What is hidden on the site in front, half a sheet high so the page stays
/// in view: a tap shows one again on the page before it is restored.
struct HiddenSheet: View {
    let browser: Browser
    let tab: Tab
    /// Watched, so a restore — one or all — shows at once.
    @ObservedObject var curtain: Curtain
    @Environment(\.dismiss) private var dismiss
    @State private var shown: String?

    /// The site of the page showing.
    private var host: String? { tab.shown?.host }
    private var veils: [Veil] { browser.veils(on: host, in: tab.privateHiding) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(veils) { veil in
                    Button {
                        shown = veil.selector
                        browser.peek(veil, on: tab)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(veil.label).lineLimit(1)
                                if let note = veil.note, !note.isEmpty {
                                    Text(note).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if shown == veil.selector {
                                Image(systemName: "eye").foregroundStyle(.secondary).accessibilityLabel("Shown on the page")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions { Button("Restore") { restore(veil) }.tint(.accentColor) }
                    .contextMenu { Button("Restore", systemImage: "eye") { restore(veil) } }
                    .accessibilityIdentifier("hidden-row")
                    .accessibilityAction(named: "Restore") { restore(veil) }
                }
                if veils.isEmpty {
                    Text("Nothing is hidden here.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(host ?? "This Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Restore All") {
                        shown = nil
                        if let host { browser.restoreAll(on: host, in: tab) }
                    }
                    .disabled(veils.isEmpty)
                    .accessibilityIdentifier("restore-all")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        // Leaving puts the page back as what is hidden says.
        .onDisappear { browser.unpeek(tab) }
    }

    private func restore(_ veil: Veil) {
        if shown == veil.selector { shown = nil }
        if let host { browser.restore(veil, on: host, in: tab) }
    }
}
