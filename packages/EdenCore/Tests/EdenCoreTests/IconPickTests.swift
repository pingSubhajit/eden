import CoreGraphics
import XCTest
@testable import EdenCore

/// A site's icon as iPhone and iPad find it (IconPick): which site an
/// address is, which declared icon is tried first, and the colour an icon
/// wears.
final class IconPickTests: XCTestCase {
    private let page = URL(string: "https://example.com/a/b")!

    private func icon(_ href: String, rel: String = "icon", sizes: String = "", type: String = "",
                      media: String = "") -> [String: String] {
        ["href": href, "rel": rel, "sizes": sizes, "type": type, "media": media]
    }

    func testASiteIsItsHostAndAnyPortOfItsOwn() {
        XCTAssertEqual(IconPick.site(URL(string: "https://Example.com/x")!), "example.com")
        XCTAssertEqual(IconPick.site(URL(string: "http://localhost:3000/")!), "localhost:3000")
        XCTAssertEqual(IconPick.site(URL(string: "https://example.com:443/")!), "example.com")
        XCTAssertNil(IconPick.site(URL(string: "file:///tmp/a.html")!))
    }

    func testACrispIconComesBeforeATinyOneAndTheTouchIcon() {
        let ranked = IconPick.rank([
            icon("/tiny.png", sizes: "16x16"),
            icon("/touch.png", rel: "apple-touch-icon"),
            icon("/crisp.png", sizes: "32x32"),
        ], page: page, dark: false)
        XCTAssertEqual(ranked.map(\.path), ["/crisp.png", "/touch.png", "/tiny.png", "/favicon.ico"])
    }

    func testWhatCannotBeDrawnFromItsBytesIsPassedOver() {
        let ranked = IconPick.rank([
            icon("/mark.svg"),
            icon("/any.png", sizes: "any"),
            icon("/vector", type: "image/svg+xml"),
            icon("data:image/png;base64,AAAA"),
        ], page: page, dark: false)
        XCTAssertEqual(ranked.map(\.absoluteString), ["https://example.com/favicon.ico"])
    }

    func testTheIconForThisAppearanceComesFirstAndTheOtherNever() {
        let declared = [
            icon("/plain.png", sizes: "32x32"),
            icon("/light.png", media: "(prefers-color-scheme: light)"),
            icon("/dark.png", media: "(prefers-color-scheme: dark)"),
        ]
        XCTAssertEqual(IconPick.rank(declared, page: page, dark: true).map(\.path), ["/dark.png", "/plain.png", "/favicon.ico"])
        XCTAssertEqual(IconPick.rank(declared, page: page, dark: false).map(\.path), ["/light.png", "/plain.png", "/favicon.ico"])
    }

    func testTheSameIconTwiceIsAskedForOnce() {
        let ranked = IconPick.rank([icon("/favicon.ico"), icon("https://example.com/favicon.ico")], page: page, dark: false)
        XCTAssertEqual(ranked.map(\.absoluteString), ["https://example.com/favicon.ico"])
    }

    func testASiteNeverSeenIsGuessedAtItsRoot() {
        XCTAssertEqual(IconPick.guesses(for: page).map(\.absoluteString),
                       ["https://example.com/apple-touch-icon.png", "https://example.com/favicon.ico"])
        XCTAssertEqual(IconPick.guesses(for: URL(string: "about:blank")!), [])
    }

    /// An image of coloured bands, each this share of it, top to bottom.
    private func image(_ parts: [((Double, Double, Double), Double)]) throws -> CGImage {
        let side = 48
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var y = 0.0
        for ((r, g, b), share) in parts {
            context.setFillColor(red: r, green: g, blue: b, alpha: 1)
            context.fill(CGRect(x: 0, y: y, width: Double(side), height: Double(side) * share))
            y += Double(side) * share
        }
        return try XCTUnwrap(context.makeImage())
    }

    func testTheColourIsTheHueMostOfItSharesNotTheirAverage() throws {
        // Gmail-like: mostly red with blue, green and yellow; averaged, brown.
        let gmail = try image([((0.9, 0.2, 0.15), 0.55), ((0.2, 0.4, 0.95), 0.15),
                               ((0.2, 0.7, 0.3), 0.15), ((0.95, 0.75, 0.1), 0.15)])
        let found = try XCTUnwrap(IconPick.accent(of: gmail))
        XCTAssertGreaterThan(found.red, 0.7)
        XCTAssertLessThan(found.green, 0.35)
    }

    func testAGreyIconHasNoColour() throws {
        XCTAssertNil(IconPick.accent(of: try image([((0, 0, 0), 0.5), ((1, 1, 1), 0.5)])))
        XCTAssertNil(IconPick.accent(of: try image([((0.3, 0.3, 0.3), 0.97), ((0.9, 0.1, 0.1), 0.03)])),
                     "a speck of colour isn't its colour")
    }
}
