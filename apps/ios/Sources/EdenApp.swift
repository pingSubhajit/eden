import SwiftUI
import WebKit

// Eden for iPhone and iPad. Phase 0: the app exists, signs as Techaboard's,
// carries the iCloud container and takes a page handed off to it. The
// browser itself comes in Phase 3, on the core it will share with the Mac
// (packages/).

@main
struct EdenApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The two kinds of page another device can hand over: the system's own,
/// from Safari or any browser, and Eden's, from Eden on the Mac.
enum Activity {
    static let web = NSUserActivityTypeBrowsingWeb
    /// From Info.plist (EDEN_ACTIVITY_BROWSING in Base.xcconfig), so it follows
    /// the bundle id.
    static let browsing = Bundle.main.object(forInfoDictionaryKey: "EdenActivityBrowsing") as? String
        ?? "com.subhajit.eden.beta.browsing"
}

struct RootView: View {
    /// The page handed over, shown as it is until there is a browser here.
    @State private var page: URL?

    var body: some View {
        Group {
            if let page {
                WebView(url: page)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                Welcome()
            }
        }
        .onContinueUserActivity(Activity.web, perform: take)
        .onContinueUserActivity(Activity.browsing, perform: take)
    }

    private func take(_ activity: NSUserActivity) {
        guard let url = activity.webpageURL, ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        page = url
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
