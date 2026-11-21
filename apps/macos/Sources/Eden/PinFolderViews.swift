import SwiftUI

// What a kept group draws of its own (see Column.swift). Its heading,
// surface, fold and menu are any group's (GroupLook.swift, GroupHeading);
// until an icon is chosen it shows a folder whose front tilts open as the
// group unfolds, and closes as it folds, as Arc's pinned folders do.

/// A folder's icon until one is chosen: its back, and its front, which
/// tilts open on the fold's spring while the folder is open. In the
/// folder's ink, the back a shade lighter, so the open front reads against
/// it at a tab's icon size.
struct PinFolderIcon: View {
    let open: Bool
    let ink: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            FolderBack()
                .fill(ink.opacity(0.45))
            FolderFront(open: open ? 1 : 0)
                .fill(ink)
        }
        .frame(width: size * 0.9, height: size * 0.9)
        .frame(width: size, height: size)
        // On the fold's spring however it was folded, here, from the menu
        // or in another window; at once with Reduce Motion, where the fold
        // has none (GroupLook.fold).
        .animation(GroupLook.fold, value: open)
        .accessibilityHidden(true)
    }
}

/// The folder's back, its tab at the top left: a unit square's drawing,
/// scaled to the frame.
private struct FolderBack: Shape {
    func path(in rect: CGRect) -> Path {
        let corners = [
            CGPoint(x: 0, y: 0.1), CGPoint(x: 0.38, y: 0.1), CGPoint(x: 0.47, y: 0.2),
            CGPoint(x: 1, y: 0.2), CGPoint(x: 1, y: 0.9), CGPoint(x: 0, y: 0.9),
        ]
        return Path.rounded(corners.map { rect.unit($0) }, radius: rect.width * 0.08)
    }
}

/// The folder's front, closed over the back's lower part, or tilted open:
/// its top edge lower and leaning out, its foot where it was.
private struct FolderFront: Shape {
    /// 0 closed, 1 open.
    var open: CGFloat

    var animatableData: CGFloat {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let top = 0.32 + 0.16 * open, lean = 0.13 * open
        let corners = [
            CGPoint(x: lean, y: top), CGPoint(x: 1, y: top),
            CGPoint(x: 1 - lean * 0.4, y: 0.9), CGPoint(x: 0, y: 0.9),
        ]
        return Path.rounded(corners.map { rect.unit($0) }, radius: rect.width * 0.08)
    }
}

private extension CGRect {
    /// A point of a unit square's drawing in this frame.
    func unit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: minX + point.x * width, y: minY + point.y * height)
    }
}

private extension Path {
    /// A closed outline through `corners`, each rounded by `radius`.
    static func rounded(_ corners: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        guard let first = corners.first, let last = corners.last, corners.count > 2 else { return path }
        // From between the last corner and the first, so every corner,
        // the first too, is rounded as the outline turns it.
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for (index, corner) in corners.enumerated() {
            let next = corners[(index + 1) % corners.count]
            path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
        }
        path.closeSubpath()
        return path
    }
}
