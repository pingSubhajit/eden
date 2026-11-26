import AppKit

/// A test's mouse event through the app, as a real one comes: posted to its
/// queue and taken off it, so the press reads the keys held with it from the
/// event the app was handed (TabClick). Handed straight to the window, it
/// was never heard there, and read the keys held on the Mac's keyboard at
/// that moment instead: ⌘ or ⇧ held in another app while a suite ran made
/// it a ⌘- or ⇧-click (#55, #58).
@MainActor
enum AppQueue {
    /// Whether the app took `event` off its queue. Everything queued before
    /// it goes through first, however much that is: what earlier tests left
    /// there (their windows' AppKit events, forty and more by this point of
    /// a full run) ran past a count of twenty, and the press was never sent.
    /// Its kind in its window is this one: each test has a window of its
    /// own, and each event of the test's is through before the next is
    /// posted.
    static func deliver(_ event: NSEvent, in window: NSWindow) -> Bool {
        NSApp.postEvent(event, atStart: false)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            guard let queued = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.2),
                                               inMode: .default, dequeue: true) else { return false }
            NSApp.sendEvent(queued)
            if queued.type == event.type && queued.window === window { return true }
        }
        return false
    }
}
