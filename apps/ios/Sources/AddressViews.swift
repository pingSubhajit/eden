import EdenCore
import SwiftUI

/// The address field at rest: the site you're on, or what to type. A tap
/// starts typing (`edit`); the arrow beside it reloads, or stops a load.
struct AddressPill: View {
    let tab: Tab?
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: edit) {
                HStack(spacing: 6) {
                    if let tab, tab.isPrivate {
                        Image(systemName: "eye.slash").font(.footnote).foregroundStyle(.secondary)
                    } else if let url = tab?.url, url.scheme == "http" {
                        // Plain http always says so.
                        Image(systemName: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                    Text(label)
                        .font(.body)
                        .foregroundStyle(tab?.url == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("address")
            .accessibilityLabel(tab?.url == nil ? "Search or enter address" : "Address, \(label)")

            if let tab, tab.url != nil {
                Button(tab.isLoading ? "Stop" : "Reload", systemImage: tab.isLoading ? "xmark" : "arrow.clockwise") {
                    tab.isLoading ? tab.stop() : tab.reload()
                }
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("reload")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(alignment: .bottom) {
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

    /// The site's name without its www, as the Mac's field shows a page at
    /// rest; the page's own address when it has no host.
    private var label: String {
        guard let url = tab?.url else { return "Search or enter address" }
        if let host = url.host(), !host.isEmpty { return Address.withoutWWW(host) }
        return Address.pretty(url)
    }
}

/// The address field while typing: the words, a way to clear them, and the
/// keyboard's Go.
struct AddressEditor: View {
    @Binding var text: String
    @Binding var selection: TextSelection?
    var focus: FocusState<Bool>.Binding
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
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
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
                        Image(systemName: symbol(offer.kind))
                            .frame(width: 22)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(primary(offer)).lineLimit(1)
                            if let secondary = secondary(offer) {
                                Text(secondary).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if offer.kind == .open {
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

/// The browser's menu: what isn't a button of its own on the bar.
struct BrowserMenu: View {
    let browser: Browser
    let tab: Tab?
    @Binding var sheet: BrowserSheet?

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
                Divider()
            }
            Button("New Tab", systemImage: "plus.square") { browser.newTab() }
            Button("New Private Tab", systemImage: "eye.slash") { browser.newTab(private: true) }
            Divider()
            Button("Bookmarks", systemImage: "book") { sheet = .bookmarks }
            Button("History", systemImage: "clock") { sheet = .history }
            Button("Settings", systemImage: "gearshape") { sheet = .settings }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("menu")
    }
}

/// The sheets the menu opens.
enum BrowserSheet: String, Identifiable {
    case bookmarks, history, settings
    var id: String { rawValue }
}
