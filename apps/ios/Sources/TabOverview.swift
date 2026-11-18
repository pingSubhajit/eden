import EdenCore
import SwiftUI

/// Every tab, as cards, ordinary and private apart: pick one, close one, or
/// open another. iPhone's way to see its tabs; iPad has its sidebar.
struct TabOverview: View {
    let browser: Browser
    @Binding var showingPrivate: Bool
    let done: () -> Void

    private var shown: [Tab] { showingPrivate ? browser.privateTabs : browser.ordinaryTabs }
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if shown.isEmpty {
                    ContentUnavailableView(showingPrivate ? "No Private Tabs" : "No Tabs",
                                           systemImage: showingPrivate ? "eye.slash" : "square.on.square",
                                           description: Text("Open one with the + button."))
                        .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(shown) { tab in card(tab) }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(showingPrivate ? "Private" : "Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Kind", selection: $showingPrivate) {
                        Text("Tabs").tag(false)
                        Text("Private").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .accessibilityIdentifier("tab-kind")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("New Tab", systemImage: "plus") {
                        browser.newTab(private: showingPrivate)
                        done()
                    }
                    .accessibilityIdentifier("new-tab")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done).accessibilityIdentifier("tabs-done")
                }
            }
        }
    }

    private func card(_ tab: Tab) -> some View {
        let active = tab.id == browser.activeID
        return Button {
            browser.select(tab)
            done()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tab.title.isEmpty ? (tab.url.map(Address.pretty) ?? "New Tab") : tab.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                Text(tab.url?.host().map(Address.withoutWWW) ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(height: 120)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(active ? Color.accentColor : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab-card")
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark.circle.fill") { browser.close(tab) }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(6)
                .accessibilityIdentifier("close-tab")
        }
    }
}
