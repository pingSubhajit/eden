import AppKit
import XCTest
@testable import Eden

/// Quitting waits on file imports once, five seconds at most (#67), inside
/// the one answer to the quit (#69): no more than that, however long the
/// import goes on, and no longer than the import takes.
@MainActor
final class QuitImportsWaitTests: XCTestCase {
    func testTheWaitEndsAtItsMostWhateverTheImportIsDoing() async {
        let start = Date()
        await Links.wait(while: true, atMost: 0.3)
        let waited = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(waited, 0.3)
        XCTAssertLessThan(waited, 1, "not past it")
    }

    func testTheWaitEndsAsTheImportDoes() async {
        let start = Date()
        let done = start.addingTimeInterval(0.2)
        await Links.wait(while: Date() < done, atMost: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "not the five seconds")
        await Links.wait(while: false, atMost: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "nothing running, no wait")
    }

    /// While a quit waits to be answered, AppKit runs the app in its modal
    /// panel mode: the import's own end, the wait and the writes before
    /// going are main-actor work, and go on in it.
    func testMainActorWorkGoesOnWhileAQuitIsAnswered() {
        _ = NSApplication.shared
        var ran = false
        Task { @MainActor in ran = true }
        let until = Date().addingTimeInterval(2)
        while !ran, Date() < until {
            _ = RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(ran)
    }
}
