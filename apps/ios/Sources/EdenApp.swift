import EdenCore
import SwiftUI
import WebKit

// Eden for iPhone and iPad. Phases 0 and 1: the app exists, signs as
// Techaboard's, carries the iCloud container, takes a page handed off to it
// and offers that page back. The browser itself comes in Phase 3, on the
// core it will share with the Mac (packages/).

@main
struct EdenApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The two kinds of page another device can hand over: the system's own,
/// from Safari or any browser, and Eden's, from Eden on the Mac. The Mac app
/// (apps/macos/Sources/Eden/Handoff.swift) uses the same two, and the same
/// rule for which pages may go (Continuity, in EdenCore).
enum Activity {
    static let web = NSUserActivityTypeBrowsingWeb
    /// From Info.plist (EDEN_ACTIVITY_BROWSING in Base.xcconfig), so it follows
    /// the bundle id.
    static let browsing = Bundle.main.object(forInfoDictionaryKey: "EdenActivityBrowsing") as? String
        ?? Continuity.browsing

    /// The page, when it may be taken or offered at all: the rule the Mac
    /// app uses too (Continuity, in EdenCore).
    static func web(_ address: URL?) -> URL? { Continuity.page(address) }
}

/// What the app offers your other devices: the page on screen, when it is a
/// page of the web, and its title, or nothing. A value, so SwiftUI updates
/// the activity whenever either part changes.
struct Offered: Hashable {
    let address: URL
    let title: String?

    init?(showing: Bool, address: URL?, title: String) {
        guard showing, let address = Activity.web(address) else { return nil }
        self.address = address
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? nil : trimmed
    }
}

struct RootView: View {
    /// The page handed over, shown as it is until there is a browser here.
    @State private var page = WebPage()
    @State private var showing = false

    var body: some View {
        Group {
            if showing {
                WebView(page)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                Welcome()
            }
        }
        .onContinueUserActivity(Activity.web, perform: take)
        .onContinueUserActivity(Activity.browsing, perform: take)
        // The page on screen, offered back to your other devices as Eden's own
        // activity, so it can go on on the Mac. Only a page you were handed
        // is ever on screen here; the switch the Mac has for offering comes
        // with the browser (Phase 3). Its address and title are read here in
        // body, so a page that renames itself after it arrives, with no new
        // address, still updates the offer; read only in the closure, the
        // title went unobserved.
        .userActivity(Activity.browsing, element: offered) { offered, activity in
            activity.webpageURL = offered.address
            activity.title = offered.title
            activity.isEligibleForHandoff = true
            activity.isEligibleForSearch = false
            activity.isEligibleForPublicIndexing = false
        }
    }

    private var offered: Offered? { Offered(showing: showing, address: page.url, title: page.title) }

    private func take(_ activity: NSUserActivity) {
        guard let url = Activity.web(activity.webpageURL) else { return }
        page.load(URLRequest(url: url))
        showing = true
    }
}

private struct Welcome: View {
    var body: some View {
        VStack(spacing: 18) {
            Logomark()
                .fill(.primary, style: FillStyle(eoFill: true))
                .aspectRatio(Logomark.canvas.width / Logomark.canvas.height, contentMode: .fit)
                .frame(height: 44)
            Text("Eden")
                .font(.title2.weight(.semibold))
            Text("For iPhone and iPad, soon.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
