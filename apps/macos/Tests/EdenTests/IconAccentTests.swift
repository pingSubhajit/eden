import AppKit
import XCTest
@testable import Eden

/// A site icon's own colour (IconAccent), for a pinned tab's glow.
@MainActor
final class IconAccentTests: XCTestCase {
    /// An icon of coloured squares, each this share of it.
    private func icon(_ parts: [(NSColor, CGFloat)]) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            var x: CGFloat = 0
            for (colour, share) in parts {
                colour.setFill()
                NSRect(x: x, y: 0, width: rect.width * share, height: rect.height).fill()
                x += rect.width * share
            }
            return true
        }
    }

    private func hue(_ colour: NSColor?) -> CGFloat? {
        colour?.usingColorSpace(.sRGB).map { $0.hueComponent * 360 }
    }

    func testAOneColourIconIsThatColour() throws {
        let red = try XCTUnwrap(hue(IconAccent.of(icon([(.systemRed, 1)]))))
        XCTAssertTrue(red < 15 || red > 345, "red, not \(red)")
    }

    func testTheHueMostOfItSharesNotTheirAverage() throws {
        // Gmail-like: mostly red with blue, green and yellow; averaged, brown.
        let found = try XCTUnwrap(hue(IconAccent.of(icon([(.systemRed, 0.55), (.systemBlue, 0.15),
                                                            (.systemGreen, 0.15), (.systemYellow, 0.15)]))))
        XCTAssertTrue(found < 15 || found > 345, "red, not \(found)")
    }

    func testAGreyIconHasNone() {
        XCTAssertNil(IconAccent.of(icon([(.black, 0.5), (.white, 0.5)])))
        XCTAssertNil(IconAccent.of(icon([(.darkGray, 0.97), (.systemRed, 0.03)])), "a speck of colour isn't its colour")
    }
}
