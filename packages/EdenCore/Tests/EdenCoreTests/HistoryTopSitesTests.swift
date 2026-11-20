import Foundation
import XCTest
@testable import EdenCore

/// What an empty address field lists before anything is typed: the sites
/// gone to most, often and lately, one place a site.
@MainActor
final class HistoryTopSitesTests: XCTestCase {
    override class func setUp() {
        setenv("EDEN_PROBE", "history-top-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("history-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.subhajit.eden.beta.test.\(world)")
        }
        super.tearDown()
    }

    private func fresh() -> History {
        History(file: "history-top-\(UUID().uuidString).json")
    }

    private func page(_ address: String) -> URL {
        guard let url = URL(string: address) else { preconditionFailure("not an address: \(address)") }
        return url
    }

    /// A site comes once, as its most visited page, and a visit to a deep
    /// page counts once: it is a visit to the front page too, which is how
    /// the site is counted, never the two added together. Five reads of an
    /// article stay under eight visits to another site's front page.
    func testOneRowASiteEachVisitCountedOnce() {
        let history = fresh()
        defer { history.retire() }
        for _ in 0..<5 { history.record(page("https://deep.example/article"), title: "Article") }
        for _ in 0..<8 { history.record(page("https://home.example/"), title: "Home") }
        history.record(page("https://once.example/"), title: "Once")

        let top = history.topSites()
        XCTAssertEqual(top.map(\.url.host), ["home.example", "deep.example", "once.example"])
        XCTAssertEqual(top.count, 3, "one row a site")
    }

    /// Lately counts as well as often: a site gone to a lot months ago
    /// falls under one gone to a few times this week.
    func testLatelyOutweighsLongAgo() {
        let history = fresh()
        defer { history.retire() }
        let now = Date()
        history.take(page("https://old.example/"), title: "Old", count: 10, last: now.addingTimeInterval(-120 * 86_400))
        history.take(page("https://new.example/"), title: "New", count: 3, last: now)

        XCTAssertEqual(history.topSites().map(\.title), ["New", "Old"])
    }

    /// No more than asked for, and a visit since changes the answer.
    func testLimitAndAVisitSince() {
        let history = fresh()
        defer { history.retire() }
        let now = Date()
        for i in 0..<8 {
            history.take(page("https://site\(i).example/"), title: "Site \(i)", count: 8 - i, last: now)
        }
        XCTAssertEqual(history.topSites(limit: 3).map(\.title), ["Site 0", "Site 1", "Site 2"])

        for _ in 0..<12 { history.record(page("https://site7.example/"), title: "Site 7") }
        XCTAssertEqual(history.topSites(limit: 1).map(\.title), ["Site 7"])
    }
}
