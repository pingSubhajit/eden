import Foundation

/// How pinned squares fall into rows, as the Mac's column lays them out:
/// no more than `most` to a row, and the rows as even as they can be, so
/// six are three and three rather than four and two. Each row then spans
/// the width it is given, its squares sharing it. The Mac's SideBar.pinRows
/// splits them the same way.
public enum PinRows {
    public static func split(_ count: Int, most: Int) -> [Int] {
        guard count > 0 else { return [] }
        let most = max(1, most)
        let rows = (count + most - 1) / most
        let base = count / rows
        let extra = count % rows
        return (0..<rows).map { $0 < extra ? base + 1 : base }
    }

    /// The places a row is split into: its own squares, except that one row
    /// alone of fewer than `least` keeps `least` places, so two pins aren't
    /// stretched across the whole width.
    public static func places(_ rows: [Int], least: Int) -> [Int] {
        rows.map { rows.count == 1 ? max($0, least) : $0 }
    }
}
