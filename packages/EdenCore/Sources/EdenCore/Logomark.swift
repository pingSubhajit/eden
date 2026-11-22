import SwiftUI

/// Eden's mark: an arch on two columns, on its own 364 × 412 canvas, drawn
/// from its measurements rather than loaded from a file so it stays a crisp
/// vector at any size. The same shape as brand/logomark.svg, and as the
/// mark in brand/AppIcon.icon; a change to one is a change to all three.
///
/// Every piece stands apart from the others, so it fills the same either
/// way, and it is drawn bare, with nothing behind it, wherever it appears.
public struct Logomark: Shape {
    /// The mark's own canvas, nothing outside it.
    public static let canvas = CGSize(width: 364, height: 412)

    public init() {}

    public func path(in rect: CGRect) -> Path {
        // Fit the canvas into whatever frame this is given, centred, at the
        // larger scale that still keeps it inside: an SVG viewBox's "meet".
        let scale = min(rect.width / Self.canvas.width, rect.height / Self.canvas.height)
        let x = rect.midX - Self.canvas.width * scale / 2
        let y = rect.midY - Self.canvas.height * scale / 2
        return Self.drawn.applying(CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale))
    }

    /// The mark on its canvas, drawn once.
    private static let drawn: Path = {
        var path = Path()
        // The arch: a half ring centred between the columns, its outer edge
        // 162 from the centre and its inner 98, with a short straight foot on
        // each side so it stands 4 above the capitals, as every gap is.
        let centre = CGPoint(x: 182, y: 162)
        path.move(to: CGPoint(x: 20, y: 168))
        path.addLine(to: CGPoint(x: 20, y: 162))
        path.addArc(center: centre, radius: 162, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        path.addLine(to: CGPoint(x: 344, y: 168))
        path.addLine(to: CGPoint(x: 280, y: 168))
        path.addLine(to: CGPoint(x: 280, y: 162))
        path.addArc(center: centre, radius: 98, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: CGPoint(x: 84, y: 168))
        path.closeSubpath()
        // The columns, each centred under a foot of the arch.
        for left in [CGFloat(0), 260] {
            column(at: left, in: &path)
        }
        return path
    }()

    /// A column 104 wide from `left`: a slab and a band for its capital, a
    /// shaft that narrows under them, then a band and a slab for its base.
    private static func column(at left: CGFloat, in path: inout Path) {
        path.addRect(CGRect(x: left, y: 172, width: 104, height: 20))
        path.addRect(CGRect(x: left + 7, y: 196, width: 90, height: 6))
        path.addLines([
            CGPoint(x: left + 7, y: 206),
            CGPoint(x: left + 97, y: 206),
            CGPoint(x: left + 91, y: 218),
            CGPoint(x: left + 91, y: 378),
            CGPoint(x: left + 13, y: 378),
            CGPoint(x: left + 13, y: 218),
        ])
        path.closeSubpath()
        path.addRect(CGRect(x: left + 7, y: 382, width: 90, height: 6))
        path.addRect(CGRect(x: left, y: 392, width: 104, height: 20))
    }
}
