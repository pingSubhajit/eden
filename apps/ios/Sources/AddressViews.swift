import EdenCore
import SwiftUI

/// The address field at rest: the site you're on, or what to type. A tap
/// starts typing (`edit`); the arrow beside it reloads, or stops a load.
/// `leading`: what sits at its start (the iPhone's page menu). The field
/// draws no surface of its own: each layout puts it on its own.
struct AddressPill<Leading: View>: View {
    let tab: Tab?
    var height: CGFloat = 44
    /// Shrunk to the site's name as the page is read (the iPhone's bar): what
    /// is either side folds away and the name gets smaller, a tap bringing
    /// the bar back rather than starting to type.
    var compact = false
    /// How wide `leading` is, for it to fold away when compact.
    var leadingWidth: CGFloat?
    let edit: () -> Void
    let leading: Leading

    init(tab: Tab?, height: CGFloat = 44, compact: Bool = false, leadingWidth: CGFloat? = nil,
         edit: @escaping () -> Void, @ViewBuilder leading: () -> Leading) {
        self.tab = tab
        self.height = height
        self.compact = compact
        self.leadingWidth = leadingWidth
        self.edit = edit
        self.leading = leading()
    }

    var body: some View {
        HStack(spacing: compact ? 0 : 8) {
            leading
                .frame(width: compact ? 0 : leadingWidth)
                .opacity(compact ? 0 : 1)
                .clipped()
            Button(action: edit) {
                HStack(spacing: 6) {
                    if let tab, tab.isPrivate {
                        Image(systemName: "eye.slash").font(.footnote).foregroundStyle(.secondary)
                    } else if let url = tab?.url, url.scheme == "http" {
                        // Plain http always says so.
                        Image(systemName: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                    Text(label)
                        // The name smaller, shrunk, as Safari's: its size
                        // itself moving from one to the other, so it is laid
                        // out — and fits — at every size between.
                        .modifier(EasedFont(size: compact ? AddressPill.compactSize : AddressPill.fullSize))
                        .foregroundStyle(tab?.url == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(compact ? "address-tucked" : "address")
            .accessibilityLabel(tab?.url == nil ? "Search or enter address" : "Address, \(label)")
            .accessibilityHint(compact ? "Shows the toolbar" : "")

            if let tab, tab.url != nil {
                Button(tab.isLoading ? "Stop" : "Reload", systemImage: tab.isLoading ? "xmark" : "arrow.clockwise") {
                    tab.isLoading ? tab.stop() : tab.reload()
                }
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: compact ? 0 : 22)
                .frame(maxHeight: .infinity)
                .opacity(compact ? 0 : 1)
                .allowsHitTesting(!compact)
                .contentShape(Rectangle())
                .accessibilityIdentifier("reload")
            }
        }
        .padding(.horizontal, compact ? 12 : 14)
        .frame(height: height)
        .overlay(alignment: .bottom) { LoadProgress(tab: tab) }
    }

    private var label: String { Address.label(for: tab) }
}

extension AddressPill {
    /// The name's size in full, and shrunk: the body's and the footnote's.
    static var fullSize: CGFloat { UIFont.preferredFont(forTextStyle: .body).pointSize }
    static var compactSize: CGFloat { UIFont.preferredFont(forTextStyle: .footnote).pointSize }
}

/// A font whose size moves smoothly as it changes, every size between laid
/// out as it goes.
private struct EasedFont: ViewModifier, Animatable {
    var size: CGFloat

    var animatableData: CGFloat {
        get { size }
        set { size = newValue }
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size))
    }
}

extension AddressPill where Leading == EmptyView {
    init(tab: Tab?, height: CGFloat = 44, edit: @escaping () -> Void) {
        self.init(tab: tab, height: height, edit: edit) { EmptyView() }
    }
}

extension Address {
    /// The site's name without its www, as the Mac's field shows a page at
    /// rest; the page's own address when it has no host.
    static func label(for tab: Tab?) -> String {
        guard let url = tab?.url else { return "Search or enter address" }
        if let host = url.host(), !host.isEmpty { return Address.withoutWWW(host) }
        return Address.pretty(url)
    }
}

/// How far the page in front has loaded: a line along the foot of the field.
struct LoadProgress: View {
    let tab: Tab?

    var body: some View {
        if let tab, tab.isLoading, tab.progress < 1 {
            GeometryReader { size in
                Capsule().fill(Color.accentColor)
                    .frame(width: max(8, size.size.width * tab.progress), height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 18)
            .accessibilityHidden(true)
        }
    }
}

/// The address field while typing: the words, a way to clear them, and the
/// keyboard's Go. Like the field at rest, it draws no surface of its own.
struct AddressEditor: View {
    @Binding var text: String
    @Binding var selection: TextSelection?
    var focus: FocusState<Bool>.Binding
    var height: CGFloat = 44
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search or enter address", text: $text, selection: $selection)
                .focused(focus)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)
                .accessibilityIdentifier("address-field")
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: height)
    }
}

/// The rows under the address field (Suggestions).
struct SuggestionList: View {
    let offers: [Suggestion]
    let pick: (Suggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(offers) { offer in
                Button { pick(offer) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: offer.elsewhere?.kind.symbol ?? symbol(offer.kind))
                            .frame(width: 22)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(primary(offer)).lineLimit(1)
                            if let secondary = secondary(offer) {
                                Text(secondary).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if let elsewhere = offer.elsewhere {
                            Text("On \(elsewhere.deviceName)").font(.footnote).foregroundStyle(.secondary)
                        } else if offer.kind == .open {
                            Text("Switch to Tab").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("suggestion")
                Divider().padding(.leading, 50)
            }
        }
    }

    private func symbol(_ kind: Suggestion.Kind) -> String {
        switch kind {
        case .search, .suggested, .searched: return "magnifyingglass"
        case .open: return "square.on.square"
        case .elsewhere: return "laptopcomputer.and.iphone"
        case .bookmark: return "book"
        case .visited: return "clock"
        case .known, .command: return "globe"
        }
    }

    private func primary(_ offer: Suggestion) -> String {
        switch offer.kind {
        case .search: return offer.key
        default: return offer.title.isEmpty ? offer.key : offer.title
        }
    }

    private func secondary(_ offer: Suggestion) -> String? {
        switch offer.kind {
        case .search: return "Search \(offer.title)"
        default: return offer.title.isEmpty ? nil : offer.key
        }
    }
}

/// The browser's menu: what isn't a button of its own on the bar. `face`:
/// how it looks there, the iPad's "More" unless told otherwise.
struct BrowserMenu<Face: View>: View {
    let browser: Browser
    let tab: Tab?
    @Binding var sheet: BrowserSheet?
    let face: Face
    @State private var renaming: Tab?

    init(browser: Browser, tab: Tab?, sheet: Binding<BrowserSheet?>, @ViewBuilder face: () -> Face) {
        self.browser = browser
        self.tab = tab
        _sheet = sheet
        self.face = face()
    }

    var body: some View {
        Menu {
            if let tab, let url = tab.url, Continuity.page(url) != nil {
                let kept = browser.bookmarks.contains(url)
                Button(kept ? "Remove Bookmark" : "Add Bookmark", systemImage: kept ? "bookmark.slash" : "bookmark") {
                    browser.bookmarks.toggle(url, title: tab.title.isEmpty ? Address.pretty(url) : tab.title)
                }
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                Button(tab.isReading ? "Leave Reading Mode" : "Reading Mode",
                       systemImage: tab.isReading ? "doc.richtext" : "doc.plaintext") {
                    browser.toggleReading(tab)
                }
                .accessibilityIdentifier("reading-mode")
                Button("Hide Elements…", systemImage: "eye.slash") { browser.startHiding(tab) }
                    .disabled(tab.shown == nil)
                    .accessibilityIdentifier("hide-elements")
                if !browser.veils(for: tab).isEmpty {
                    Button("Hidden on This Site", systemImage: "eye") { sheet = .hidden }
                        .accessibilityIdentifier("hidden-here")
                }
                Divider()
            }
            if let tab, browser.pinDef(of: tab) != nil {
                Menu("Pin", systemImage: "pin") { PinActions(browser: browser, tab: tab, renaming: $renaming) }
                    .accessibilityIdentifier("pin-menu")
            } else if let tab, browser.canPin(tab) {
                PinActions(browser: browser, tab: tab, renaming: $renaming)
            }
            Button("New Tab", systemImage: "plus.square") { browser.newTab() }
            Button("New Private Tab", systemImage: "eye.slash") { browser.newTab(private: true) }
            Divider()
            Button("Bookmarks", systemImage: "book") { sheet = .bookmarks }
            Button("History", systemImage: "clock") { sheet = .history }
            Button("Settings", systemImage: "gearshape") { sheet = .settings }
        } label: {
            face
        }
        .accessibilityIdentifier("menu")
        .pinRenaming($renaming, browser: browser)
    }
}

extension BrowserMenu where Face == Label<Text, Image> {
    init(browser: Browser, tab: Tab?, sheet: Binding<BrowserSheet?>) {
        self.init(browser: browser, tab: tab, sheet: sheet) { Label("More", systemImage: "ellipsis.circle") }
    }
}

/// The sheets the menu opens.
enum BrowserSheet: String, Identifiable {
    case bookmarks, history, settings, hidden
    var id: String { rawValue }
}
