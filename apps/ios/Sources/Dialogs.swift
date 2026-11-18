import UIKit
import WebKit

/// A page's alert, confirm and prompt, and the question before a link opens
/// another app: the system's own alert over the page's window, titled with
/// the site that asked — a page can say anything, and shouldn't seem to
/// speak for Eden. The page always gets an answer, and only one: a button,
/// or the quiet one (OK, Cancel, nothing typed) when the alert can't be shown.
enum Dialogs {
    static func alert(_ message: String, from frame: WKFrameInfo, in page: WKWebView) async {
        await ask(page, unanswered: ()) { answer in
            let sheet = UIAlertController(title: site(frame), message: message, preferredStyle: .alert)
            sheet.addAction(UIAlertAction(title: "OK", style: .default) { _ in answer(()) })
            return sheet
        }
    }

    static func confirm(_ message: String, from frame: WKFrameInfo, in page: WKWebView) async -> Bool {
        await ask(page, unanswered: false) { answer in
            let sheet = UIAlertController(title: site(frame), message: message, preferredStyle: .alert)
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer(false) })
            sheet.addAction(UIAlertAction(title: "OK", style: .default) { _ in answer(true) })
            return sheet
        }
    }

    static func prompt(_ message: String, defaultText: String?, from frame: WKFrameInfo, in page: WKWebView) async -> String? {
        await ask(page, unanswered: nil) { answer in
            let sheet = UIAlertController(title: site(frame), message: message, preferredStyle: .alert)
            sheet.addTextField { $0.text = defaultText }
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer(nil) })
            sheet.addAction(UIAlertAction(title: "OK", style: .default) { [weak sheet] _ in
                answer(sheet?.textFields?.first?.text ?? "")
            })
            return sheet
        }
    }

    /// Before a tapped link opens another app (Tab's navigation policy):
    /// whatever its address carries goes to that app, so it is asked first,
    /// as Safari asks. No, unless you say yes.
    static func openApp(_ url: URL, from frame: WKFrameInfo, in page: WKWebView) async -> Bool {
        await ask(page, unanswered: false) { answer in
            let sheet = UIAlertController(title: site(frame),
                                          message: "This page wants to open another app (\(url.scheme ?? "")).",
                                          preferredStyle: .alert)
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer(false) })
            sheet.addAction(UIAlertAction(title: "Open", style: .default) { _ in answer(true) })
            return sheet
        }
    }

    private static func site(_ frame: WKFrameInfo) -> String {
        let host = frame.securityOrigin.host
        return host.isEmpty ? "This page" : host
    }

    /// Shows the alert `make` builds over the page's own window, and waits for
    /// its answer: the one its button gives, or `unanswered` when it can't be
    /// shown — no window, something already being dismissed, or UIKit turning
    /// the presentation down.
    private static func ask<Answer: Sendable>(_ page: WKWebView, unanswered: Answer,
                                              make: (@escaping (Answer) -> Void) -> UIAlertController) async -> Answer {
        await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
            let once = Once(continuation)
            let sheet = make { once.give($0) }
            guard var front = page.window?.rootViewController else { return once.give(unanswered) }
            while let next = front.presentedViewController, !next.isBeingDismissed { front = next }
            guard !front.isBeingDismissed, front.presentedViewController == nil else { return once.give(unanswered) }
            front.present(sheet, animated: true)
            // UIKit declines a presentation it can't make with no more than a
            // log line; the page is answered rather than left waiting.
            if sheet.presentingViewController == nil { once.give(unanswered) }
        }
    }

    /// A continuation resumed once, whoever asks first.
    private final class Once<Answer: Sendable> {
        private var continuation: CheckedContinuation<Answer, Never>?
        init(_ continuation: CheckedContinuation<Answer, Never>) { self.continuation = continuation }
        func give(_ answer: Answer) {
            continuation?.resume(returning: answer)
            continuation = nil
        }
    }
}
