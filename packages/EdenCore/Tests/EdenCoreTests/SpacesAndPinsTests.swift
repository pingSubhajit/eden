import XCTest
@testable import EdenCore

/// What spaces and pins are on every device: spaces.json and its repairs,
/// whose store a space uses, how it looks, where its tabs are kept, pins.json
/// and how a space's own pins and its profile's shared ones make one row.
final class SpacesAndPinsTests: XCTestCase {
    private let work = Space(id: UUID(), name: "Work", colour: 1)
    private let play = Space(id: UUID(), name: "Play", colour: 2)
    private let clients = UUID()
    private let clientsHome = UUID()

    private func home(_ profile: UUID) -> UUID? { profile == clients ? clientsHome : nil }

    private func spaces(_ saved: [Space], orderKept: Bool = false) -> [Space] {
        SpacesFile.spaces(from: saved, orderKept: orderKept, home: home)
    }

    // MARK: - spaces.json

    func testNoListIsTheFirstSpaceAlone() {
        XCTAssertEqual(spaces([]).map(\.id), [Space.firstID])
    }

    func testAListWithoutTheFirstSpaceGetsItBackFirst() {
        XCTAssertEqual(spaces([work, play]).map(\.id), [Space.firstID, work.id, play.id])
    }

    func testTheFirstSpaceIsKeptOnceAndInPersonal() {
        var stray = Space.first()
        stray.profile = clients
        stray.name = "Again"
        let read = spaces([work, stray, play, Space.first()])
        XCTAssertEqual(read.filter(\.isFirst).count, 1)
        XCTAssertEqual(read.first { $0.isFirst }?.name, "Again", "the first entry, where it was")
        XCTAssertNil(read.first { $0.isFirst }?.profile)
    }

    func testAnUntouchedListReadsHomeFirst() {
        // Written before spaces could be moved: the home goes first.
        let first = Space.first()
        XCTAssertEqual(spaces([first, work]).map(\.id), [Space.firstID, work.id])
    }

    func testAMovedHomeStaysWhereItWasPut() {
        // Only a move puts a home away from the front: the order is the user's.
        XCTAssertEqual(spaces([work, Space.first(), play]).map(\.id), [work.id, Space.firstID, play.id])
        XCTAssertEqual(spaces([work, Space.first()], orderKept: true).map(\.id), [work.id, Space.firstID])
    }

    func testOneProfilesSpacesReadHomeFirstUnlessMoved() {
        let theirs = Space(id: UUID(), name: "Accounts", colour: 0, profile: clients)
        let theirHome = Space(id: clientsHome, name: "Clients", colour: 0, profile: clients)
        let saved = [Space.first(), work, theirs, theirHome]
        let all = spaces(saved, orderKept: false)
        // Clients' home is second in its block: a move, so the order is kept.
        let mine = SpacesFile.spaces(of: clients, in: all, saved: saved, orderKept: false, home: home)
        XCTAssertEqual(mine.map(\.id), [theirs.id, clientsHome])
        let personal = SpacesFile.spaces(of: Space.personalProfileID, in: all, saved: saved, orderKept: false, home: home)
        XCTAssertEqual(personal.map(\.id), [Space.firstID, work.id])
    }

    func testReplacingOneProfileKeepsTheOthers() {
        let theirs = Space(id: UUID(), name: "Accounts", colour: 0, profile: clients)
        let all = [Space.first(), work, theirs]
        let replaced = SpacesFile.replacing(profile: Space.personalProfileID, in: all, with: [play, Space.first()])
        XCTAssertEqual(replaced.map(\.id), [theirs.id, play.id, Space.firstID])
        XCTAssertEqual(SpacesFile.replacing(profile: clients, in: all, with: [play]).last?.profile, clients)
    }

    func testAListGoesAndComesBackTheSame() throws {
        let list = [Space.first(), Space(id: UUID(), name: "Work", colour: 3, icon: "terminal", sharesSignIns: true,
                                         downloads: "/tmp", profile: clients)]
        XCTAssertEqual(try SpacesFile.decode(SpacesFile.encode(list)), list)
    }

    // MARK: - a space's store, look and session

    func testWhoseSignInsASpaceHas() {
        XCTAssertEqual(Space.first().storeKey(profileHome: Space.firstID), .profile(Space.personalProfileID))
        var shares = work
        shares.sharesSignIns = true
        XCTAssertEqual(shares.storeKey(profileHome: Space.firstID), .profile(Space.personalProfileID))
        XCTAssertEqual(work.storeKey(profileHome: Space.firstID), .space(work.id), "from before the choice: its own")
        let theirHome = Space(id: clientsHome, name: "Clients", colour: 0, profile: clients)
        XCTAssertEqual(theirHome.storeKey(profileHome: clientsHome), .profile(clients))
    }

    func testAnIconOrColourFromANewerEdenShowsAsNoneAndIsKept() {
        var newer = work
        newer.icon = "sparkles.rectangle.stack.fill"
        newer.colour = 99
        XCTAssertEqual(newer.symbol, "briefcase")
        XCTAssertNil(newer.tintIndex)
        XCTAssertEqual(newer.icon, "sparkles.rectangle.stack.fill", "kept for the Eden that knows it")
        XCTAssertEqual(Space.first().symbol, "house")
        XCTAssertEqual(work.tintIndex, 1)
        XCTAssertEqual(SpaceAppearance.icons.count, SpaceAppearance.iconNames.count)
        XCTAssertEqual(SpaceAppearance.colours.count, SpaceAppearance.colourNames.count)
    }

    func testANewSpaceGetsTheFirstIconNotWorn() {
        var worn = work
        worn.icon = "briefcase"
        XCTAssertEqual(SpaceAppearance.freeIcon(among: [worn]), "building.2")
    }

    func testTheFirstSpaceKeepsTheSessionFileThereAlwaysWas() {
        XCTAssertEqual(SpaceSessionFile.name(for: Space.firstID, stem: "tabs"), "tabs.json")
        XCTAssertEqual(SpaceSessionFile.name(for: work.id, stem: "session"), "session-\(work.id.uuidString).json")
    }

    // MARK: - pins.json

    private func def(_ letter: String, listed: Bool? = nil) -> PinDef {
        PinDef(id: UUID(), letter: letter, home: "https://\(letter.lowercased()).example/", title: letter, listed: listed)
    }

    func testAFileWithSharedPinsReadsEveryList() throws {
        let space = UUID(), other = UUID()
        let json = """
        {"\(space.uuidString)": [{"id": "\(UUID().uuidString)", "letter": "A", "home": "https://a.example/", "title": "A"}],
         "shared": [{"id": "\(UUID().uuidString)", "letter": "M", "home": "https://m.example/", "title": "M"}],
         "shared:\(other.uuidString)": [{"id": "\(UUID().uuidString)", "letter": "N", "home": "https://n.example/", "title": "N"}],
         "shared:nonsense": [], "later": []}
        """
        let read = try PinsFile.decode(Data(json.utf8))
        XCTAssertEqual(read.pins(of: space).map(\.letter), ["A"])
        XCTAssertEqual(read.shared(by: Space.personalProfileID).map(\.letter), ["M"])
        XCTAssertEqual(read.shared(by: other).map(\.letter), ["N"])
        XCTAssertEqual(read.bySpace.count, 1)
    }

    func testAFileGoesAndComesBackTheSameGroupsIncluded() throws {
        var a = def("A", listed: true)
        a.group = UUID()
        let catalog = PinCatalog(bySpace: [UUID(): [a]], sharedByProfile: [Space.personalProfileID: [def("M")], clients: [def("N")]])
        XCTAssertEqual(try PinsFile.decode(PinsFile.encode(catalog)), catalog)
    }

    /// A row's kept group goes on disk under the name it always had,
    /// "folder", so an older Eden and every other device read it as before.
    func testAPinsGroupIsWrittenAndReadAsItsFolder() throws {
        var a = def("A", listed: true)
        let group = UUID()
        a.group = group
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        XCTAssertEqual(object["folder"] as? String, group.uuidString)
        XCTAssertNil(object["group"])
        let older = #"{"id":"\#(UUID().uuidString)","letter":"B","home":"https://b.example/","title":"B","listed":true,"folder":"\#(group.uuidString)"}"#
        XCTAssertEqual(try JSONDecoder().decode(PinDef.self, from: Data(older.utf8)).group, group)
        let none = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(def("C"))) as? [String: Any])
        XCTAssertNil(none["folder"], "in no group, the pin is written as it always was")
    }

    func testNoSharedPinsWritesNoSharedKey() throws {
        // Someone who never turns them on keeps the file they had.
        let data = try PinsFile.encode(PinCatalog(bySpace: [UUID(): [def("A")]], sharedByProfile: [Space.personalProfileID: []]))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(keys.count, 1)
        XCTAssertFalse(keys.contains("shared"))
    }

    func testAFileThatWontReadSaysSo() {
        XCTAssertThrowsError(try PinsFile.decode(Data("{".utf8)))
    }

    // MARK: - a row

    func testSharingMovesAPinToTheEndOfTheSharedOnesOutOfItsGroup() {
        var a = def("A", listed: true)
        a.group = UUID()
        let b = def("B"), m = def("M")
        let moved = PinLists.share(a.id, own: [a, b], shared: [m])
        XCTAssertEqual(moved.own, [b])
        XCTAssertEqual(moved.shared.map(\.id), [m.id, a.id])
        XCTAssertNil(moved.shared.last?.group)
    }

    func testKeepingMovesAPinToTheStartOfTheSpacesOwn() {
        let a = def("A"), m = def("M"), n = def("N")
        let moved = PinLists.keep(m.id, own: [a], shared: [m, n])
        XCTAssertEqual(moved.own, [m, a])
        XCTAssertEqual(moved.shared, [n])
    }

    func testAnUnknownPinChangesNothing() {
        let a = def("A"), m = def("M")
        XCTAssertTrue(PinLists.share(UUID(), own: [a], shared: [m]) == ([a], [m]))
        XCTAssertTrue(PinLists.keep(UUID(), own: [a], shared: [m]) == ([a], [m]))
    }

    func testSplittingARowKeepsEachListInRowOrder() {
        let a = def("A"), m = def("M"), b = def("B"), n = def("N")
        let parts = PinLists.split([a, m, b, n], shared: [m.id, n.id])
        XCTAssertEqual(parts.own, [a, b])
        XCTAssertEqual(parts.shared, [m, n])
    }

    func testARowIsTheSharedPinsThenTheSpacesOwnEachOnce() {
        let a = def("A"), m = def("M")
        XCTAssertEqual(PinLists.row(own: [a, m], shared: [m], showing: true), [m, a])
        XCTAssertEqual(PinLists.row(own: [a], shared: [m], showing: false), [a])
    }

    func testARowNotYetGivenTheSharedPinsCannotWipeThem() {
        let m = def("M"), n = def("N")
        XCTAssertEqual(PinLists.sharedToWrite([n, m], showing: true), [n, m])
        XCTAssertNil(PinLists.sharedToWrite([], showing: true))
        XCTAssertNil(PinLists.sharedToWrite([m], showing: false))
    }
}
