import SwiftUI
import UIKit
import WebKit

extension EnvironmentValues {
    /// How much of the page's bottom the browser's own bar covers, the page
    /// running on under it (PhoneBrowser).
    @Entry var pageCovered: CGFloat = 0
    /// How much of its top the status bar covers, the page running on up
    /// under it as in Safari (PhoneBrowser). None where the page starts below
    /// a bar of the browser's own (PadBrowser).
    @Entry var pageTop: CGFloat = 0
    /// Told which way a finger is moving the page, so the bar can shrink out
    /// of the way as it is read (PhoneBrowser). Nothing is told by default.
    @Entry var barTuck: BarTuck?
}

/// Which way the page is being moved: on down it, or back up it (or right to
/// its top, where the bar always shows in full).
enum PageScroll {
    case down, up
}

/// The tab's page, in a plain view that swaps web views as tabs change:
/// each tab keeps its own, with its scroll and its history, while it isn't
/// shown.
struct PageView: UIViewRepresentable {
    let tab: Tab
    @Environment(\.pageCovered) private var covered
    @Environment(\.pageTop) private var top
    @Environment(\.barTuck) private var tuck

    func makeCoordinator() -> ScrollFollower { ScrollFollower() }

    func makeUIView(context: Context) -> PageHost {
        let host = PageHost()
        host.show(tab.webView)
        context.coordinator.follow(tab.webView.scrollView)
        return host
    }

    func updateUIView(_ host: PageHost, context: Context) {
        context.coordinator.tuck = tuck
        let page = tab.webView
        if page.superview !== host {
            host.show(page)
            context.coordinator.follow(page.scrollView)
        }
        host.edges(top: top, bottom: covered)
        // The page told what lies over it — the status bar above, the bar
        // and the home indicator below — so it starts clear of the one and
        // ends clear of the other, scrolling on under both, and what it
        // keeps fixed at its top or bottom is kept out from under them.
        // Every page the same way, whatever covered it before: the insets
        // are these alone, never the system's guess beside them.
        let scroll = page.scrollView
        scroll.contentInsetAdjustmentBehavior = .never
        let obscured = UIEdgeInsets(top: top, left: 0, bottom: covered, right: 0)
        guard page.obscuredContentInsets != obscured else { return }
        // A page at its top stays at its top, now further down.
        let atTop = scroll.contentOffset.y <= -scroll.contentInset.top
        page.obscuredContentInsets = obscured
        scroll.contentInset.top = top
        scroll.contentInset.bottom = covered
        scroll.verticalScrollIndicatorInsets.top = top
        scroll.verticalScrollIndicatorInsets.bottom = covered
        if atTop { scroll.contentOffset.y = -top }
    }
}

/// Holds the page shown, with a strip over each of its edges where
/// something lies over it: the system blurs the page softly under each, as
/// under Safari's status bar and toolbar, so what lies there stays legible
/// on any page.
final class PageHost: UIView {
    private let topStrip = UIView()
    private let bottomStrip = UIView()
    private let topEdge = UIScrollEdgeElementContainerInteraction()
    private let bottomEdge = UIScrollEdgeElementContainerInteraction()
    private var topHeight: NSLayoutConstraint?
    private var bottomHeight: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        topEdge.edge = .top
        bottomEdge.edge = .bottom
        for (strip, edge) in [(topStrip, topEdge), (bottomStrip, bottomEdge)] {
            // Only says where the edges are: every touch goes to the page.
            strip.isUserInteractionEnabled = false
            strip.translatesAutoresizingMaskIntoConstraints = false
            strip.addInteraction(edge)
            addSubview(strip)
        }
        let topHeight = topStrip.heightAnchor.constraint(equalToConstant: 0)
        let bottomHeight = bottomStrip.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            topStrip.topAnchor.constraint(equalTo: topAnchor),
            topStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            topStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            topHeight,
            bottomStrip.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomHeight,
        ])
        self.topHeight = topHeight
        self.bottomHeight = bottomHeight
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `page` in place of the one shown, under the strips.
    func show(_ page: WKWebView) {
        subviews.filter { $0 is WKWebView }.forEach { $0.removeFromSuperview() }
        page.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(page, at: 0)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.topAnchor.constraint(equalTo: topAnchor),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        topEdge.scrollView = page.scrollView
        bottomEdge.scrollView = page.scrollView
    }

    /// How much lies over the page at its top and its bottom.
    func edges(top: CGFloat, bottom: CGFloat) {
        if topHeight?.constant != top { topHeight?.constant = top }
        if bottomHeight?.constant != bottom { bottomHeight?.constant = bottom }
    }
}

/// Watches the page shown being scrolled by a finger, and says which way
/// once it has gone far enough that way to mean it.
@MainActor
final class ScrollFollower {
    weak var tuck: BarTuck?
    private var watching: NSKeyValueObservation?
    private var last: CGFloat = 0
    /// How far the page has gone the same way since it last turned.
    private var run: CGFloat = 0

    /// Down needs less than up: the bar goes as soon as reading starts, and
    /// comes back only for a real look back — more than the page shifts as
    /// the bar's own size changes what it covers.
    private static let down: CGFloat = 16
    private static let up: CGFloat = 44

    func follow(_ scroll: UIScrollView) {
        last = scroll.contentOffset.y
        run = 0
        watching = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
            MainActor.assumeIsolated { self?.moved(scroll) }
        }
    }

    private func moved(_ scroll: UIScrollView) {
        let y = scroll.contentOffset.y
        let step = y - last
        last = y
        // Only a finger's scrolling, and the fling after it: a page jumping
        // to an anchor, or put back where it was read, leaves the bar be.
        guard scroll.isDragging || scroll.isDecelerating else { return }
        if y <= -scroll.adjustedContentInset.top + 1 {
            run = 0
            tuck?.scrolled(.up)
            return
        }
        // Turning back starts the count again.
        if step != 0, (step > 0) != (run > 0) { run = 0 }
        run += step
        if run > Self.down {
            run = 0
            tuck?.scrolled(.down)
        } else if run < -Self.up {
            run = 0
            tuck?.scrolled(.up)
        }
    }
}
