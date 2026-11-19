import XCTest
@testable import Eden

/// Which way a long title fades (Design.swift, fadesOut): from its first
/// letter, so a Hebrew or Arabic one keeps its beginning.
final class FadeOutTests: XCTestCase {
    func testWhichWayATitleReads() {
        XCTAssertFalse("The Conjuring (2013)".readsRightToLeft)
        XCTAssertTrue("ויקיפדיה, האנציקלופדיה החופשית".readsRightToLeft)
        XCTAssertTrue("ويكيبيديا، الموسوعة الحرة".readsRightToLeft)
        XCTAssertTrue("(2024) ويكيبيديا".readsRightToLeft, "from the first letter, past digits and marks")
        XCTAssertFalse("YouTube — يوتيوب".readsRightToLeft)
        XCTAssertFalse("".readsRightToLeft)
        XCTAssertFalse("2024".readsRightToLeft)
    }
}
