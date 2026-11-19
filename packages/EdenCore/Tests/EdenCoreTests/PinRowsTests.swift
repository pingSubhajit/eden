import XCTest
@testable import EdenCore

/// How pinned squares fall into rows (PinRows), as the Mac's column has them.
final class PinRowsTests: XCTestCase {
    func testNoMoreThanFourToARowAndTheRowsEven() {
        XCTAssertEqual(PinRows.split(0, most: 4), [])
        XCTAssertEqual(PinRows.split(3, most: 4), [3])
        XCTAssertEqual(PinRows.split(4, most: 4), [4])
        XCTAssertEqual(PinRows.split(5, most: 4), [3, 2])
        XCTAssertEqual(PinRows.split(6, most: 4), [3, 3], "three and three, not four and two")
        XCTAssertEqual(PinRows.split(7, most: 4), [4, 3])
        XCTAssertEqual(PinRows.split(9, most: 4), [3, 3, 3])
    }

    func testOneShortRowKeepsThreePlaces() {
        XCTAssertEqual(PinRows.places([1], least: 3), [3])
        XCTAssertEqual(PinRows.places([2], least: 3), [3])
        XCTAssertEqual(PinRows.places([4], least: 3), [4])
        XCTAssertEqual(PinRows.places([3, 2], least: 3), [3, 2], "a short last row under another spans as it is")
    }
}
