import SwiftUI

/// A tab carried onto the squares, as in Arc: let go over the grid, it
/// becomes a square there, and the grid makes room for it on the way, so
/// where it will land is seen before it is let go. The squares are a tier of
/// their own, above the column's two areas; everything under the grid is
/// the rows', which part for a tab carried there as for any other
/// (ColumnLayout, ColumnCarry).
///
/// The gestures stay each row's and each square's own (Carried,
/// PinCarried); this is only whether the hand is over the grid, worked out
/// in one space the grid and the rows are both measured in (the page's,
/// "column").
enum PinDrop {
    /// A tab carried over the grid, and the place among the squares opened
    /// for it.
    struct Crossing: Equatable {
        let tab: Tab.ID
        let slot: Int
    }

    enum Zone: Equatable { case squares, rows, none }

    /// The half of the margin under the grid that still counts as the
    /// grid, so the hand needn't reach a square to aim between two.
    static let gridSlack: CGFloat = 5
    /// How far beside the column the hand may stray and still be in it.
    static let sideSlack: CGFloat = 10

    /// Which tier a point is over, in the column's space: the grid's —
    /// everything above its bottom edge, the band of the window's buttons
    /// included, which is where a first pin is made when there is none —
    /// or the rows under it. Beside the column, none. `gridBottom` nil: no
    /// grid drawn, and its tier is above the page.
    static func zone(_ point: CGPoint, width: CGFloat, gridBottom: CGFloat?) -> Zone {
        guard point.x >= -sideSlack, point.x <= width + sideSlack else { return .none }
        let edge = gridBottom.map { $0 + gridSlack } ?? 0
        return point.y < edge ? .squares : .rows
    }

    /// The place among the squares a point is over, once the grid has made
    /// room for one more: the nearest of `cells`, laid out for that many.
    /// The place opened is one of them, so the hand over it keeps it.
    static func gridSlot(_ point: CGPoint, cells: [CGRect]) -> Int {
        func distance(_ cell: CGRect) -> CGFloat { hypot(cell.midX - point.x, cell.midY - point.y) }
        return cells.indices.min { distance(cells[$0]) < distance(cells[$1]) } ?? 0
    }
}

/// Where the grid and the rows are, in the column's space, for taking a
/// point from one to the other. Kept out of SwiftUI's state on purpose:
/// measured on every layout and every scroll, and read only while a tab is
/// carried, it must not draw the column again.
final class ColumnFrames {
    var grid: CGRect?
    var rows: CGRect = .zero
    /// The scrolling part of the column, which cuts off what is drawn past
    /// its edges.
    var scroll: CGRect?
}

/// The place opened in the grid for a tab carried there: its mark, faint,
/// on the hover grey.
struct PinGhost: View {
    @Environment(\.greys) private var greys
    @ObservedObject var tab: Tab
    let width: CGFloat
    let height: CGFloat

    private var scale: CGFloat { min(width, height) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
        shape
            .fill(greys.hover)
            .overlay { shape.strokeBorder(Palette.ink.opacity(0.16), lineWidth: 1) }
            .overlay {
                Mark(icon: tab.icon, letter: tab.pin ?? tab.monogram, size: scale * 16 / 34)
                    .opacity(0.55)
            }
            .frame(width: width, height: height)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// Where the gap is drawn in the rows' space, kept for the tab let go into
/// it to start from the hand: a box, so the rows don't redraw as it moves.
final class RowGapFrame {
    var top: CGFloat?
}

/// A tab or a group let go into a gap in another run: drawn there anew, not
/// the one carried, which goes at once. It starts where the hand left it,
/// by this much, and settles into its place.
struct RowLanding: Equatable {
    /// The tab's id, or the group's.
    let tab: UUID
    let offset: CGFloat
}

/// The place a gap opens for something carried (ColumnCarry): nothing
/// drawn, only room the rows around it make, as tall as what it is for.
struct RowGapSlot: View {
    let height: CGFloat
    let frame: RowGapFrame

    var body: some View {
        Color.clear
            .frame(height: height)
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("rows")).minY }) { [frame] in frame.top = $0 }
            .accessibilityHidden(true)
    }
}

/// A row or a group carried to a gap in another run: its own place closes,
/// what it is still drawn under the hand from where the place began.
/// Always applied, so the carried view never changes under the hand, which
/// would call the carry off (see Carried).
struct RowGapSource: ViewModifier {
    let away: Bool
    /// Just let go into a gap here: how far from its place it starts.
    var landing: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .frame(height: away ? 0 : nil, alignment: .top)
            .padding(.bottom, away ? -SideBar.gap : 0)
            .offset(y: landing)
    }
}
