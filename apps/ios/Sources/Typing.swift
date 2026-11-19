import EdenCore
import Observation
import SwiftUI

/// What is being typed in the address field, and where it goes: shared by
/// the iPhone's bar and the iPad's, which differ only in where they sit.
@Observable
final class Typing {
    var text = ""
    var editing = false
    /// What is selected in the field: all of the address it starts with, so
    /// typing replaces it, as in Safari; a tap puts the cursor where it lands.
    var selection: TextSelection?

    /// Starts typing over the tab's address, or an empty field.
    func start(over tab: Tab?) {
        text = tab?.url.flatMap { Continuity.page($0) }.map(Address.editable) ?? ""
        selection = nil
        editing = true
    }

    /// The field has the keyboard: all of the address in it selected. Only
    /// once it has it — selected before, the field putting its cursor at the
    /// end as it takes the keyboard undid it.
    func focused() {
        let typed = text
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.editing, self.text == typed, !typed.isEmpty else { return }
            self.selection = TextSelection(range: typed.startIndex..<typed.endIndex)
        }
    }

    func cancel() {
        editing = false
    }

    /// Return: what was typed opened in the tab in front, or a new tab.
    func submit(in browser: Browser) {
        if browser.go(text, in: browser.active) { editing = false }
    }

    /// A suggestion picked: its tab if it is open, else its page here.
    func pick(_ offer: Suggestion, in browser: Browser) {
        defer { editing = false }
        if offer.kind == .open, let id = offer.tab, let tab = browser.tabs.first(where: { $0.id == id }) {
            browser.select(tab)
            return
        }
        if let elsewhere = offer.elsewhere {
            browser.open(elsewhere, in: browser.active?.url == nil ? browser.active : nil)
            return
        }
        if let tab = browser.active {
            tab.load(offer.url)
            browser.select(tab)
        } else {
            browser.newTab(url: offer.url)
        }
    }

    func offers(in browser: Browser) -> [Suggestion] {
        Suggestions.offers(for: text, in: browser)
    }
}

/// The page, its start page, or why it didn't arrive.
struct TabContent: View {
    let browser: Browser
    let tab: Tab?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let tab, tab.url != nil, !Clearing.shared.done {
            // A test's fresh start still clearing its website store: the page
            // is made, and loads, once it has (EdenApp.startFreshIfAsked).
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let tab, tab.url != nil {
            PageView(tab: tab)
                // Up under the status bar, as in Safari, the page told how
                // much of it lies there (pageTop).
                .ignoresSafeArea(edges: .top)
                .overlay {
                    if let failure = tab.failure {
                        ContentUnavailableView {
                            Label("Can't Open the Page", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(failure)
                        } actions: {
                            Button("Try Again") { tab.reload() }
                        }
                        .background(Color(.systemBackground))
                        .accessibilityIdentifier("failure")
                    }
                }
        } else {
            StartPage(browser: browser, tab: tab)
                .environment(\.colorScheme, tab?.isPrivate == true ? .dark : colorScheme)
        }
    }
}
