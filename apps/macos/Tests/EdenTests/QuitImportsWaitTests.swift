import XCTest
@testable import Eden

/// Quitting waits on file imports once, five seconds in all (#67): asked
/// again while one was still there, it used to start five seconds over, and
/// an import that stayed kept Eden from ever quitting.
final class QuitImportsWaitTests: XCTestCase {
    func testTheWaitEndsFiveSecondsAfterTheFirstAttemptHoweverOftenItIsAsked() {
        var wait = Links.ImportsWait()
        let start = Date()
        XCTAssertTrue(wait.waits(importsRunning: true, now: start))
        XCTAssertEqual(wait.deadline, start.addingTimeInterval(5))
        XCTAssertTrue(wait.waits(importsRunning: true, now: start.addingTimeInterval(4)))
        XCTAssertEqual(wait.deadline, start.addingTimeInterval(5), "asked again, the same five seconds")
        XCTAssertFalse(wait.waits(importsRunning: true, now: start.addingTimeInterval(5)),
                       "past it, the quit goes ahead with the import still there")
        XCTAssertNil(wait.deadline)
    }

    func testNothingRunningQuitsAtOnceAndTheNextQuitWaitsAfresh() {
        var wait = Links.ImportsWait()
        let start = Date()
        XCTAssertFalse(wait.waits(importsRunning: false, now: start))
        XCTAssertTrue(wait.waits(importsRunning: true, now: start))
        XCTAssertFalse(wait.waits(importsRunning: false, now: start.addingTimeInterval(1)), "the imports are done")
        let later = start.addingTimeInterval(60)
        XCTAssertTrue(wait.waits(importsRunning: true, now: later))
        XCTAssertEqual(wait.deadline, later.addingTimeInterval(5))
    }
}
