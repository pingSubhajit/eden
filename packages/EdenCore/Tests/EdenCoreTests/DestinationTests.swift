import Foundation
import XCTest
import EdenCore

/// Where what was typed in the address field goes (Address.destination),
/// on the Mac and on iPhone and iPad alike.
final class DestinationTests: XCTestCase {
    private let google = Engine.google.template(custom: "")

    func testAnAddressGoesThere() {
        XCTAssertEqual(Address.destination(for: "example.com", engine: google)?.absoluteString, "https://example.com")
        XCTAssertEqual(Address.destination(for: "http://localhost:8080/a", engine: google)?.absoluteString,
                       "http://localhost:8080/a")
    }

    func testWordsAreSearched() throws {
        let url = try XCTUnwrap(Address.destination(for: "eden browser", engine: google))
        XCTAssertEqual(url.host(), "www.google.com")
        XCTAssertTrue(url.absoluteString.contains("eden%20browser") || url.absoluteString.contains("eden+browser"),
                      url.absoluteString)
    }

    func testASitesShortcutSearchesThatSite() throws {
        let keywords = [Keyword(keyword: "yt", template: "https://www.youtube.com/results?search_query=%s")]
        let url = try XCTUnwrap(Address.destination(for: "yt cats", engine: google, keywords: keywords))
        XCTAssertEqual(url.host(), "www.youtube.com")
        XCTAssertTrue(url.absoluteString.hasSuffix("search_query=cats"), url.absoluteString)
    }

    func testAFileOnlyWhereFilesAreAllowed() {
        XCTAssertEqual(Address.destination(for: "/etc/hosts", engine: google, files: true)?.isFileURL, true)
        XCTAssertNotEqual(Address.destination(for: "/etc/hosts", engine: google)?.isFileURL, true)
    }
}
