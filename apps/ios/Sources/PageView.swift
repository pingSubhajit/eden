import SwiftUI
import UIKit
import WebKit

/// The tab's page, in a plain view that swaps web views as tabs change:
/// each tab keeps its own, with its scroll and its history, while it isn't
/// shown.
struct PageView: UIViewRepresentable {
    let tab: Tab

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .systemBackground
        show(tab.webView, in: host)
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        let page = tab.webView
        guard page.superview !== host else { return }
        show(page, in: host)
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
