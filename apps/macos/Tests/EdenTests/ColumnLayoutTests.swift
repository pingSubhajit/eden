import XCTest
@testable import Eden

/// The column laid out in one go (ColumnLayout), and what a carry over it
/// aims at: pure, on ids, both areas alike (#6). Lines are 28 tall, a
/// heading 22 on its surface 3 in, 2 between lines, the line 18.
final class ColumnLayoutTests: XCTestCase {
    private let metrics = ColumnMetrics(row: 28, heading: 22, gap: 2, inset: 3, line: 18)
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    private let kept = TabGroup(id: UUID(), name: "Kept", collapsed: false)
    private let open = TabGroup(id: UUID(), name: "Open", collapsed: false)

    /// Above the line: a, then Kept holding b and c. Under it: d, then Open
    /// holding e. The New Tab row under them all.
    private var shape: ColumnLayout<UUID>.Shape {
        ColumnLayout<UUID>.Shape(kept: [.tab(a), .group(kept, [b, c])], open: [.tab(d), .group(open, [e])], line: true)
    }

    private func laid(_ shape: ColumnLayout<UUID>.Shape? = nil, carry: ColumnCarry? = nil) -> ColumnLayout<UUID> {
        ColumnLayout(shape ?? self.shape, metrics: metrics, width: 200, carry: carry, id: { $0 })
    }

    private func span(_ rect: CGRect?) -> ClosedRange<CGFloat>? {
        rect.map { $0.minY...$0.maxY }
    }

    private func row(_ id: UUID, in area: ColumnLayout<UUID>.Area) -> CGRect? {
        for piece in area.pieces {
            switch piece {
            case .row(let row) where row.id == id: return row.frame
            case .group(let held):
                if let row = held.members.first(where: { $0.id == id }) { return row.frame }
            default: break
            }
        }
        return nil
    }

    private func group(_ id: UUID, in area: ColumnLayout<UUID>.Area) -> ColumnLayout<UUID>.Group? {
        area.pieces.lazy.compactMap { piece -> ColumnLayout<UUID>.Group? in
            if case .group(let held) = piece, held.group.id == id { return held }
            return nil
        }.first
    }

    private func gap(in pieces: [ColumnLayout<UUID>.Piece]) -> CGRect? {
        pieces.lazy.compactMap { piece -> CGRect? in
            if case .gap(let rect) = piece { return rect }
            return nil
        }.first
    }

    // MARK: - laid out

    func testBothAreasAreLaidOutAsTheViewsStackThem() {
        let column = laid()
        XCTAssertEqual(span(row(a, in: column.kept)), 0...28)
        let held = try? XCTUnwrap(group(kept.id, in: column.kept))
        XCTAssertEqual(span(held?.frame), 30...118, "a group's surface: its heading and rows, 3 in")
        XCTAssertEqual(span(held?.heading), 33...55)
        XCTAssertEqual(span(row(b, in: column.kept)), 57...85)
        XCTAssertEqual(span(row(c, in: column.kept)), 87...115)
        XCTAssertEqual(span(column.line), 120...138, "the line a gap clear of the kept area")
        XCTAssertEqual(span(row(d, in: column.open)), 140...168)
        XCTAssertEqual(span(group(open.id, in: column.open)?.frame), 170...228, "an open group laid out as a kept one")
        XCTAssertEqual(span(row(e, in: column.open)), 197...225)
        XCTAssertEqual(span(column.newTab), 230...258)
        XCTAssertEqual(column.height, 258)
        XCTAssertEqual(column.steps(in: .kept), [30, 90])
        XCTAssertEqual(column.keptLines.map { line -> String in
            switch line {
            case .heading(let group): group.name
            case .tab(let id, let group): (id == a ? "a" : id == b ? "b" : "c") + (group == nil ? "" : " in")
            }
        }, ["a", "Kept", "b in", "c in"])
    }

    func testTheNewTabRowAtTheTopStandsUnderTheLine() {
        var shape = self.shape
        shape.newTabOnTop = true
        let column = laid(shape)
        XCTAssertEqual(span(column.newTab), 140...168)
        XCTAssertEqual(span(row(d, in: column.open)), 170...198)
        XCTAssertEqual(column.height, 258)
    }

    /// A carry's gap opens where it would land, as tall as what is carried,
    /// and its own place closes: the rows between part and close round it.
    func testAGapOpensWhereItWouldLandAndItsOwnPlaceCloses() {
        let carry = ColumnCarry(carried: .tab(d), target: .place(ColumnPlace(area: .kept, index: 1)), height: 28)
        let column = laid(carry: carry)
        XCTAssertEqual(span(gap(in: column.kept.pieces)), 30...58, "before Kept")
        XCTAssertEqual(span(group(kept.id, in: column.kept)?.frame), 60...148)
        XCTAssertEqual(span(column.line), 150...168)
        if case .row(let row)? = column.open.pieces.first {
            XCTAssertTrue(row.away)
            XCTAssertEqual(row.frame.height, 0)
        } else {
            XCTFail("d still drawn, its place closed")
        }
        XCTAssertEqual(span(group(open.id, in: column.open)?.frame), 170...228, "Open where d was")
    }

    func testAGapInAGroupOpensAmongItsRowsAndAFoldedOneShowsIt() {
        let into = ColumnCarry(carried: .tab(d), target: .place(ColumnPlace(area: .kept, group: kept.id, index: 1)), height: 28)
        let held = group(kept.id, in: laid(carry: into).kept)
        XCTAssertEqual(span(held.flatMap { gap(in: $0.rows) }), 87...115, "between b and c")
        XCTAssertEqual(span(held?.frame), 30...148)

        var shape = self.shape
        let folded = TabGroup(id: kept.id, name: "Kept", collapsed: true)
        shape.kept = [.tab(a), .group(folded, [])]
        XCTAssertEqual(span(group(kept.id, in: laid(shape).kept)?.frame), 30...58, "folded: one line")
        let opened = group(kept.id, in: laid(shape, carry: into).kept)
        XCTAssertEqual(opened?.showsRows, true, "a gap opened in it shows")
        XCTAssertEqual(span(opened?.frame), 30...88)
    }

    /// A pair stands as two lines, and its gap is two lines tall.
    func testAPairIsTwoLines() {
        let column = ColumnLayout(shape, metrics: metrics, width: 200, id: { $0 }, lines: { $0 == d ? 2 : 1 })
        XCTAssertEqual(span(row(d, in: column.open)), 140...196)
        XCTAssertEqual(column.steps(in: .open), [58, 60])
    }

    /// A group carried to the other area: a gap its height, its own place
    /// closed, the line moving with what is kept.
    func testAGroupCarriedAboveTheLineClosesItsPlaceBelow() {
        let carry = ColumnCarry(carried: .group(open.id), target: .place(ColumnPlace(area: .kept, index: 0)), height: 58)
        let column = laid(carry: carry)
        XCTAssertEqual(span(gap(in: column.kept.pieces)), 0...58)
        XCTAssertEqual(span(row(a, in: column.kept)), 60...88)
        XCTAssertEqual(span(column.line), 180...198)
        XCTAssertEqual(group(open.id, in: column.open)?.away, true)
        XCTAssertEqual(span(column.newTab), 230...258, "under d, Open's place closed")
    }

    // MARK: - aimed at

    private func aim(_ carried: SideItemID, from own: ColumnRun?, at y: CGFloat,
                     in column: ColumnLayout<UUID>? = nil, takes: @escaping (ColumnPlace) -> Bool = { _ in true }) -> ColumnAim {
        (column ?? laid()).aim(for: carried, from: own, at: CGPoint(x: 70, y: y), holding: nil, takes: takes)
    }

    func testTheLineSplitsTheAreas() {
        let column = laid()
        XCTAssertEqual(column.area(at: 128), .kept)
        XCTAssertEqual(column.area(at: 130), .open)
        var shape = self.shape
        shape.line = false
        shape.kept = []
        XCTAssertEqual(laid(shape).area(at: 5), .open, "nothing kept: no line")
        XCTAssertEqual(laid(shape).area(at: -5), .kept, "and the kept area above the rows' top")
    }

    /// A tab from under the line, over the kept area: at its top level
    /// between its rows and groups, or into a kept group among its rows.
    func testATabAimsAtTheKeptAreaAsAtTheOpenOne() {
        let own = ColumnRun(area: .open)
        XCTAssertEqual(aim(.tab(d), from: own, at: 5), .place(ColumnPlace(area: .kept, index: 0)))
        XCTAssertEqual(aim(.tab(d), from: own, at: 20), .place(ColumnPlace(area: .kept, index: 1)), "past a's middle")
        XCTAssertEqual(aim(.tab(d), from: own, at: 36), .place(ColumnPlace(area: .kept, index: 1)),
                       "the top of a heading is the place before its group")
        XCTAssertEqual(aim(.tab(d), from: own, at: 45), .place(ColumnPlace(area: .kept, group: kept.id, index: 0)),
                       "on an open group's heading: its top")
        XCTAssertEqual(aim(.tab(d), from: own, at: 70), .place(ColumnPlace(area: .kept, group: kept.id, index: 0)))
        XCTAssertEqual(aim(.tab(d), from: own, at: 95), .place(ColumnPlace(area: .kept, group: kept.id, index: 1)))
        XCTAssertEqual(aim(.tab(d), from: own, at: 110), .place(ColumnPlace(area: .kept, group: kept.id)), "its end")
        XCTAssertEqual(aim(.tab(d), from: own, at: 125), .place(ColumnPlace(area: .kept)), "under every kept line: the end")
        XCTAssertEqual(aim(.tab(a), from: ColumnRun(area: .kept), at: 200), .place(ColumnPlace(area: .open, group: open.id, index: 0)),
                       "a kept row over an open group's tab")
        XCTAssertEqual(aim(.tab(a), from: ColumnRun(area: .kept), at: 150), .place(ColumnPlace(area: .open, index: 0)))
    }

    func testAlongItsOwnRunItMovesAsItGoes() {
        XCTAssertEqual(aim(.tab(d), from: ColumnRun(area: .open), at: 150), .along)
        XCTAssertEqual(aim(.tab(e), from: ColumnRun(area: .open, group: open.id), at: 210), .along)
        XCTAssertEqual(aim(.tab(b), from: ColumnRun(area: .kept, group: kept.id), at: 100), .along)
        XCTAssertEqual(aim(.tab(a), from: ColumnRun(area: .kept), at: 5), .along)
        // Out of its group, onto the top of its area.
        XCTAssertEqual(aim(.tab(b), from: ColumnRun(area: .kept, group: kept.id), at: 5), .place(ColumnPlace(area: .kept, index: 0)))
    }

    /// Where the rule says no, nothing parts.
    func testARunThatWontTakeItHoldsItStill() {
        XCTAssertEqual(aim(.tab(d), from: ColumnRun(area: .open), at: 20, takes: { $0.area != .kept }), .refused)
        XCTAssertEqual(aim(.tab(d), from: ColumnRun(area: .open), at: 200, takes: { $0.group == nil }), .refused)
    }

    /// A group only ever goes to an area's top level: over a group's rows,
    /// past it.
    func testAGroupAimsAtTheOtherAreasTopLevelOnly() {
        XCTAssertEqual(aim(.group(open.id), from: ColumnRun(area: .open), at: 10), .place(ColumnPlace(area: .kept, index: 0)))
        XCTAssertEqual(aim(.group(open.id), from: ColumnRun(area: .open), at: 70), .place(ColumnPlace(area: .kept)),
                       "over Kept's rows: after it, never in it")
        XCTAssertEqual(aim(.group(open.id), from: ColumnRun(area: .open), at: 150), .along)
        XCTAssertEqual(aim(.group(kept.id), from: ColumnRun(area: .kept), at: 150), .place(ColumnPlace(area: .open, index: 0)))
        XCTAssertEqual(aim(.group(kept.id), from: ColumnRun(area: .kept), at: 175), .place(ColumnPlace(area: .open, index: 1)))
    }

    /// The rows every space shows keep the head of the kept area.
    func testNothingGoesBeforeTheRowsEverySpaceShows() {
        var shape = self.shape
        shape.keptHead = 1
        XCTAssertEqual(aim(.tab(d), from: ColumnRun(area: .open), at: 2, in: laid(shape)),
                       .place(ColumnPlace(area: .kept, index: 1)))
    }

    /// A folded group takes a tab over its whole surface, and the gap
    /// between it and its neighbours, so a tab carried up to it along the
    /// tabs under it doesn't pass it first.
    func testAFoldedGroupTakesATabOverItsWholeSurface() {
        var shape = self.shape
        shape.kept = []
        shape.line = false
        let folded = TabGroup(id: open.id, name: "Open", collapsed: true)
        shape.open = [.group(folded, []), .tab(d)]
        let column = laid(shape)
        XCTAssertEqual(span(column.dropFrames(in: .open)[open.id]?.rect), -1...29)
        XCTAssertEqual(column.area(at: 2), .open)
        XCTAssertEqual(aim(.tab(d), from: ColumnRun(area: .open), at: 28, in: column),
                       .place(ColumnPlace(area: .open, group: open.id)))
    }

    /// Your other devices' groups stand first, under the squares, over the
    /// kept area, which starts a gap clear of them.
    func testAnotherDevicesGroupIsLaidOutOverTheKeptArea() {
        var shape = self.shape
        shape.devices = [(id: "phone", pages: 0, opened: false), (id: "pad", pages: 2, opened: true)]
        let column = laid(shape)
        XCTAssertEqual(column.devices.map(\.id), ["phone", "pad"])
        XCTAssertEqual(column.devices.map { span($0.frame) }, [0...28, 30...118])
        XCTAssertEqual(span(row(a, in: column.kept)), 120...148, "the kept area under them")
        XCTAssertEqual(span(group(kept.id, in: column.kept)?.frame), 150...238)
        XCTAssertEqual(span(column.line), 240...258)
        XCTAssertEqual(span(row(d, in: column.open)), 260...288)
        XCTAssertEqual(column.device(at: 40, holding: nil), "pad")
        XCTAssertNil(column.device(at: 119, holding: nil))
        XCTAssertEqual(column.device(at: 119, holding: "pad"), "pad", "the one it is over keeps it a little past its edge")
        let carry = ColumnCarry(carried: .tab(d), target: .device("phone"), height: 28)
        let opened = laid(shape, carry: carry)
        XCTAssertEqual(opened.devices.first.map { span($0.frame) }, 0...58, "opened to show where it goes")
        XCTAssertEqual(opened.devices.first.flatMap { span($0.gap) }, 27...55)
        XCTAssertEqual(span(row(a, in: opened.kept)), 150...178, "and the kept area under it moves down as far")
    }

    /// A folded device's group shows its pages once a tab is carried onto
    /// it, as DeviceGroup draws it (DeviceRows): the layout counts them, the
    /// gap at their end, and everything under it moves down as far.
    func testAFoldedDevicesGroupShowsItsPagesForACarriedTab() {
        var shape = self.shape
        shape.devices = [(id: "phone", pages: 3, opened: false), (id: "pad", pages: 2, opened: false)]
        XCTAssertEqual(DeviceRows.lines(pages: 3, opened: false, carried: false), 0)
        XCTAssertEqual(DeviceRows.lines(pages: 3, opened: false, carried: true), 4)
        XCTAssertEqual(DeviceRows.lines(pages: 3, opened: true, carried: true), 4)
        XCTAssertEqual(laid(shape).devices.map { span($0.frame) }, [0...28, 30...58], "folded: a heading each")
        let carry = ColumnCarry(carried: .tab(d), target: .device("phone"), height: 28)
        let column = laid(shape, carry: carry)
        XCTAssertEqual(column.devices.map { span($0.frame) }, [0...148, 150...178],
                       "its three pages and the gap: heading 28, then 2 + 3 × 30 + 28")
        XCTAssertEqual(column.devices.first.flatMap { span($0.gap) }, 117...145)
        XCTAssertEqual(span(row(a, in: column.kept)), 180...208)
        XCTAssertEqual(span(column.line), 300...318)
        XCTAssertEqual(span(row(d, in: column.open)), 320...348)
        XCTAssertEqual(column.device(at: 100, holding: "phone"), "phone", "over its pages: the device's")
        XCTAssertEqual(column.area(at: 100), .kept, "over the devices: above the line")
        XCTAssertEqual(column.area(at: 308), .kept)
        XCTAssertEqual(column.area(at: 310), .open)
    }

    /// Over the devices, anything they don't take goes to the head of the
    /// kept area under them: a group, or a first pin with nothing kept yet.
    func testOverTheDevicesIsTheHeadOfTheKeptArea() {
        var shape = self.shape
        shape.devices = [(id: "phone", pages: 0, opened: false)]
        XCTAssertEqual(laid(shape).aim(for: .group(open.id), from: ColumnRun(area: .open), at: CGPoint(x: 70, y: 10),
                                       holding: nil) { _ in true }, .place(ColumnPlace(area: .kept, index: 0)))
        shape.kept = []
        let empty = laid(shape)
        XCTAssertEqual(span(empty.line), 30...48)
        XCTAssertEqual(empty.aim(for: .tab(d), from: ColumnRun(area: .open), at: CGPoint(x: 70, y: 10), holding: nil) { _ in true },
                       .place(ColumnPlace(area: .kept)), "nothing kept: the first pin")
        XCTAssertEqual(empty.aim(for: .tab(d), from: ColumnRun(area: .open), at: CGPoint(x: 70, y: 36), holding: nil) { _ in true },
                       .place(ColumnPlace(area: .kept)), "the line's upper half too")
    }

    /// The New Tab row takes nothing: the hand over it at the top of your
    /// tabs is at the head of them, from either area; at their foot, at
    /// their end.
    func testTheNewTabRowIsTheHeadOrTheFootOfYourTabs() {
        var shape = self.shape
        shape.newTabOnTop = true
        let top = laid(shape)
        XCTAssertEqual(span(top.newTab), 140...168)
        let over = CGPoint(x: 70, y: 154)
        XCTAssertEqual(top.aim(for: .tab(a), from: ColumnRun(area: .kept), at: over, holding: nil) { _ in true },
                       .place(ColumnPlace(area: .open, index: 0)), "a kept row: the head of your tabs, under New tab")
        XCTAssertEqual(top.aim(for: .group(kept.id), from: ColumnRun(area: .kept), at: over, holding: nil) { _ in true },
                       .place(ColumnPlace(area: .open, index: 0)), "a kept group too")
        XCTAssertEqual(top.aim(for: .tab(d), from: ColumnRun(area: .open), at: over, holding: nil) { _ in true }, .along,
                       "a tab of yours: along its own run, to its head")
        let opened = ColumnLayout(shape, metrics: metrics, width: 200,
                                  carry: ColumnCarry(carried: .tab(a), target: .place(ColumnPlace(area: .open, index: 0)), height: 28),
                                  id: { $0 })
        XCTAssertEqual(span(opened.newTab), 110...138, "New tab where it was, less the place closed above")
        XCTAssertEqual(span(gap(in: opened.open.pieces)), 140...168, "the gap straight under it")

        let foot = laid()
        XCTAssertEqual(span(foot.newTab), 230...258)
        XCTAssertEqual(foot.aim(for: .tab(a), from: ColumnRun(area: .kept), at: CGPoint(x: 70, y: 244), holding: nil) { _ in true },
                       .place(ColumnPlace(area: .open)), "at the foot: the end of your tabs")
    }

    /// The New Tab row wins over the margin the group the hand was over
    /// keeps: at its upper edge under the last group, the end of your tabs;
    /// at its lower edge over the first, their head.
    func testTheNewTabRowWinsOverAHeldGroupsMargin() {
        let foot = laid()
        let heldOpen = ColumnPlace(area: .open, group: open.id)
        XCTAssertEqual(span(foot.newTab), 230...258)
        XCTAssertEqual(foot.aim(for: .tab(a), from: ColumnRun(area: .kept), at: CGPoint(x: 70, y: 226), holding: heldOpen) { _ in true },
                       .place(ColumnPlace(area: .open, group: open.id)), "within the group's margin, above New tab: still the group's")
        XCTAssertEqual(foot.aim(for: .tab(a), from: ColumnRun(area: .kept), at: CGPoint(x: 70, y: 231), holding: heldOpen) { _ in true },
                       .place(ColumnPlace(area: .open)), "on New tab's upper edge: the end of your tabs")
        XCTAssertEqual(foot.aim(for: .tab(e), from: ColumnRun(area: .open, group: open.id), at: CGPoint(x: 70, y: 231),
                                holding: nil) { _ in true },
                       .place(ColumnPlace(area: .open)), "its own group's tab too: out of it, at the end")

        var shape = self.shape
        shape.newTabOnTop = true
        shape.open = [.group(open, [e]), .tab(d)]
        let top = laid(shape)
        XCTAssertEqual(span(top.newTab), 140...168)
        XCTAssertEqual(top.aim(for: .tab(a), from: ColumnRun(area: .kept), at: CGPoint(x: 70, y: 167), holding: heldOpen) { _ in true },
                       .place(ColumnPlace(area: .open, index: 0)), "on New tab's lower edge: the head of your tabs, not the group under it")
    }

    /// A pin every space shows goes among the rows at the kept area's head
    /// and no further down.
    func testAPinEverySpaceShowsStaysAmongTheHead() {
        var shape = self.shape
        shape.keptHead = 1
        let column = laid(shape)
        XCTAssertEqual(column.aim(for: .tab(d), from: nil, at: CGPoint(x: 70, y: 125), holding: nil, heading: true) { _ in true },
                       .place(ColumnPlace(area: .kept, index: 1)), "after the one there is, not at the end")
        XCTAssertEqual(column.aim(for: .tab(d), from: nil, at: CGPoint(x: 70, y: 2), holding: nil, heading: true) { _ in true },
                       .place(ColumnPlace(area: .kept, index: 0)))
    }
}
