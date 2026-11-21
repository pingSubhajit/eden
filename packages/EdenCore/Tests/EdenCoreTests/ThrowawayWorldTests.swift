import XCTest
@testable import EdenCore

/// Which names a test run's sweep may take away (Store.ended, #7): only a
/// throwaway world's whose process, that pid started at that moment, is gone.
final class ThrowawayWorldTests: XCTestCase {
    func testAWorldIsEndedOnlyOnceItsOwnProcessIsGone() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let pid = sleeper.processIdentifier
        guard case .running(let start) = Store.process(pid) else { return XCTFail("its process is running") }
        XCTAssertFalse(Store.ended("field-offers-\(pid).\(start)"), "its process is running")
        XCTAssertTrue(Store.ended("field-offers-\(pid).\(start - 1)"),
                      "the pid came round to another process: the world's own is gone")
        sleeper.terminate()
        sleeper.waitUntilExit()
        XCTAssertEqual(Store.process(pid), .gone)
        XCTAssertTrue(Store.ended("field-offers-\(pid).\(start)"))
    }

    func testNothingButAThrowawayWorldsNameIsEverEnded() {
        let mine = ProcessInfo.processInfo.processIdentifier
        guard case .running(let myStart) = Store.process(mine) else { return XCTFail("this process is running") }
        for name in ["", "test", "split-tests-5a84b50d", "field-offers-123", "field-offers-123456.1",
                     "field-offers-12.", "field-offers-.123", "import-tests-9aa77393-4719", "little-default-12.abc",
                     "field-offers-\(mine).\(myStart)"] {
            XCTAssertFalse(Store.ended(name), name)
        }
    }
}
