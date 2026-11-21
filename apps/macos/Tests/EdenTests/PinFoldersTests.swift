import EdenCore
import XCTest
@testable import Eden

/// The column's one model (Column.swift) and the kept groups' files
/// (KeptGroups.swift): a pin's group written as its folder always was, the
/// kept groups' file and pin-folders.json read both ways, folders an Eden
/// from before kept inside others flattened as they are taken in, what an
/// area draws — the same for both areas — where a row let go goes, and
/// Arc's nested folders coming in one level deep. In memory only.
final class PinFoldersTests: XCTestCase {
    private func def(_ letter: String, group: UUID? = nil) -> PinDef {
        PinDef(id: UUID(), letter: letter, home: "https://\(letter.lowercased()).example/",
               title: letter, name: nil, listed: true, group: group)
    }

    private func group(_ name: String, collapsed: Bool = false) -> TabGroup {
        TabGroup(id: UUID(), name: name, collapsed: collapsed)
    }

    private func items(_ pins: [PinDef], _ groups: [TabGroup], keepingEmpty: Bool = true) -> [ColumnItem<UUID>] {
        ColumnTree.items(pins, group: \.group, groups: groups, keepingEmpty: keepingEmpty).map { item in
            switch item {
            case .tab(let pin): .tab(pin.id)
            case .group(let group, let pins): .group(group, pins.map(\.id))
            }
        }
    }

    // MARK: - the files

    func testAPinInNoGroupIsWrittenAsItAlwaysWas() throws {
        let data = try JSONEncoder().encode(def("A"))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("folder"))
        XCTAssertFalse(keys.contains("group"))
    }

    func testAPinsGroupRoundTripsAsItsFolderAndAnOldPinReadsAsInNone() throws {
        let g = UUID()
        let a = def("A", group: g)
        let data = try JSONEncoder().encode(a)
        XCTAssertEqual(try JSONDecoder().decode(PinDef.self, from: data), a)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(keys["folder"] as? String, g.uuidString, "the name it has always had on disk")
        let old = #"{"id":"\#(UUID().uuidString)","letter":"G","home":"https://g.example/","title":"G"}"#
        XCTAssertNil(try JSONDecoder().decode(PinDef.self, from: Data(old.utf8)).group)
    }

    func testAPinsFileWithGroupsStillReadsAsPins() throws {
        let space = UUID()
        let a = def("A", group: UUID())
        let data = try PinsFile.encode(PinCatalog(bySpace: [space: [a]]))
        XCTAssertEqual(try PinsFile.decode(data).bySpace[space], [a])
    }

    func testAFolderFromBeforeReadsAsAnOpenStoneGroupWithNoIcon() throws {
        let space = UUID(), id = UUID()
        let json = #"{"\#(space.uuidString)":[{"id":"\#(id.uuidString)","name":"Work","parent":"not an id"}]}"#
        let read = try XCTUnwrap(LegacyPinFolders.decode(Data(json.utf8)))
        XCTAssertEqual(read.bySpace[space], [TabGroup(id: id, name: "Work", collapsed: false, colour: .stone, icon: nil)])
        // Written into the new file with no look an older Eden would meet,
        // and no parent.
        let file = try XCTUnwrap(KeptGroupsFile.encode(read))
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: file) as? [String: [[String: Any]]])
        XCTAssertEqual(Set(try XCTUnwrap(top[space.uuidString]?.first).keys), ["id", "name", "collapsed"])
    }

    /// Everything a folder had comes over: its id (the rows' group), its
    /// name, its fold, its colour and its icon.
    func testAFoldersEveryFieldComesOverIntoItsGroup() throws {
        let space = UUID(), id = UUID()
        let json = #"{"\#(space.uuidString)":[{"id":"\#(id.uuidString)","name":"Reading","collapsed":true,"colour":"madder","icon":"emoji:📚"}]}"#
        let read = try XCTUnwrap(LegacyPinFolders.decode(Data(json.utf8)))
        XCTAssertEqual(read.bySpace[space], [TabGroup(id: id, name: "Reading", collapsed: true, colour: .madder, icon: .emoji("📚"))])
        XCTAssertTrue(read.moved.isEmpty)
    }

    func testAGroupsColourAndIconGoAndComeBackTheSame() throws {
        var work = TabGroup(id: UUID(), name: "Work", collapsed: true, colour: .sage, icon: .emoji("🌿"))
        XCTAssertEqual(try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(work)), work)
        work.icon = .symbol("leaf.fill")
        let file = try XCTUnwrap(KeptGroupsFile.encode(KeptGroupsFile.Read(bySpace: [UUID(): [work]])))
        XCTAssertEqual(KeptGroupsFile.decode(file)?.bySpace.values.first, [work])
    }

    /// Where the folders that were inside others went is kept in the new
    /// file until the rows are known to be on disk in them; once they are,
    /// nothing of it is written.
    func testMovesWaitingForTheRowsAreKeptInTheFile() throws {
        let space = UUID()
        let work = group("Work")
        let child = UUID()
        let file = try XCTUnwrap(KeptGroupsFile.encode(KeptGroupsFile.Read(bySpace: [space: [work]], moved: [space: [child: work.id]])))
        let read = try XCTUnwrap(KeptGroupsFile.decode(file))
        XCTAssertEqual(read.bySpace[space], [work])
        XCTAssertEqual(read.moved[space], [child: work.id])

        let settled = try XCTUnwrap(KeptGroupsFile.encode(KeptGroupsFile.Read(bySpace: [space: [work]])))
        XCTAssertEqual(KeptGroupsFile.decode(settled)?.moved.isEmpty, true, "nothing kept once the rows landed")
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: settled) as? [String: Any])
        XCTAssertNil(top[KeptGroupsFile.movedKey])
    }

    /// pin-folders.json's own waiting moves come over with it.
    func testTheOldFilesWaitingMovesComeOver() throws {
        let space = UUID(), work = UUID(), gone = UUID()
        let json = #"{"\#(space.uuidString)":[{"id":"\#(work.uuidString)","name":"Work"}],"moved":{"\#(space.uuidString)":{"\#(gone.uuidString)":"\#(work.uuidString)"}}}"#
        let read = try XCTUnwrap(LegacyPinFolders.decode(Data(json.utf8)))
        XCTAssertEqual(read.moved[space], [gone: work])
    }

    func testAnEmptyFileIsStillAFile() throws {
        // That it is there says pin-folders.json was taken in.
        let file = try XCTUnwrap(KeptGroupsFile.encode(KeptGroupsFile.Read()))
        XCTAssertEqual(KeptGroupsFile.decode(file), KeptGroupsFile.Read())
        XCTAssertNil(KeptGroupsFile.decode(Data("not json".utf8)), "a file that isn't one is said so, to be set aside")
        XCTAssertNil(LegacyPinFolders.decode(Data("[".utf8)))
    }

    func testAColourOrIconANewerEdenAddedReadsAsNone() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Work","colour":"teal","icon":"sticker:🦊"}"#
        let read = try JSONDecoder().decode(TabGroup.self, from: Data(json.utf8))
        XCTAssertEqual(read.colour, .stone)
        XCTAssertNil(read.icon)
    }

    func testASpaceWhoseGroupsDontReadLosesNoOtherSpace() throws {
        let good = UUID(), bad = UUID()
        let work = group("Work")
        let encoded = try XCTUnwrap(KeptGroupsFile.encode(KeptGroupsFile.Read(bySpace: [good: [work]])))
        var top = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        top[bad.uuidString] = [["name": 3]]
        top["not a space"] = []
        let data = try JSONSerialization.data(withJSONObject: top)
        XCTAssertEqual(KeptGroupsFile.decode(data), KeptGroupsFile.Read(bySpace: [good: [work]]))
        XCTAssertEqual(LegacyPinFolders.decode(data), KeptGroupsFile.Read(bySpace: [good: [work]]))
    }

    func testSharingAPinTakesItOutOfItsGroup() {
        let a = def("A", group: UUID())
        let moved = PinLists.share(a.id, own: [a], shared: [])
        XCTAssertNil(moved.shared.first?.group)
    }

    // MARK: - folders inside folders, from before

    /// Work holding Docs holding Old, Home, X and Y holding each other, and
    /// Lost inside a folder that is gone, as an Eden from before wrote them.
    func testFoldersInsideFoldersAreFlattenedAsTheyAreTakenIn() throws {
        let space = UUID()
        let work = group("Work"), docs = group("Docs"), old = group("Old", collapsed: true)
        let home = group("Home"), x = group("X"), y = group("Y"), lost = group("Lost")
        func entry(_ group: TabGroup, in parent: UUID?) -> [String: Any] {
            var out: [String: Any] = ["id": group.id.uuidString, "name": group.name, "collapsed": group.collapsed]
            if let parent { out["parent"] = parent.uuidString }
            return out
        }
        let file = try JSONSerialization.data(withJSONObject: [space.uuidString: [
            entry(work, in: nil), entry(docs, in: work.id), entry(old, in: docs.id), entry(home, in: nil),
            entry(x, in: y.id), entry(y, in: x.id), entry(lost, in: UUID()),
        ]])
        let read = try XCTUnwrap(LegacyPinFolders.decode(file))
        XCTAssertEqual(read.bySpace[space]?.map(\.name), ["Work", "Home", "X", "Lost"],
                       "one level, in their order; of two holding each other, the first listed")
        XCTAssertEqual(read.moved[space], [docs.id: work.id, old.id: work.id, y.id: x.id])

        let a = def("A", group: old.id), b = def("B", group: docs.id), c = def("C", group: home.id)
        let d = def("D", group: y.id), e = def("E")
        let refiled = LegacyPinFolders.refiled([a, b, c, d, e], into: read.moved[space] ?? [:])
        XCTAssertEqual(refiled.map(\.group), [work.id, work.id, home.id, x.id, nil],
                       "each row in the group at the top it was in")
        XCTAssertEqual(refiled.map(\.id), [a, b, c, d, e].map(\.id))
    }

    func testAFolderWithNothingAboveItIsLeftAsItIs() {
        let work = group("Work"), home = group("Home")
        let flat = LegacyPinFolders.flattened([work, home], parents: [:])
        XCTAssertEqual(flat.groups, [work, home])
        XCTAssertTrue(flat.into.isEmpty)
        XCTAssertEqual(LegacyPinFolders.flattened([work], parents: [work.id: work.id]).groups, [work], "nor one holding itself")
    }

    // MARK: - what an area draws

    /// A group stands where its first tab stands, its tabs together, among
    /// the tabs in no group: the same in both areas.
    func testAGroupStandsWhereItsFirstTabStands() {
        let work = group("Work"), docs = group("Docs")
        let a = def("A"), b = def("B", group: work.id), c = def("C", group: docs.id), d = def("D", group: work.id)
        XCTAssertEqual(items([a, b, c, d], [work, docs]), [
            .tab(a.id),
            .group(work, [b.id, d.id]),
            .group(docs, [c.id]),
        ])
        XCTAssertEqual(items([b, a, d, c], [docs, work], keepingEmpty: false), [
            .group(work, [b.id, d.id]),
            .tab(a.id),
            .group(docs, [c.id]),
        ], "the groups' own order says nothing while they hold tabs")
        XCTAssertEqual(ColumnTree.ordered([a, b, c, d], group: \.group, groups: [work, docs]).map(\.id),
                       [a, b, d, c].map(\.id), "laid flat, each group's tabs together")
    }

    /// An empty group, kept above the line, stands after the group before
    /// it in their own order, or first; under the line there is none.
    func testAnEmptyGroupStandsAfterTheGroupBeforeIt() {
        let work = group("Work"), empty = group("Empty"), first = group("First")
        let a = def("A"), b = def("B", group: work.id), c = def("C")
        XCTAssertEqual(items([a, b, c], [first, work, empty]), [
            .group(first, []), .tab(a.id), .group(work, [b.id]), .group(empty, []), .tab(c.id),
        ])
        XCTAssertEqual(items([a, b, c], [first, work, empty], keepingEmpty: false), [
            .tab(a.id), .group(work, [b.id]), .tab(c.id),
        ])
    }

    func testFlatteningTheItemsGivesBackTheTabsAndTheGroupsInOrder() {
        let work = group("Work"), empty = group("Empty")
        let a = def("A"), b = def("B", group: work.id)
        let flat = ColumnTree.flattened(ColumnTree.items([a, b], group: \.group, groups: [empty, work], keepingEmpty: true))
        XCTAssertEqual(flat.members.map(\.member.id), [a.id, b.id])
        XCTAssertEqual(flat.members.map(\.group), [nil, work.id])
        XCTAssertEqual(flat.groups.map(\.id), [empty.id, work.id])
        // Read again, the same: the order is its own fixed point.
        let again = ColumnTree.items(flat.members.map(\.member), group: \.group, groups: flat.groups, keepingEmpty: true)
        XCTAssertEqual(again.map { $0.group?.id }, [empty.id, nil, work.id])
    }

    func testAFoldedGroupHidesItsTabsButThePageYouAreOn() {
        let work = group("Work", collapsed: true)
        let b = def("B", group: work.id), c = def("C", group: work.id)
        let drawn = ColumnTree.items([b.id, c.id], group: { _ in work.id }, groups: [work], keepingEmpty: true)
        XCTAssertEqual(ColumnTree.lines(drawn), [.heading(work)])
        XCTAssertEqual(ColumnTree.lines(drawn, showing: { $0 == c.id }), [.heading(work), .tab(c.id, group: work.id)])
    }

    func testATabWhoseGroupIsGoneIsInNone() {
        let a = def("A", group: UUID())
        XCTAssertEqual(items([a], []), [.tab(a.id)])
    }

    func testAnImportMakesNoEmptyGroup() {
        let mine = group("Mine"), work = group("Work"), empty = group("Empty")
        let a = def("A", group: work.id)
        let kept = ColumnTree.withoutEmpty([mine, work, empty], keeping: [mine.id], pins: [a])
        XCTAssertEqual(kept.map(\.id), [mine.id, work.id])
    }

    // MARK: - Arc

    /// A StorableSidebar.json with one space whose pinned list is a page and
    /// a folder four deep, each level holding a page.
    private func arcFile() throws -> Data {
        var items: [[String: Any]] = []
        func tab(_ id: String, _ url: String) -> [String: Any] {
            ["id": id, "title": id, "data": ["tab": ["savedURL": url, "savedTitle": id]]]
        }
        func list(_ id: String, _ children: [String]) -> [String: Any] {
            ["id": id, "title": id, "childrenIds": children, "data": ["list": [:] as [String: Any]]]
        }
        items.append(["id": "pinned", "childrenIds": ["top", "L1"], "data": [:] as [String: Any]])
        items.append(tab("top", "https://top.example/"))
        items.append(list("L1", ["p1", "L2"]))
        items.append(tab("p1", "https://one.example/"))
        items.append(list("L2", ["p2", "L3"]))
        items.append(tab("p2", "https://two.example/"))
        items.append(list("L3", ["p3", "L4"]))
        items.append(tab("p3", "https://three.example/"))
        items.append(list("L4", ["p4"]))
        items.append(tab("p4", "https://four.example/"))
        let space: [String: Any] = ["id": "s", "title": "Work", "containerIDs": ["pinned", "pinned"]]
        let main: [String: Any] = ["spaces": ["s", space], "items": items, "topAppsContainerIDs": [] as [Any]]
        return try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [["global": [:] as [String: Any]], main]]])
    }

    func testArcsParserKeepsTheNesting() throws {
        let sidebar = try XCTUnwrap(Arc.parse(arcFile(), profile: nil))
        let pinned = try XCTUnwrap(sidebar.spaces.first?.pinned)
        XCTAssertEqual(pinned.count, 2)
        guard case .folder(let l1) = pinned[1], case .folder(let l2) = l1.items[1],
              case .folder(let l3) = l2.items[1], case .folder(let l4) = l3.items[1]
        else { return XCTFail("folders not nested: \(pinned)") }
        XCTAssertEqual([l1.title, l2.title, l3.title, l4.title], ["L1", "L2", "L3", "L4"])
        XCTAssertEqual(sidebar.pinnedCount, 5)
    }

    func testArcsFoldersComeInOneLevelDeep() throws {
        let sidebar = try XCTUnwrap(Arc.parse(arcFile(), profile: nil))
        let filed = ColumnTree.fromArc(try XCTUnwrap(sidebar.spaces.first?.pinned), into: [])
        // L1 at the top; the pages of L2, L3 and L4 inside it go into it.
        XCTAssertEqual(filed.groups.map(\.name), ["L1"])
        let l1 = try XCTUnwrap(filed.groups.first).id
        XCTAssertEqual(filed.pages.map(\.item.url.absoluteString), [
            "https://top.example/", "https://one.example/", "https://two.example/",
            "https://three.example/", "https://four.example/",
        ], "in the order they come")
        XCTAssertEqual(filed.pages.map(\.group), [nil, l1, l1, l1, l1])
    }

    func testBringingArcInAgainFillsTheGroupsThereAre() throws {
        let sidebar = try XCTUnwrap(Arc.parse(arcFile(), profile: nil))
        let pinned = try XCTUnwrap(sidebar.spaces.first?.pinned)
        let first = ColumnTree.fromArc(pinned, into: [])
        let again = ColumnTree.fromArc(pinned, into: first.groups)
        XCTAssertEqual(again.groups, first.groups)
        XCTAssertEqual(again.pages.map(\.group), first.pages.map(\.group))
    }
}
