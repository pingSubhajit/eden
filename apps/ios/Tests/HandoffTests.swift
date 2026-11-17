import Foundation
import Testing
@testable import Eden

/// What the iOS app takes from another device and offers back
/// (EdenApp.swift): the same rules as the Mac app's Handoff.swift.
struct HandoffTests {
    private let page = URL(string: "https://example.com/article?id=7")!

    @Test func onlyWebPagesAreTakenOrOffered() {
        #expect(Activity.web(page) == page)
        #expect(Activity.web(URL(string: "HTTP://example.com/")) != nil)
        for text in ["file:///etc/hosts", "about:blank", "eden://settings", "https:///nohost",
                     "https://someone:secret@example.com/", "https://someone@example.com/"] {
            #expect(Activity.web(URL(string: text)) == nil, "\(text)")
        }
        #expect(Activity.web(nil) == nil)
    }

    @Test func nothingIsOfferedUntilAPageIsOnScreen() {
        #expect(Offered(showing: false, address: page, title: "Article") == nil)
        #expect(Offered(showing: true, address: nil, title: "Article") == nil)
        #expect(Offered(showing: true, address: URL(string: "about:blank"), title: "") == nil)
    }

    @Test func theOfferCarriesThePageAndItsTitle() throws {
        let offered = try #require(Offered(showing: true, address: page, title: "  Article \n"))
        #expect(offered.address == page)
        #expect(offered.title == "Article")
        #expect(Offered(showing: true, address: page, title: "   ")?.title == nil)
    }

    /// A page that renames itself after it arrives, its address the same, is
    /// a different offer: SwiftUI updates the activity for it.
    @Test func aNewTitleAloneMakesANewOffer() {
        let before = Offered(showing: true, address: page, title: "")
        let after = Offered(showing: true, address: page, title: "Article")
        #expect(before != after)
        #expect(before?.address == after?.address)
    }

    @Test func theActivityTypeFollowsTheBundle() {
        #expect(Activity.browsing.hasSuffix(".browsing"))
        #expect(Activity.web == NSUserActivityTypeBrowsingWeb)
    }
}
