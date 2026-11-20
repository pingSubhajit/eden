import SwiftUI

/// A tab carried across the line between the pins and the tabs, as in Arc:
/// a tab let go over the grid becomes a pin there, a pin let go among the
/// tabs becomes a tab there, and the block it is over makes room for it on
/// the way — a place opened in the grid, a line opened among the rows —
/// so where it will land is seen before it is let go.
///
/// The gestures stay each row's and each square's own (Carried,
/// PinCarried); this is only where in the column the hand is, worked out
/// in one space every block is measured in (the page's, "column").
enum PinDrop {
    /// Where a carried tab would land.
    enum Target: Equatable {
        /// Among the squares, at this place.
        case squares(Int)
        /// Among the pinned rows (Settings › Tabs › Pinned rows).
        case listed(Int)
        /// Among the tabs in no group.
        case loose(Int)
        /// Into a group, over its heading.
        case group(UUID)
    }

    /// The tab being carried and where it would land: what the column
    /// shows while it is over a block that would take it.
    struct Crossing: Equatable {
        let tab: Tab.ID
        let target: Target
    }

    enum Zone: Equatable { case squares, listed, loose, none }

    /// The half of the margin under the grid that still counts as the
    /// grid, so the hand needn't reach a square to aim between two.
    static let gridSlack: CGFloat = 5
    /// How far beside the column the hand may stray and still be in it.
    static let sideSlack: CGFloat = 10

    /// Which block a point is over, in the column's space: the grid's —
    /// everything above its bottom edge, the band of the window's buttons
    /// included, which is where a first pin is made when there is none —
    /// then the pinned rows, then the tabs. Beside the column, none.
    /// `gridBottom` nil: no grid drawn, and its block is above the page.
    static func zone(_ point: CGPoint, width: CGFloat, gridBottom: CGFloat?, listed: CGRect?) -> Zone {
        guard point.x >= -sideSlack, point.x <= width + sideSlack else { return .none }
        let edge = gridBottom.map { $0 + gridSlack } ?? 0
        if point.y < edge { return .squares }
        if let listed, listed.height > 0, point.y < listed.maxY + 1 { return .listed }
        return .loose
    }

    /// The place among the squares a point is over, once the grid has made
    /// room for one more: the nearest of `cells`, laid out for that many.
    /// The place opened is one of them, so the hand over it keeps it.
    static func gridSlot(_ point: CGPoint, cells: [CGRect]) -> Int {
        func distance(_ cell: CGRect) -> CGFloat { hypot(cell.midX - point.x, cell.midY - point.y) }
        return cells.indices.min { distance(cells[$0]) < distance(cells[$1]) } ?? 0
    }

    /// The place among rows of `heights` (top to bottom, `gap` between) a
    /// point `y` down from the first is over: before the first row whose
    /// middle it is above. `ghost`: the line already opened, at its place
    /// and of its height — the hand anywhere on it keeps it, and the rows
    /// after it are measured where they now are, below it.
    static func rowSlot(y: CGFloat, heights: [CGFloat], gap: CGFloat, ghost: (at: Int, height: CGFloat)?) -> Int {
        var top: CGFloat = 0
        for (index, height) in heights.enumerated() {
            if let ghost, ghost.at == index {
                if y < top + ghost.height { return index }
                top += ghost.height + gap
            }
            if y < top + height / 2 { return index }
            top += height + gap
        }
        return heights.count
    }
}

/// Where the column's blocks are, in its space. Kept out of SwiftUI's
/// state on purpose: measured on every layout and every scroll, and read
/// only while a tab is carried, it must not draw the column again.
final class ColumnFrames {
    var grid: CGRect?
    var listed: CGRect?
    var rows: CGRect = .zero
    var loose: CGRect?
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

/// Where a tab carried out of its own run in the column would land if let
/// go now — in a group, among the tabs in none, or on another device — and
/// how tall a place it needs: the rows there part for it (RowGapSlot) while
/// its own place closes (RowGapSource). Along its own run it needs none: it
/// moves as it goes (Carried).
struct RowGap: Equatable {
    enum Place: Equatable {
        /// In a group, before one of its tabs, or at its end.
        case group(UUID, before: UUID?)
        /// Among the tabs in no group, before one of them or a group, or
        /// after them all.
        case loose(before: SideItemID?)
        /// At the end of another device's group (DeviceGroup), by its id as
        /// it syncs: opened there too (Sync.askToOpen), and kept here.
        case device(String)
    }

    let tab: UUID
    let place: Place
    let height: CGFloat
    /// The row's whole item, rather than a pair's half leaving it, whose
    /// other half keeps the row's place.
    var whole = true

    var group: UUID? {
        if case .group(let id, _) = place { return id }
        return nil
    }

    /// Another device it would be opened on.
    var device: String? {
        if case .device(let id) = place { return id }
        return nil
    }

    /// Whether the tab leaves its own place for it: not for another device,
    /// where it is opened as well as kept here.
    var moves: Bool { device == nil }

    /// Whether the row's place closes behind it: not for a copy, nor for a
    /// half whose pair stays.
    var empties: Bool { moves && whole }

    /// The run it is in, to tell when it moves into another.
    var run: String {
        switch place {
        case .group(let id, _): return id.uuidString
        case .loose: return "loose"
        case .device(let id): return "device:" + id
        }
    }

    /// How long a carried tab rests on a folded group before it opens.
    static let spring: TimeInterval = 0.5
    /// Its frame among the groups' (GroupDropFrames): the hand over the gap
    /// is over its group.
    static let frameKey = UUID()
}

/// Where the gap is drawn in the rows' space, kept for the tab let go into
/// it to start from the hand: a box, so the rows don't redraw as it moves.
final class RowGapFrame {
    var top: CGFloat?
}

/// Where each of your other devices' groups is drawn in the rows' space,
/// by the device's id as it syncs, for a tab carried onto one: a box, as
/// LooseFrames is, so a group that moves redraws nothing.
final class DeviceFrames {
    var rects: [String: CGRect] = [:]
}

/// A tab let go into a gap in another run: a new row there, not the one
/// carried, which goes at once. It starts where the hand left it, by this
/// much, and settles into its place.
struct RowLanding: Equatable {
    let tab: UUID
    let offset: CGFloat
}

/// The place a gap opens for a carried tab: nothing drawn, only room the
/// rows around it make, measured as part of its group's run.
struct RowGapSlot: View {
    let gap: RowGap
    let frame: RowGapFrame

    var body: some View {
        Color.clear
            .frame(height: gap.height)
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("rows")).minY }) { [frame] in frame.top = $0 }
            .background {
                if let group = gap.group {
                    GeometryReader { geometry in
                        Color.clear.preference(key: GroupDropFrames.self,
                                               value: [RowGap.frameKey: GroupDropFrame(group: group,
                                                                                       rect: geometry.frame(in: .named("rows")))])
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

/// A row whose tab is carried to a gap in another run: its own place
/// closes, the tab still drawn under the hand from where the place began.
/// Always applied, so the carried row's view never changes under the hand,
/// which would call the carry off (see Carried).
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

/// The line opened among the rows for a tab carried there: its mark and
/// name, faint, on the hover grey.
struct RowGhost: View {
    @Environment(\.greys) private var greys
    @ObservedObject var tab: Tab
    let height: CGFloat
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 8) {
            Mark(icon: tab.icon, letter: tab.monogram, size: 15)
            Text(tab.label)
                .font(.system(size: size))
                .lineLimit(1)
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
        }
        .opacity(0.6)
        .padding(.leading, 10)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(greys.hover))
        .overlay { shape.strokeBorder(Palette.ink.opacity(0.16), lineWidth: 1) }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
