import EdenCore
import SwiftUI

/// A tab with nowhere to be yet: your bookmarks and where you went last, to
/// go back to in a tap. A private tab says what it keeps, which is nothing.
struct StartPage: View {
    let browser: Browser
    let tab: Tab?
    /// Watched, so a visit recorded, or the history arriving from disk,
    /// shows in Recently Visited.
    @ObservedObject private var history: History

    init(browser: Browser, tab: Tab?) {
        self.browser = browser
        self.tab = tab
        _history = ObservedObject(wrappedValue: browser.history)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Spacer()
                    Logomark()
                        .fill(.primary)
                        .aspectRatio(Logomark.canvas.width / Logomark.canvas.height, contentMode: .fit)
                        .frame(height: 40)
                        .accessibilityLabel("Eden")
                    Spacer()
                }
                .padding(.top, 40)

                if tab?.isPrivate == true {
                    Label("A private tab keeps no history and its own cookies, gone when it closes.",
                          systemImage: "eye.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("private-note")
                }

                // Carrying on from your other devices: the page in front on the
                // one just put down, and pages closed there a moment ago.
                if tab?.isPrivate != true {
                    let now = Date().timeIntervalSince1970
                    if let carry = Elsewhere.continuing(from: browser.elsewhere, now: now, frontHere: nil) {
                        continuing(carry)
                    }
                    let closed = Elsewhere.closed(on: browser.elsewhere, now: now, openHere: browser.openHere)
                    if !closed.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recently Closed on Your Other Devices").displayFont(26)
                            ForEach(Array(closed.enumerated()), id: \.offset) { _, offer in
                                Button { browser.open(offer, in: tab) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: offer.kind.symbol)
                                            .frame(width: 34, height: 34)
                                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(offer.page.shownTitle).lineLimit(1)
                                            Text("Closed on \(offer.deviceName)").font(.footnote).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("closed-elsewhere")
                            }
                        }
                    }
                }

                // The space's pins, a tap away; never in a private tab.
                if tab?.isPrivate != true, !browser.shownPins.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pins").displayFont(26)
                        PinStrip(browser: browser, container: "start")
                    }
                }

                if !browser.bookmarks.items.isEmpty {
                    section("Bookmarks", sites: browser.bookmarks.items.compactMap { mark in
                        mark.address.map { (mark.title, $0) }
                    })
                }

                let recent = tab?.isPrivate == true ? [] : history.recent().prefix(6).map { ($0.title, $0.url) }
                if !recent.isEmpty { section("Recently Visited", sites: Array(recent)) }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color(.systemBackground))
    }

    /// The page in front on the device just put down, to carry on with here.
    private func continuing(_ offer: Elsewhere.Offer) -> some View {
        Button { browser.open(offer, in: tab) } label: {
            HStack(spacing: 14) {
                Image(systemName: offer.kind.symbol).font(.title2).foregroundStyle(.tint).frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Continue from \(offer.deviceName)").font(.footnote).foregroundStyle(.secondary)
                    Text(offer.page.shownTitle).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                    if let scroll = offer.page.scroll, scroll > 0 {
                        Text("\(Int((scroll * 100).rounded()))% read").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right.circle.fill").font(.title2).foregroundStyle(.tint)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("continue-elsewhere")
    }

    private func section(_ title: String, sites: [(String, URL)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).displayFont(26)
            ForEach(Array(sites.enumerated()), id: \.offset) { _, site in
                Button {
                    if let tab { tab.load(site.1); browser.select(tab) } else { browser.newTab(url: site.1) }
                } label: {
                    HStack(spacing: 12) {
                        Text(String((site.1.host().map(Address.withoutWWW) ?? "?").prefix(1)).uppercased())
                            .font(.headline)
                            .frame(width: 34, height: 34)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.0.isEmpty ? Address.pretty(site.1) : site.0).lineLimit(1)
                            Text(Address.pretty(site.1)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
