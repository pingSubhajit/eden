import Foundation
import XCTest
@testable import EdenCore

/// A place forgotten from History tells the app (History.forgotten), so
/// what the app keeps for it beside the history — the Mac's icons — goes
/// too.
@MainActor
final class HistoryForgetTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "history-forget-\(getpid())", 1)
        super.setUp()
    }

    /// The world the history suites share (Store.world is fixed for the
    /// process, named by whichever ran first): gone with its settings once a
    /// suite is done, so the last to run leaves nothing.
    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("history-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.subhajit.eden.beta.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() {
        History.forgotten = nil
        super.tearDown()
    }

    func testForgettingAPlaceTellsTheApp() async throws {
        let name = "history-forget-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(at: Store.file(name)) }
        var told: [URL] = []
        History.forgotten = { told.append($0) }
        let history = History(file: name, read: { _ in nil })
        let page = try XCTUnwrap(URL(string: "https://example.com/article"))
        history.record(page, title: "Article")
        // Forgetting waits for a load still running; the empty file loads at once.
        history.forget(History.identity(for: page))
        for _ in 0..<400 where told.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(told, [page])
        XCTAssertTrue(history.everything(matching: "example.com").isEmpty)
        history.flush()
    }
}
