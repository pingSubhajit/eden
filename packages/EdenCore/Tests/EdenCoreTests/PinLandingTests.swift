import XCTest
@testable import EdenCore

/// Where a pin's trip home comes to rest (PinLanding): wherever the page goes
/// by itself after reaching home is home, and where it goes once touched is
/// not.
final class PinLandingTests: XCTestCase {
    private let home = URL(string: "https://mail.example.com")
    private let step = URL(string: "https://mail.example.com/u/0")
    private let inbox = URL(string: "https://mail.example.com/u/0/#inbox")
    private let letter = URL(string: "https://mail.example.com/u/0/#inbox/1")

    private func url(_ url: URL?) throws -> URL { try XCTUnwrap(url) }

    func testWhereTheHomeSendsItIsHome() throws {
        var landing = PinLanding()
        landing.moved(to: try url(home), home: home)
        landing.moved(to: try url(inbox), home: home)
        XCTAssertTrue(landing.atHome(home, showing: inbox))
        XCTAssertFalse(landing.atHome(home, showing: letter))
    }

    func testAChainOfPagesTheHomeGoesThroughEndsAtHome() throws {
        var landing = PinLanding()
        landing.moved(to: try url(home), home: home)
        landing.moved(to: try url(step), home: home)
        landing.moved(to: try url(inbox), home: home)
        XCTAssertEqual(landing.landed, inbox, "however long the chain takes")
        XCTAssertTrue(landing.atHome(home, showing: inbox))
    }

    func testOnceTouchedWhereItGoesIsYours() throws {
        var landing = PinLanding()
        landing.moved(to: try url(home), home: home)
        landing.moved(to: try url(inbox), home: home)
        landing.touched()
        landing.moved(to: try url(letter), home: home)
        XCTAssertFalse(landing.atHome(home, showing: letter), "a link followed however soon")
        XCTAssertTrue(landing.atHome(home, showing: inbox), "back at the landing is home again")
    }

    func testTheNextTripHomeForgetsTheLastLanding() throws {
        var landing = PinLanding()
        landing.moved(to: try url(home), home: home)
        landing.moved(to: try url(inbox), home: home)
        landing.touched()
        landing.moved(to: try url(home), home: home)
        XCTAssertNil(landing.landed)
        XCTAssertTrue(landing.atHome(home, showing: home))
        landing.moved(to: try url(step), home: home)
        XCTAssertEqual(landing.landed, step, "a trip of its own, not touched yet")
    }

    func testPinnedWhileOnItsWayHomeLandsThere() throws {
        // Pinned, or its home replaced, while the page it shows still loads.
        var landing = PinLanding(home: home, showing: home)
        landing.moved(to: try url(inbox), home: home)
        XCTAssertTrue(landing.atHome(home, showing: inbox))
        XCTAssertFalse(PinLanding(home: home, showing: letter).atHome(home, showing: inbox),
                       "given a home it isn't at, it has no trip under way")
    }

    func testNoHomeIsNeverHome() throws {
        var landing = PinLanding()
        landing.moved(to: try url(home), home: nil)
        XCTAssertFalse(landing.atHome(nil, showing: home))
        XCTAssertFalse(landing.atHome(home, showing: nil))
    }
}
