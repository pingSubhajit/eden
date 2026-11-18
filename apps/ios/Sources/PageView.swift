import SwiftUI
import UIKit
import WebKit

extension EnvironmentValues {
    /// How much of the page's bottom the browser's own bar covers, the page
    /// running on under it (PhoneBrowser).
    @Entry var pageCovered: CGFloat = 0
}

/// The tab's page, in a plain view that swaps web views as tabs change:
/// each tab keeps its own, with its scroll and its history, while it isn't
/// shown.
struct PageView: UIViewRepresentable {
    let tab: Tab
    @Environment(\.pageCovered) private var covered

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .systemBackground
        show(tab.webView, in: host)
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        let page = tab.webView
        if page.superview !== host { show(page, in: host) }
        // The page told what lies over it — the bar, and below it the home
        // indicator — so its end scrolls clear of it, and what it keeps at
        // the bottom is lifted above it.
        // Every page the same way, whatever covered it before: the insets
        // are these alone, never the system's guess beside them.
        page.scrollView.contentInsetAdjustmentBehavior = .never
        let obscured = UIEdgeInsets(top: 0, left: 0, bottom: covered, right: 0)
        guard page.obscuredContentInsets != obscured else { return }
        page.obscuredContentInsets = obscured
        page.scrollView.contentInset.bottom = covered
        page.scrollView.verticalScrollIndicatorInsets.bottom = covered
    }

    private func show(_ page: WKWebView, in host: UIView) {
        host.subviews.forEach { $0.removeFromSuperview() }
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            page.topAnchor.constraint(equalTo: host.topAnchor),
            page.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}
