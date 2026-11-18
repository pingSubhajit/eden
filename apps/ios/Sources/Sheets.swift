import EdenCore
import SwiftUI

/// Your bookmarks: tap to open in the tab in front, swipe to let one go.
struct BookmarksSheet: View {
    let browser: Browser
    let open: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(browser.bookmarks.items) { mark in
                    Button {
                        if let url = mark.address { open(url) }
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mark.label).lineLimit(1)
                            if let url = mark.address {
                                Text(Address.pretty(url)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        // The whole row answers a tap, not only its words.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bookmark-row")
                }
                .onDelete { browser.bookmarks.remove(at: $0) }
            }
            .overlay {
                if browser.bookmarks.items.isEmpty {
                    ContentUnavailableView("No Bookmarks", systemImage: "book",
                                           description: Text("Add one from the menu on any page."))
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
    }
}

/// Where you have been, newest first, searchable: tap to go back, swipe to
/// forget one place, or clear it all.
struct HistorySheet: View {
    let browser: Browser
    let open: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var asking = false
    /// Read again after each change to the history, or to what is searched.
    @State private var traces: [History.Trace] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(traces) { trace in
                    Button {
                        open(trace.url)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trace.title.isEmpty ? trace.address : trace.title).lineLimit(1)
                            Text("\(trace.address) · \(trace.last.formatted(.relative(presentation: .named)))")
                                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("history-row")
                }
                .onDelete { offsets in
                    for index in offsets { browser.history.forget(traces[index].key) }
                    reread()
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search History")
            .onChange(of: query) { _, _ in reread() }
            .onAppear(perform: reread)
            // A visit recorded, or the history finishing its load, behind the
            // sheet: read again once the change has landed (History says it
            // is coming before it does).
            .onReceive(browser.history.objectWillChange) { _ in
                Task { @MainActor in
                    await Task.yield()
                    reread()
                }
            }
            .overlay {
                if traces.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No History" : "Nothing Found", systemImage: "clock")
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { asking = true }
                        .disabled(traces.isEmpty && query.isEmpty)
                        .accessibilityIdentifier("clear-history")
                }
            }
            .confirmationDialog("Clear all history?", isPresented: $asking, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) {
                    browser.history.forget()
                    reread()
                }
            } message: {
                Text("Every place you have been, on this device. Bookmarks and open tabs stay.")
            }
        }
    }

    private func reread() {
        traces = browser.history.everything(matching: query)
    }
}

/// What can be chosen: the engine, the blocker, Handoff and sync.
struct SettingsSheet: View {
    @Bindable var settings: Settings
    let browser: Browser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Search With", selection: $settings.engine) {
                        // Custom only as the Mac set it, with its address.
                        ForEach(Engine.allCases.filter { $0 != .custom || settings.engine == .custom }) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .accessibilityIdentifier("engine")
                } footer: {
                    Text("Where words that aren't an address go.")
                }
                Section {
                    Toggle("Block Ads and Trackers", isOn: $settings.blocks)
                        .accessibilityIdentifier("blocks")
                        .onChange(of: settings.blocks) { _, _ in browser.applyBlocking() }
                    if let trouble = Shield.shared.trouble {
                        Text(trouble).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Stopped before they load, as on the Mac.")
                }
                Section {
                    Toggle("Hand Off Pages to Your Other Devices", isOn: $settings.handsOff)
                        .accessibilityIdentifier("handoff")
                } footer: {
                    Text("With Handoff, the address and title of the page in front go to the devices signed in to your Apple Account, through Apple. Never a private tab. A page handed over from another device opens here whether this is on or not.")
                }
                if let sync = browser.sync {
                    Section {
                        Toggle("Sync with iCloud", isOn: Binding(get: { settings.syncs },
                                                                set: { $0 ? sync.turnOn() : sync.turnOff() }))
                            .accessibilityIdentifier("sync")
                        if settings.syncs {
                            Text(sync.summary).font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("sync-status")
                        }
                    } footer: {
                        Text("Your open tabs, bookmarks, history, search engine and blocker, on your Macs, iPhone and iPad signed in to the same Apple Account, through your own private iCloud database. Never a private tab, a password or a cookie.")
                    }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
