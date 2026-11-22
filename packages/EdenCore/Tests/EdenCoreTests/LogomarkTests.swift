import EdenCore
import SwiftUI
import Testing

/// The mark fills its canvas and nothing past it, the arch is open under
/// its crown, and the gaps between its pieces stay gaps.
struct LogomarkTests {
    private let path = Logomark().path(in: CGRect(origin: .zero, size: Logomark.canvas))

    @Test func fillsItsCanvas() {
        let bounds = path.boundingRect
        #expect(abs(bounds.minX) < 0.001)
        #expect(abs(bounds.minY) < 0.001)
        #expect(abs(bounds.width - Logomark.canvas.width) < 0.001)
        #expect(abs(bounds.height - Logomark.canvas.height) < 0.001)
    }

    @Test func archIsARing() {
        // The crown of the arch, and the opening under it.
        #expect(path.contains(CGPoint(x: 182, y: 30)))
        #expect(!path.contains(CGPoint(x: 182, y: 120)))
        // Both feet, and nothing between a foot and its capital.
        #expect(path.contains(CGPoint(x: 52, y: 165)))
        #expect(path.contains(CGPoint(x: 312, y: 165)))
        #expect(!path.contains(CGPoint(x: 52, y: 170)))
    }

    @Test func columnsMirrorEachOther() {
        // A point on each piece of the left column, and the gap under it,
        // holds the same on the right.
        for (x, y, filled) in [(2.0, 180.0, true), (52, 194, false), (10, 199, true), (52, 204, false),
                               (10, 207, true), (14, 300, true), (11, 300, false), (52, 380, false),
                               (10, 385, true), (52, 390, false), (2, 400, true)] {
            #expect(path.contains(CGPoint(x: x, y: y)) == filled, "left \(x), \(y)")
            #expect(path.contains(CGPoint(x: 364 - x, y: y)) == filled, "right \(364 - x), \(y)")
        }
    }

    @Test func fitsAFrameCentred() {
        // A wide frame: the mark takes its height and sits in the middle.
        let frame = CGRect(x: 0, y: 0, width: 400, height: 103)
        let bounds = Logomark().path(in: frame).boundingRect
        #expect(abs(bounds.height - 103) < 0.001)
        #expect(abs(bounds.midX - 200) < 0.001)
    }
}
