import CryptoKit
import Foundation
import XCTest
@testable import EdenCore

/// Pictures of pages kept for the next launch: found again by their page and
/// their website store, gone with Clear History and never brought back by a
/// picture drawn before it, and let go of once not kept for a month.
final class PagePicturesTests: XCTestCase {
    // XCTest makes a new case for each test: each has a folder of its own.
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("page-pictures-\(UUID().uuidString)", isDirectory: true)
    private lazy var pictures = PagePictures(folder: folder)

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func page(_ address: String) -> URL {
        guard let url = URL(string: address) else { preconditionFailure("not an address: \(address)") }
        return url
    }

    private func keep(_ picture: Data, for url: URL, store: UUID? = nil) async {
        pictures.keep(picture, for: url, store: store, ticket: pictures.ticket())
        await pictures.settled()
    }

    func testKeptPictureIsFoundAgainByItsPage() async {
        let url = page("https://example.com/a?b=1")
        let picture = Data([0xFF, 0xD8, 0x01, 0x02])
        XCTAssertFalse(pictures.has(url, store: nil))
        await keep(picture, for: url)
        XCTAssertTrue(pictures.has(url, store: nil))
        let found = await pictures.kept(for: url, store: nil)
        XCTAssertEqual(found, picture)
    }

    func testSamePageInAnotherSpellingSharesItsPicture() async {
        await keep(Data([1]), for: page("https://Example.com/a#section"))
        XCTAssertTrue(pictures.has(page("https://example.com/a"), store: nil))
        XCTAssertFalse(pictures.has(page("https://example.com/b"), store: nil))
    }

    func testEachWebsiteStoreKeepsItsOwnPictureOfAPage() async {
        let inbox = page("https://mail.example.com/")
        let work = UUID()
        let personal = UUID()
        await keep(Data([1]), for: inbox, store: work)
        XCTAssertTrue(pictures.has(inbox, store: work))
        XCTAssertFalse(pictures.has(inbox, store: personal))
        XCTAssertFalse(pictures.has(inbox, store: nil))
        await keep(Data([2]), for: inbox, store: personal)
        let worksOwn = await pictures.kept(for: inbox, store: work)
        XCTAssertEqual(worksOwn, Data([1]))
    }

    func testPicturesKeptBeforeStoresCountedAreNeitherReadNorKept() async throws {
        // Before, every space's picture of a page had one name, by the page
        // alone, in "cards": whose sign-in it showed can't be told.
        let unscoped = folder.appendingPathComponent("cards", isDirectory: true)
        let pictures = PagePictures(folder: folder.appendingPathComponent("page-pictures", isDirectory: true),
                                    unscoped: unscoped)
        let url = page("https://mail.example.com/")
        let name = SHA256.hash(data: Data(History.identity(for: url).utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined() + ".jpg"
        try FileManager.default.createDirectory(at: unscoped, withIntermediateDirectories: true)
        try Data([1]).write(to: unscoped.appendingPathComponent(name))

        XCTAssertFalse(pictures.has(url, store: nil))
        let found = await pictures.kept(for: url, store: nil)
        XCTAssertNil(found)
        pictures.prune()
        await pictures.settled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: unscoped.path))
    }

    func testClearHistoryTakesPicturesKeptBeforeStoresCountedToo() async throws {
        let unscoped = folder.appendingPathComponent("cards", isDirectory: true)
        let pictures = PagePictures(folder: folder.appendingPathComponent("page-pictures", isDirectory: true),
                                    unscoped: unscoped)
        try FileManager.default.createDirectory(at: unscoped, withIntermediateDirectories: true)
        try Data([1]).write(to: unscoped.appendingPathComponent("old.jpg"))
        pictures.forgetAll()
        await pictures.settled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: unscoped.path))
    }

    func testKeepingAgainReplacesThePicture() async {
        let url = page("https://example.com/")
        await keep(Data([1]), for: url)
        await keep(Data([2]), for: url)
        let found = await pictures.kept(for: url, store: nil)
        XCTAssertEqual(found, Data([2]))
    }

    func testFileNameDoesNotShowTheAddress() {
        let name = pictures.file(for: page("https://example.com/secret-page"), store: nil).lastPathComponent
        XCTAssertFalse(name.contains("example"))
        XCTAssertTrue(name.hasSuffix(".jpg"))
    }

    func testForgetAllTakesEveryPicture() async {
        let url = page("https://example.com/")
        await keep(Data([1]), for: url)
        pictures.forgetAll()
        await pictures.settled()
        XCTAssertFalse(pictures.has(url, store: nil))
    }

    func testPictureDrawnBeforeClearHistoryIsNotKeptAfterIt() async {
        let url = page("https://example.com/")
        // Drawing begins, History is cleared, and then the picture arrives.
        let ticket = pictures.ticket()
        pictures.forgetAll()
        pictures.keep(Data([1]), for: url, store: nil, ticket: ticket)
        await pictures.settled()
        XCTAssertFalse(pictures.has(url, store: nil))
        // One drawn after it is kept.
        await keep(Data([2]), for: url)
        XCTAssertTrue(pictures.has(url, store: nil))
    }

    func testPruneLetsGoOnlyOfPicturesNotKeptForAMonth() async throws {
        let old = page("https://example.com/old")
        let fresh = page("https://example.com/fresh")
        await keep(Data([1]), for: old)
        await keep(Data([2]), for: fresh)
        let longAgo = Date().addingTimeInterval(-PagePictures.lifetime - 60)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: pictures.file(for: old, store: nil).path)
        pictures.prune()
        await pictures.settled()
        XCTAssertFalse(pictures.has(old, store: nil))
        XCTAssertTrue(pictures.has(fresh, store: nil))
    }

    func testPruneKeepsAPictureKeptAgainBeforeItRuns() async throws {
        let url = page("https://example.com/")
        await keep(Data([1]), for: url)
        let longAgo = Date().addingTimeInterval(-PagePictures.lifetime - 60)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: pictures.file(for: url, store: nil).path)
        // Kept again, then pruned: in that order, so the new picture stays.
        pictures.keep(Data([2]), for: url, store: nil, ticket: pictures.ticket())
        pictures.prune()
        await pictures.settled()
        let found = await pictures.kept(for: url, store: nil)
        XCTAssertEqual(found, Data([2]))
    }
}
