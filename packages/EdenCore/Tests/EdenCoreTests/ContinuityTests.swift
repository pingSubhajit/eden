import Foundation
import XCTest
import EdenCore

/// Which pages may go from one of your devices to another (Continuity),
/// the rule both apps take and offer pages by.
final class ContinuityTests: XCTestCase {
    func testAnOrdinaryWebPageMayGo() {
        let page = URL(string: "https://example.com/article?id=7#part")!
        XCTAssertEqual(Continuity.page(page), page)
        XCTAssertNotNil(Continuity.page(URL(string: "HTTP://example.com/")))
    }

    func testNothingButAWebPageWithAHostMayGo() {
        for text in ["file:///etc/hosts", "about:blank", "eden://settings", "javascript:alert(1)",
                     "data:text/html,hi", "https:///nohost", "mailto:someone@example.com"] {
            XCTAssertNil(Continuity.page(URL(string: text)), text)
        }
        XCTAssertNil(Continuity.page(nil))
    }

    func testAnAddressWithANameOrPasswordInItStays() {
        XCTAssertNil(Continuity.page(URL(string: "https://someone:secret@example.com/")))
        XCTAssertNil(Continuity.page(URL(string: "https://someone@example.com/")))
    }

    func testEdensActivityFollowsTheBundle() {
        XCTAssertEqual(Continuity.browsing, "com.subhajit.eden.beta.browsing")
    }
}
