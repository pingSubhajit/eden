import SwiftUI

/// Eden's mark: a pill with an E cut out of it, on its own 608 × 276 canvas.
/// The same shape as the Mac app's `Logomark` (apps/macos/Sources/Eden/Design.swift)
/// and its icon; it moves into the shared core with Phase 2.
nonisolated struct Logomark: Shape {
    static let canvas = CGSize(width: 608, height: 276)

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.canvas.width, rect.height / Self.canvas.height)
        let origin = CGPoint(x: rect.midX - Self.canvas.width * scale / 2,
                             y: rect.midY - Self.canvas.height * scale / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        var path = Path()
        // The pill: the canvas, with ends as round as it is tall.
        path.addRoundedRect(in: CGRect(origin: origin, size: CGSize(width: Self.canvas.width * scale, height: 275.321 * scale)),
                            cornerSize: CGSize(width: 137.66 * scale, height: 137.66 * scale))
        // The E, filled even-odd so it is a hole.
        let e: [(CGFloat, CGFloat)] = [(86, 54), (190, 54), (190, 76), (110, 76), (110, 126), (180, 126),
                                       (180, 148), (110, 148), (110, 197), (192, 197), (192, 219), (86, 219)]
        path.move(to: point(e[0].0, e[0].1))
        for corner in e.dropFirst() { path.addLine(to: point(corner.0, corner.1)) }
        path.closeSubpath()
        return path
    }
}
